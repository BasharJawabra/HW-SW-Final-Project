// --------------------------------------------------------------------------
// huffman_decoder_tb.sv
//
// Co-verification testbench for huffman_decoder.sv.
//
// The stimulus and the expected results are not written by hand: they are
// produced by hw/gen_test_vectors.py from the benchmark's own Huffman
// implementation. A passing run therefore shows that the hardware decoder
// reproduces what pyflate's HuffmanTable.find_next_symbol produces, which is
// the property the accelerator has to satisfy in order to be a drop-in
// replacement.
//
// Checked:
//   * every decoded symbol, in order, against the Python decode
//   * the EOB symbol terminates decoding rather than being streamed onward
//   * symbol_count excludes EOB
//   * final_bit_pos equals the true end of the encoded stream, which fails
//     if the pipeline reports the position of the code it prefetched behind
//     EOB instead of EOB's own end
//   * no spurious error assertion
//
// Run with +backpressure to randomly stall the output channel, which
// exercises the stage-2 hold path; without it the sink always accepts.
//
//   iverilog -g2012 -o /tmp/hd_tb hw/huffman_decoder.sv hw/huffman_decoder_tb.sv
//   vvp /tmp/hd_tb
//   vvp /tmp/hd_tb +backpressure
// --------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module huffman_decoder_tb;

    localparam int MAX_CODE_LEN = 20;
    localparam int SYMBOL_W     = 9;
    localparam int NUM_SYMBOLS  = 258;
    localparam int WORD_W       = 32;

    // Groups present in the generated vectors, which is fewer than the six
    // the DUT supports.
    localparam int VEC_GROUPS   = 2;
    localparam int GROUP_LEN    = 50;

    localparam int MAX_WORDS     = 4096;
    localparam int MAX_EXPECTED  = 8192;
    localparam int MAX_SELECTORS = 1024;
    localparam int TIMEOUT_CYCLES = 200000;

    // ---- vector storage ---------------------------------------------------
    logic [MAX_CODE_LEN-1:0] vec_first [0:VEC_GROUPS*MAX_CODE_LEN-1];
    logic [SYMBOL_W:0]       vec_count [0:VEC_GROUPS*MAX_CODE_LEN-1];
    logic [SYMBOL_W-1:0]     vec_base  [0:VEC_GROUPS*MAX_CODE_LEN-1];
    logic [SYMBOL_W-1:0]     vec_sym   [0:VEC_GROUPS*NUM_SYMBOLS-1];
    logic [2:0]              vec_sel   [0:MAX_SELECTORS-1];
    logic [WORD_W-1:0]       vec_word  [0:MAX_WORDS-1];
    logic [SYMBOL_W-1:0]     vec_exp   [0:MAX_EXPECTED-1];
    logic [15:0]             vec_meta  [0:3];

    int exp_eob;
    int exp_symbols;
    int exp_words;
    int exp_bits;

    // ---- clock / reset ----------------------------------------------------
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- DUT ports --------------------------------------------------------
    logic                    start;
    logic [SYMBOL_W-1:0]     eob_symbol;
    logic                    busy, done, error;
    logic [31:0]             final_bit_pos, symbol_count;

    logic                    tbl_we;
    logic [2:0]              tbl_table;
    logic [4:0]              tbl_len;
    logic [MAX_CODE_LEN-1:0] tbl_first_code;
    logic [SYMBOL_W:0]       tbl_count;
    logic [SYMBOL_W-1:0]     tbl_base_index;

    logic                    sym_we;
    logic [2:0]              sym_table;
    logic [SYMBOL_W-1:0]     sym_addr, sym_data;

    logic                    sel_we;
    logic [14:0]             sel_addr;
    logic [2:0]              sel_data;

    logic                    s_valid, s_ready;
    logic [WORD_W-1:0]       s_data;

    logic                    m_valid, m_ready;
    logic [SYMBOL_W-1:0]     m_data;

    huffman_decoder #(
        .MAX_CODE_LEN (MAX_CODE_LEN),
        .SYMBOL_W     (SYMBOL_W),
        .NUM_SYMBOLS  (NUM_SYMBOLS),
        .WORD_W       (WORD_W)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .start (start), .eob_symbol (eob_symbol),
        .busy (busy), .done (done), .error (error),
        .final_bit_pos (final_bit_pos), .symbol_count (symbol_count),
        .tbl_we (tbl_we), .tbl_table (tbl_table), .tbl_len (tbl_len),
        .tbl_first_code (tbl_first_code), .tbl_count (tbl_count),
        .tbl_base_index (tbl_base_index),
        .sym_we (sym_we), .sym_table (sym_table),
        .sym_addr (sym_addr), .sym_data (sym_data),
        .sel_we (sel_we), .sel_addr (sel_addr), .sel_data (sel_data),
        .s_valid (s_valid), .s_ready (s_ready), .s_data (s_data),
        .m_valid (m_valid), .m_ready (m_ready), .m_data (m_data)
    );

    // ---- scoreboard -------------------------------------------------------
    int received;
    int mismatches;
    logic saw_eob;
    logic backpressure;

    task automatic load_vectors();
        // The arrays are sized for the worst case, so every file is shorter
        // than the array it fills and $readmemh warns accordingly. Clearing
        // first means the unfilled tail reads as zero instead of X, so a
        // genuinely missing file shows up as an empty-vector failure rather
        // than as X propagating quietly into the DUT.
        for (int i = 0; i < VEC_GROUPS*MAX_CODE_LEN; i++) begin
            vec_first[i] = '0;
            vec_count[i] = '0;
            vec_base[i]  = '0;
        end
        for (int i = 0; i < VEC_GROUPS*NUM_SYMBOLS; i++) vec_sym[i] = '0;
        for (int i = 0; i < MAX_SELECTORS; i++)          vec_sel[i] = '0;
        for (int i = 0; i < MAX_WORDS; i++)              vec_word[i] = '0;
        for (int i = 0; i < MAX_EXPECTED; i++)           vec_exp[i] = '0;
        for (int i = 0; i < 4; i++)                      vec_meta[i] = '0;

        $readmemh("hw/vectors/meta.hex",       vec_meta);
        $readmemh("hw/vectors/first_code.hex", vec_first);
        $readmemh("hw/vectors/count.hex",      vec_count);
        $readmemh("hw/vectors/base_index.hex", vec_base);
        $readmemh("hw/vectors/symbols.hex",    vec_sym);
        $readmemh("hw/vectors/selectors.hex",  vec_sel);
        $readmemh("hw/vectors/stream.hex",     vec_word);
        $readmemh("hw/vectors/expected.hex",   vec_exp);

        exp_eob     = int'(vec_meta[0]);
        exp_symbols = int'(vec_meta[1]);
        exp_words   = int'(vec_meta[2]);
        exp_bits    = int'(vec_meta[3]);

        if (exp_symbols == 0 || exp_words == 0) begin
            $fatal(1, "vectors missing or empty - run: python3 hw/gen_test_vectors.py");
        end

        $display("vectors: %0d symbols, %0d words, %0d bits, eob=%0d",
                 exp_symbols, exp_words, exp_bits, exp_eob);
    endtask

    task automatic program_dut();
        for (int g = 0; g < VEC_GROUPS; g++) begin
            for (int L = 1; L <= MAX_CODE_LEN; L++) begin
                @(negedge clk);
                tbl_we         = 1'b1;
                tbl_table      = g[2:0];
                tbl_len        = L[4:0];
                tbl_first_code = vec_first[g*MAX_CODE_LEN + L - 1];
                tbl_count      = vec_count[g*MAX_CODE_LEN + L - 1];
                tbl_base_index = vec_base [g*MAX_CODE_LEN + L - 1];
            end
            @(negedge clk);
            tbl_we = 1'b0;

            for (int a = 0; a < NUM_SYMBOLS; a++) begin
                @(negedge clk);
                sym_we    = 1'b1;
                sym_table = g[2:0];
                sym_addr  = a[SYMBOL_W-1:0];
                sym_data  = vec_sym[g*NUM_SYMBOLS + a];
            end
            @(negedge clk);
            sym_we = 1'b0;
        end

        // Only the selectors the stream actually uses, one per GROUP_LEN
        // symbols including the group EOB falls in.
        for (int s = 0; s < (exp_symbols + GROUP_LEN) / GROUP_LEN; s++) begin
            @(negedge clk);
            sel_we   = 1'b1;
            sel_addr = s;
            sel_data = vec_sel[s];
        end
        @(negedge clk);
        sel_we = 1'b0;
    endtask

    // Source: hand words to the decoder whenever it will take them. Once the
    // vectors run out the stream is held invalid; a correct decoder must have
    // already found EOB by then.
    int word_ptr;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            word_ptr <= 0;
        end else if (s_valid && s_ready) begin
            word_ptr <= word_ptr + 1;
        end
    end

    assign s_valid = (word_ptr < exp_words);
    assign s_data  = vec_word[word_ptr];

    // Sink.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_ready <= 1'b1;
        end else if (backpressure) begin
            m_ready <= ($urandom_range(0, 3) != 0);
        end else begin
            m_ready <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && m_valid && m_ready) begin
            if (m_data == eob_symbol) begin
                saw_eob <= 1'b1;
                if (received != exp_symbols) begin
                    mismatches <= mismatches + 1;
                    $display("FAIL: eob arrived after %0d symbols, expected %0d",
                             received, exp_symbols);
                end
            end else begin
                if (saw_eob) begin
                    mismatches <= mismatches + 1;
                    $display("FAIL: symbol streamed after eob");
                end else if (received >= exp_symbols) begin
                    mismatches <= mismatches + 1;
                    $display("FAIL: symbol %0d beyond expected count", received);
                end else if (m_data !== vec_exp[received]) begin
                    mismatches <= mismatches + 1;
                    if (mismatches < 10) begin
                        $display("FAIL: symbol %0d = %0d, expected %0d",
                                 received, m_data, vec_exp[received]);
                    end
                end
                received <= received + 1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && error) begin
            $display("FAIL: decoder asserted error after %0d symbols", received);
        end
    end

    // ---- main sequence ----------------------------------------------------
    int cycles;

    initial begin
        backpressure = $test$plusargs("backpressure");

        start = 1'b0; tbl_we = 1'b0; sym_we = 1'b0; sel_we = 1'b0;
        tbl_table = '0; tbl_len = '0; tbl_first_code = '0;
        tbl_count = '0; tbl_base_index = '0;
        sym_table = '0; sym_addr = '0; sym_data = '0;
        sel_addr = '0; sel_data = '0;
        received = 0; mismatches = 0; saw_eob = 1'b0; cycles = 0;

        load_vectors();
        eob_symbol = exp_eob[SYMBOL_W-1:0];

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        program_dut();

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        while (!done && !error && cycles < TIMEOUT_CYCLES) begin
            @(posedge clk);
            cycles++;
        end

        repeat (4) @(negedge clk);

        if (cycles >= TIMEOUT_CYCLES) begin
            $display("FAIL: timeout after %0d cycles, %0d symbols decoded",
                     cycles, received);
            mismatches++;
        end

        if (!saw_eob) begin
            $display("FAIL: eob never observed on the output stream");
            mismatches++;
        end

        if (received != exp_symbols) begin
            $display("FAIL: decoded %0d symbols, expected %0d",
                     received, exp_symbols);
            mismatches++;
        end

        if (symbol_count != exp_symbols) begin
            $display("FAIL: symbol_count = %0d, expected %0d",
                     symbol_count, exp_symbols);
            mismatches++;
        end

        if (final_bit_pos != exp_bits) begin
            $display("FAIL: final_bit_pos = %0d, expected %0d",
                     final_bit_pos, exp_bits);
            mismatches++;
        end

        $display("----------------------------------------------------------");
        $display("backpressure    : %0s", backpressure ? "on" : "off");
        $display("symbols decoded : %0d", received);
        $display("cycles          : %0d", cycles);
        $display("final_bit_pos   : %0d (expected %0d)",
                 final_bit_pos, exp_bits);
        if (received > 0) begin
            $display("cycles/symbol   : %0.2f",
                     real'(cycles) / real'(received));
        end

        if (mismatches == 0) begin
            $display("RESULT: PASS");
        end else begin
            $display("RESULT: FAIL (%0d problems)", mismatches);
        end
        $display("----------------------------------------------------------");

        $finish;
    end

endmodule

`default_nettype wire
