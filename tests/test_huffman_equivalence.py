#!/usr/bin/env python3
"""Differential test: optimized Huffman decoder vs the original.

bm_pyflate_opt replaces HuffmanTable.find_next_symbol's linear table scan
with a length-indexed dictionary lookup. The bundled benchmark data is
bzip2, which only ever decodes with reversed=False, so the bundled MD5
check cannot exercise the reversed=True path used by DEFLATE.

This test drives both implementations with identical randomly generated
Huffman tables and identical bit patterns, in both directions, and
requires that they agree on all three observable outcomes:

  * the returned symbol code
  * how many bits were consumed from the field
  * whether the lookup raised instead of returning

Run directly:  python3 tests/test_huffman_equivalence.py
Exits non-zero on any mismatch.
"""

import importlib
import os
import random
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TRIALS = 300
PATTERNS_PER_TABLE = 40
SEED = 7


def load(variant):
    sys.path.insert(0, os.path.join(REPO_ROOT, variant))
    sys.modules.pop("run_benchmark", None)
    module = importlib.import_module("run_benchmark")
    sys.path.pop(0)
    return module


class FakeField(object):
    """Minimal stand-in for Bitfield/RBitfield.

    Only snoopbits, readbits and tell are reachable from
    find_next_symbol. Bit order does not matter here: both
    implementations are driven through this same object, so any
    self-consistent definition exposes a divergence between them.
    """

    WIDTH = 24

    def __init__(self, value):
        self.value = value
        self.consumed = None

    def snoopbits(self, n):
        return (self.value >> (self.WIDTH - n)) & ((1 << n) - 1)

    def readbits(self, n):
        self.consumed = n

    def tell(self):
        return (0, 0)


def probe(module, lengths, value, reverse):
    table = module.OrderedHuffmanTable(lengths)
    table.populate_huffman_symbols()
    table.min_max_bits()
    field = FakeField(value)
    try:
        return ("ok", table.find_next_symbol(field, reverse), field.consumed)
    except Exception as exc:
        return ("raise", type(exc).__name__, None)


def main():
    original = load("bm_pyflate")
    optimized = load("bm_pyflate_opt")

    random.seed(SEED)
    compared = 0
    mismatches = []

    for _ in range(TRIALS):
        size = random.randint(2, 40)
        lengths = [random.choice([0, 1, 2, 3, 4, 5, 6, 7, 8])
                   for _ in range(size)]
        if not any(lengths):
            continue

        for reverse in (True, False):
            for _ in range(PATTERNS_PER_TABLE):
                value = random.getrandbits(FakeField.WIDTH)
                expected = probe(original, lengths, value, reverse)
                actual = probe(optimized, lengths, value, reverse)
                compared += 1
                if expected != actual:
                    mismatches.append((lengths, reverse, value,
                                       expected, actual))

    print("compared %d decode attempts across both directions" % compared)

    if mismatches:
        print("%d MISMATCHES" % len(mismatches))
        for lengths, reverse, value, expected, actual in mismatches[:5]:
            print("  lengths=%s reversed=%s value=%#08x" %
                  (lengths, reverse, value))
            print("    original : %s" % (expected,))
            print("    optimized: %s" % (actual,))
        return 1

    print("no mismatches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
