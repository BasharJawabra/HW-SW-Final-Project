#!/usr/bin/env python3
"""Single-shot profiling driver for the raytrace benchmark.

pyperf spawns a fresh worker process for every measured value, which
scatters `perf record` samples across short-lived children and makes the
resulting profile hard to attribute. This driver runs the identical render
workload in one long-lived process instead.

Two profiling modes are supported:

  (default)    plain run, intended to be wrapped by `perf record`
  --cprofile   deterministic per-function profile printed to stdout

The second mode exists because CPython 3.10 has no perf trampoline support
(added in 3.12), so `perf` can only resolve C-level interpreter symbols.
cProfile supplies the Python-level function attribution that perf cannot.

--variant selects which copy of the benchmark to load, so the pristine and
optimized versions can be profiled with an otherwise identical harness.
"""

import argparse
import importlib
import os
import sys

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))


def load_variant(variant):
    path = os.path.join(REPO_ROOT, variant)
    if not os.path.isdir(path):
        sys.exit("no such benchmark variant: %s" % path)
    sys.path.insert(0, path)
    return importlib.import_module("run_benchmark")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", default="bm_raytrace",
                        help="benchmark directory to load "
                             "(default: %(default)s)")
    parser.add_argument("--loops", type=int, default=10,
                        help="number of full scene renders (default: 10)")
    parser.add_argument("--width", type=int,
                        help="image width (default: benchmark default)")
    parser.add_argument("--height", type=int,
                        help="image height (default: benchmark default)")
    parser.add_argument("--ppm", metavar="PATH",
                        help="write the final frame here, for output "
                             "comparison between variants")
    parser.add_argument("--cprofile", action="store_true",
                        help="run under cProfile and print the top functions")
    parser.add_argument("--sort", default="tottime",
                        help="cProfile sort key (default: %(default)s)")
    parser.add_argument("--limit", type=int, default=25,
                        help="cProfile rows to print (default: %(default)s)")
    return parser.parse_args()


def main():
    args = parse_args()
    raytrace = load_variant(args.variant)

    width = args.width if args.width else raytrace.DEFAULT_WIDTH
    height = args.height if args.height else raytrace.DEFAULT_HEIGHT

    def run():
        return raytrace.bench_raytrace(args.loops, width, height, args.ppm)

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

    print("variant=%s loops=%d geometry=%dx%d total=%.3fs per_loop=%.1fms"
          % (args.variant, args.loops, width, height,
             elapsed, elapsed / args.loops * 1000.0))


if __name__ == "__main__":
    main()
