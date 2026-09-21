// ---------------------------------------------------------------------------
// huffman_decoder.sv
//
// Canonical Huffman symbol decoder for the bzip2 decode path exercised by the
// pyflate benchmark. Sustains one decoded symbol per clock cycle.
//
// The software it replaces is HuffmanTable.find_next_symbol, which walks a
// table of code descriptors once per decoded symbol. Because pyflate assigns
// codes canonically (see populate_huffman_symbols), the codes themselves never
// need to be stored or compared: for a candidate value taken from the top L
// bits of the stream, a length-L code matches when
//
//     candidate - first_code[L] < count[L]
//
// and the decoded symbol then lives at base_index[L] + (candidate -
// first_code[L]) in a flat symbol table ordered by (length, symbol).
//
// All MAX_CODE_LEN lengths are evaluated concurrently and the shortest match
// wins, which is unambiguous because a Huffman code is prefix-free.
//
// Interfaces are simple ready/valid. An AXI4-Lite shim for the control and
// table-load ports and an AXI4-Stream/DMA shim for the data ports are
// described in report_pyflate.txt but are not implemented here.
// ---------------------------------------------------------------------------

`default_nettype none

module huffman_decoder #(
    // bzip2 permits code lengths of 1..20 and up to 258 symbols in use
    // (256 byte values plus the RUNA/RUNB pair and the EOB symbol).
    parameter int MAX_CODE_LEN = 20,
    parameter int SYMBOL_W     = 9,
    parameter int NUM_SYMBOLS  = 258,
    // bzip2 allows 2..6 Huffman groups, reselected every 50 symbols.
    parameter int NUM_TABLES   = 6,
    parameter int GROUP_LEN    = 50,
    parameter int SEL_DEPTH    = 32768,
    parameter int WORD_W       = 32,
    parameter int BIT_BUF_W    = 64
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // ---- control / status -------------------------------------------------
    input  logic                    start,
    input  logic [SYMBOL_W-1:0]     eob_symbol,
    output logic                    busy,
    output logic                    done,
    output logic                    error,
    // Bit offset immediately after the EOB symbol, so software can resume
    // parsing the next block header at the correct position.
    output logic [31:0]             final_bit_pos,
    output logic [31:0]             symbol_count,

    // ---- per-length table load (first_code / count / base_index) ----------
    input  logic                    tbl_we,
    input  logic [2:0]              tbl_table,
    input  logic [4:0]              tbl_len,
    input  logic [MAX_CODE_LEN-1:0] tbl_first_code,
    input  logic [SYMBOL_W:0]       tbl_count,
    input  logic [SYMBOL_W-1:0]     tbl_base_index,

    // ---- flat symbol table load -------------------------------------------
    input  logic                    sym_we,
    input  logic [2:0]              sym_table,
    input  logic [SYMBOL_W-1:0]     sym_addr,
    input  logic [SYMBOL_W-1:0]     sym_data,

    // ---- selector list load (which group decodes each run of 50) ----------
    input  logic                    sel_we,
    input  logic [14:0]             sel_addr,
    input  logic [2:0]              sel_data,

    // ---- compressed bit stream in -----------------------------------------
    input  logic                    s_valid,
    output logic                    s_ready,
    input  logic [WORD_W-1:0]       s_data,

    // ---- decoded symbol stream out ----------------------------------------
    output logic                    m_valid,
    input  logic                    m_ready,
    output logic [SYMBOL_W-1:0]     m_data
);

    localparam int CNT_W     = $clog2(BIT_BUF_W + 1);
    localparam int REFILL_HI = BIT_BUF_W - WORD_W;

    // -----------------------------------------------------------------------
    // Table storage
    // -----------------------------------------------------------------------
    logic [MAX_CODE_LEN-1:0] first_code_mem [0:NUM_TABLES-1][1:MAX_CODE_LEN];
    logic [SYMBOL_W:0]       count_mem      [0:NUM_TABLES-1][1:MAX_CODE_LEN];
    logic [SYMBOL_W-1:0]     base_mem       [0:NUM_TABLES-1][1:MAX_CODE_LEN];
    logic [SYMBOL_W-1:0]     sym_mem        [0:NUM_TABLES-1][0:NUM_SYMBOLS-1];
    logic [2:0]              sel_mem        [0:SEL_DEPTH-1];

    always_ff @(posedge clk) begin
        if (tbl_we) begin
            first_code_mem[tbl_table][tbl_len] <= tbl_first_code;
            count_mem[tbl_table][tbl_len]      <= tbl_count;
            base_mem[tbl_table][tbl_len]       <= tbl_base_index;
        end
        if (sym_we) begin
            sym_mem[sym_table][sym_addr] <= sym_data;
        end
        if (sel_we) begin
            sel_mem[sel_addr] <= sel_data;
        end
    end

    // -----------------------------------------------------------------------
    // Bit buffer: MSB-aligned, matching pyflate's RBitfield, which consumes
    // bzip2 streams most-significant-bit first.
    // -----------------------------------------------------------------------
    logic [BIT_BUF_W-1:0] buf_q;
    logic [CNT_W-1:0]     cnt_q;

    logic [BIT_BUF_W-1:0] buf_consumed, buf_next;
    logic [CNT_W-1:0]     cnt_consumed, cnt_next;
    logic                 load_word;

    logic                    do_consume;
    logic [4:0]              consume_len;
    logic [MAX_CODE_LEN-1:0] peek;

    assign peek = buf_q[BIT_BUF_W-1 -: MAX_CODE_LEN];

    always_comb begin
        if (do_consume) begin
            buf_consumed = buf_q << consume_len;
            cnt_consumed = cnt_q - consume_len;
        end else begin
            buf_consumed = buf_q;
            cnt_consumed = cnt_q;
        end

        if (load_word) begin
            buf_next = buf_consumed |
                       ({{(BIT_BUF_W-WORD_W){1'b0}}, s_data} <<
                        (REFILL_HI - cnt_consumed));
            cnt_next = cnt_consumed + WORD_W;
        end else begin
            buf_next = buf_consumed;
            cnt_next = cnt_consumed;
        end
    end

    assign s_ready   = busy && (cnt_consumed <= REFILL_HI);
    assign load_word = s_valid && s_ready;

    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            buf_q <= {BIT_BUF_W{1'b0}};
            cnt_q <= {CNT_W{1'b0}};
        end else begin
            buf_q <= buf_next;
            cnt_q <= cnt_next;
        end
    end

    // -----------------------------------------------------------------------
    // Group selection: bzip2 reselects the Huffman group every GROUP_LEN
    // symbols, and the selector list is fully known before decoding starts,
    // so the accelerator can switch tables autonomously.
    // -----------------------------------------------------------------------
    logic [2:0]  cur_table;
    logic [14:0] sel_ptr;
    logic [5:0]  group_left;

    // -----------------------------------------------------------------------
    // Stage 1: evaluate every code length in parallel, take the shortest hit
    // -----------------------------------------------------------------------
    logic [MAX_CODE_LEN-1:0] cand   [1:MAX_CODE_LEN];
    logic [MAX_CODE_LEN:0]   offset [1:MAX_CODE_LEN];
    logic                    hit    [1:MAX_CODE_LEN];

    logic       sel_hit;
    logic [4:0] sel_len;

    always_comb begin
        for (int L = 1; L <= MAX_CODE_LEN; L = L + 1) begin
            cand[L]   = peek >> (MAX_CODE_LEN - L);
            offset[L] = cand[L] - first_code_mem[cur_table][L];
            hit[L]    = (cnt_q >= L) &&
                        (count_mem[cur_table][L] != 0) &&
                        (cand[L] >= first_code_mem[cur_table][L]) &&
                        (offset[L] < count_mem[cur_table][L]);
        end
    end

    // Descending scan leaves the shortest matching length asserted last,
    // which is the one a prefix-free code requires. sel_len defaults to 1
    // rather than 0 so that the per-length arrays, which are indexed from 1,
    // are never read out of bounds when nothing matches.
    always_comb begin
        sel_hit = 1'b0;
        sel_len = 5'd1;
        for (int L = MAX_CODE_LEN; L >= 1; L = L - 1) begin
            if (hit[L]) begin
                sel_hit = 1'b1;
                sel_len = L[4:0];
            end
        end
    end

    logic [SYMBOL_W-1:0] sym_index;
    assign sym_index = base_mem[cur_table][sel_len] +
                       offset[sel_len][SYMBOL_W-1:0];

    // -----------------------------------------------------------------------
    // Stage 2: symbol table read and output
    // -----------------------------------------------------------------------
    logic                s2_valid;
    logic [2:0]          s2_table;
    logic [SYMBOL_W-1:0] s2_index;
    logic [31:0]         s2_bit_pos;

    logic [SYMBOL_W-1:0] s2_symbol;
    logic                s2_is_eob;
    logic                stage2_ready;
    logic                stage1_fire;
    logic                decode_error;
    logic [31:0]         bit_pos;

    assign s2_symbol    = sym_mem[s2_table][s2_index];
    assign s2_is_eob    = s2_valid && (s2_symbol == eob_symbol);
    assign stage2_ready = !s2_valid || m_ready;

    assign m_valid = s2_valid;
    assign m_data  = s2_symbol;

    // Advance stage 1 only when the stream has a code available, the output
    // can accept a symbol, and decoding has not already finished.
    assign stage1_fire = busy && sel_hit && stage2_ready && !s2_is_eob;

    assign do_consume  = stage1_fire;
    assign consume_len = sel_len;

    // An absent match is only an error once enough bits are buffered that
    // every length could genuinely be tested; otherwise we are merely
    // waiting for the stream to refill.
    assign decode_error = busy && !sel_hit && (cnt_q >= MAX_CODE_LEN);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy          <= 1'b0;
            done          <= 1'b0;
            error         <= 1'b0;
            s2_valid      <= 1'b0;
            s2_table      <= 3'd0;
            s2_index      <= {SYMBOL_W{1'b0}};
            s2_bit_pos    <= 32'd0;
            bit_pos       <= 32'd0;
            cur_table     <= 3'd0;
            sel_ptr       <= 15'd0;
            group_left    <= 6'd0;
            symbol_count  <= 32'd0;
            final_bit_pos <= 32'd0;
        end else if (start) begin
            busy          <= 1'b1;
            done          <= 1'b0;
            error         <= 1'b0;
            s2_valid      <= 1'b0;
            s2_table      <= 3'd0;
            s2_index      <= {SYMBOL_W{1'b0}};
            s2_bit_pos    <= 32'd0;
            bit_pos       <= 32'd0;
            cur_table     <= sel_mem[0];
            sel_ptr       <= 15'd1;
            group_left    <= GROUP_LEN;
            symbol_count  <= 32'd0;
            final_bit_pos <= 32'd0;
        end else begin
            // retire stage 2
            if (s2_valid && m_ready) begin
                s2_valid <= 1'b0;
                if (s2_symbol == eob_symbol) begin
                    busy          <= 1'b0;
                    done          <= 1'b1;
                    final_bit_pos <= s2_bit_pos;
                end else begin
                    symbol_count <= symbol_count + 32'd1;
                end
            end

            if (decode_error) begin
                busy  <= 1'b0;
                error <= 1'b1;
            end

            // launch a new symbol
            if (stage1_fire) begin
                s2_valid   <= 1'b1;
                s2_table   <= cur_table;
                s2_index   <= sym_index;
                s2_bit_pos <= bit_pos + sel_len;
                bit_pos    <= bit_pos + sel_len;

                if (group_left == 6'd1) begin
                    cur_table  <= sel_mem[sel_ptr];
                    sel_ptr    <= sel_ptr + 15'd1;
                    group_left <= GROUP_LEN;
                end else begin
                    group_left <= group_left - 6'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
