#!/usr/bin/env python3
"""Single-shot profiling driver for the pyflate benchmark.

The counterpart to profile_raytrace.py, and it exists for the same reason:
pyperf forks a fresh worker process per measured value, so `perf record`
samples scatter across short-lived children. This driver runs the identical
decompression workload in one long-lived process.

Two modes:

  (default)    plain run, intended to be wrapped by `perf record`
  --cprofile   deterministic per-function profile printed to stdout

CPython 3.10 predates the perf trampoline support added in 3.12, so perf
resolves only C-level interpreter symbols; cProfile supplies the
Python-level attribution.

--variant selects which copy of the benchmark to load, so the pristine and
optimized versions are profiled through an identical harness. Each variant
carries its own copy of the compressed input, so the data file is resolved
relative to the variant directory rather than hardcoded.

The benchmark verifies its own output: bench_pyflake raises on an MD5
mismatch, so a run that prints a timing at all decompressed correctly.
"""

import argparse
import importlib
import os
import sys

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))

DATA_NAME = os.path.join("data", "interpreter.tar.bz2")


def load_variant(variant):
    path = os.path.join(REPO_ROOT, variant)
    if not os.path.isdir(path):
        sys.exit("no such benchmark variant: %s" % path)
    sys.path.insert(0, path)
    return importlib.import_module("run_benchmark"), path


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", default="bm_pyflate",
                        help="benchmark directory to load "
                             "(default: %(default)s)")
    parser.add_argument("--loops", type=int, default=5,
                        help="number of full decompressions (default: 5)")
    parser.add_argument("--cprofile", action="store_true",
                        help="run under cProfile and print the top functions")
    parser.add_argument("--sort", default="tottime",
                        help="cProfile sort key (default: %(default)s)")
    parser.add_argument("--limit", type=int, default=25,
                        help="cProfile rows to print (default: %(default)s)")
    return parser.parse_args()


def main():
    args = parse_args()
    pyflate, variant_dir = load_variant(args.variant)

    data = os.path.join(variant_dir, DATA_NAME)
    if not os.path.isfile(data):
        sys.exit("missing benchmark data: %s" % data)

    def run():
        return pyflate.bench_pyflake(args.loops, data)

    if args.cprofile:
        import cProfile
        import pstats

        profiler = cProfile.Profile()
        profiler.enable()
        elapsed = run()
        profiler.disable()
        pstats.Stats(profiler, stream=sys.stdout) \
              .sort_stats(args.sort) \
              .print_stats(args.limit)
    else:
        elapsed = run()

    print("variant=%s loops=%d total=%.3fs per_loop=%.1fms"
          % (args.variant, args.loops, elapsed,
             elapsed / args.loops * 1000.0))


if __name__ == "__main__":
    main()
