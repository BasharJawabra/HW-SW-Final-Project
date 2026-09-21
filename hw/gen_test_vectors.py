#!/usr/bin/env python3
"""Generate co-verification vectors for hw/huffman_decoder.sv.

The vectors are derived from the benchmark's own Huffman implementation, so a
passing simulation demonstrates that the hardware decoder and the Python
decoder agree, rather than merely that the hardware matches a hand-written
expectation.

For a set of randomly chosen code lengths this script:

  1. builds an OrderedHuffmanTable exactly as bm_pyflate_opt does,
  2. derives the canonical per-length parameters the hardware needs
     (first_code, count, base_index) plus the flat symbol table,
  3. encodes a random symbol sequence MSB-first, switching Huffman group
     every GROUP_LEN symbols according to a selector list,
  4. terminates the sequence with the EOB symbol,
  5. writes $readmemh-compatible files into hw/vectors/.

The encoder is the inverse of the decoder under test: symbol s is emitted as
x.bits bits of x.symbol for the table entry whose .code equals s. Both come
straight from populate_huffman_symbols, so no independent reimplementation of
canonical code assignment is involved.

Usage:  python3 hw/gen_test_vectors.py
"""

import heapq
import os
import random
import sys

MAX_CODE_LEN = 20
NUM_SYMBOLS = 258
GROUP_LEN = 50
WORD_W = 32

NUM_GROUPS = 2
NUM_SYMBOLS_TO_ENCODE = 230
SEED = 20260921

HW_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HW_DIR)
VECTOR_DIR = os.path.join(HW_DIR, "vectors")


def load_benchmark():
    sys.path.insert(0, os.path.join(REPO_ROOT, "bm_pyflate_opt"))
    import run_benchmark
    return run_benchmark


def huffman_lengths(weights):
    """Code lengths from a real Huffman tree.

    Randomly chosen lengths will not generally satisfy the Kraft equality,
    and canonical code assignment over invalid lengths produces a code that
    is not prefix-free: a short code can be a prefix of a longer one, so the
    decoder's shortest-match rule decodes the wrong symbol. Building an
    actual tree guarantees a decodable code.
    """
    if len(weights) == 1:
        return [1]

    heap = [(weight, [index]) for index, weight in enumerate(weights)]
    heapq.heapify(heap)
    lengths = [0] * len(weights)

    while len(heap) > 1:
        weight_a, group_a = heapq.heappop(heap)
        weight_b, group_b = heapq.heappop(heap)
        for index in group_a + group_b:
            lengths[index] += 1
        heapq.heappush(heap, (weight_a + weight_b, group_a + group_b))

    return lengths


def build_table(pf, lengths):
    table = pf.OrderedHuffmanTable(lengths)
    table.populate_huffman_symbols()
    table.min_max_bits()
    return table


def derive_hw_params(table):
    """Extract canonical per-length parameters from a populated table.

    table.table is sorted by (bits, code), so the flat symbol array is simply
    the codes in that order, and each length's symbols occupy one contiguous
    span within it.
    """
    first_code = [0] * (MAX_CODE_LEN + 1)
    count = [0] * (MAX_CODE_LEN + 1)
    base_index = [0] * (MAX_CODE_LEN + 1)
    symbols = [entry.code for entry in table.table]

    for index, entry in enumerate(table.table):
        length = entry.bits
        if count[length] == 0:
            first_code[length] = entry.symbol
            base_index[length] = index
        count[length] += 1

    return first_code, count, base_index, symbols


def encode(tables, sequence):
    """Encode a symbol sequence MSB-first, switching group every GROUP_LEN."""
    bits = []
    for position, symbol in enumerate(sequence):
        table = tables[selector_for(position)]
        entry = next(e for e in table.table if e.code == symbol)
        for shift in range(entry.bits - 1, -1, -1):
            bits.append((entry.symbol >> shift) & 1)
    return bits


def selector_for(position):
    return (position // GROUP_LEN) % NUM_GROUPS


def bits_to_words(bits):
    padded = bits + [0] * ((-len(bits)) % WORD_W)
    words = []
    for offset in range(0, len(padded), WORD_W):
        value = 0
        for bit in padded[offset:offset + WORD_W]:
            value = (value << 1) | bit
        words.append(value)
    return words


def write_hex(name, values, digits):
    path = os.path.join(VECTOR_DIR, name)
    with open(path, "w") as handle:
        for value in values:
            handle.write("%0*x\n" % (digits, value))
    return path


def main():
    pf = load_benchmark()
    random.seed(SEED)
    os.makedirs(VECTOR_DIR, exist_ok=True)

    # Every group must be able to encode every symbol we intend to emit, so
    # all groups are built over the same symbol alphabet with independently
    # chosen code lengths.
    alphabet = 40
    tables = []
    for _ in range(NUM_GROUPS):
        weights = [random.randint(1, 500) for _ in range(alphabet)]
        lengths = huffman_lengths(weights)
        assert max(lengths) <= MAX_CODE_LEN
        assert abs(sum(2.0 ** -length for length in lengths) - 1.0) < 1e-9, \
            "lengths violate the Kraft equality"
        table = build_table(pf, lengths)
        assert len({entry.code for entry in table.table}) == alphabet
        tables.append(table)

    eob_symbol = alphabet - 1
    body = [random.randint(0, alphabet - 2)
            for _ in range(NUM_SYMBOLS_TO_ENCODE)]
    sequence = body + [eob_symbol]

    bits = encode(tables, sequence)
    words = bits_to_words(bits)

    first_codes = []
    counts = []
    bases = []
    symbol_mem = []
    for table in tables:
        first_code, count, base_index, symbols = derive_hw_params(table)
        first_codes += first_code[1:MAX_CODE_LEN + 1]
        counts += count[1:MAX_CODE_LEN + 1]
        bases += base_index[1:MAX_CODE_LEN + 1]
        padded = symbols + [0] * (NUM_SYMBOLS - len(symbols))
        symbol_mem += padded

    num_selectors = (len(sequence) + GROUP_LEN - 1) // GROUP_LEN
    selectors = [group % NUM_GROUPS for group in range(num_selectors)]
    assert all(selectors[position // GROUP_LEN] == selector_for(position)
               for position in range(len(sequence))), \
        "selector list disagrees with the group used during encoding"

    write_hex("first_code.hex", first_codes, 5)
    write_hex("count.hex", counts, 3)
    write_hex("base_index.hex", bases, 3)
    write_hex("symbols.hex", symbol_mem, 3)
    write_hex("selectors.hex", selectors, 1)
    write_hex("stream.hex", words, 8)
    write_hex("expected.hex", body, 3)
    # The fourth entry lets the testbench check final_bit_pos exactly: the
    # decoder must report the offset immediately after the EOB code, not
    # after the code its pipeline speculatively fetched behind it.
    write_hex("meta.hex",
              [eob_symbol, len(body), len(words), len(bits)], 4)

    print("groups            : %d" % NUM_GROUPS)
    print("alphabet          : %d symbols (eob = %d)" % (alphabet, eob_symbol))
    print("encoded symbols   : %d body + 1 eob" % len(body))
    print("encoded bits       : %d (%d words of %d bits)"
          % (len(bits), len(words), WORD_W))
    print("selector entries  : %s" % selectors)
    print("vectors written to: %s" % VECTOR_DIR)


if __name__ == "__main__":
    main()
