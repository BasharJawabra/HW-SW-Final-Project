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
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "bm_raytrace"))

import run_benchmark as raytrace  # noqa: E402


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--loops", type=int, default=10,
                        help="number of full scene renders (default: 10)")
    parser.add_argument("--width", type=int, default=raytrace.DEFAULT_WIDTH,
                        help="image width (default: %(default)s)")
    parser.add_argument("--height", type=int, default=raytrace.DEFAULT_HEIGHT,
                        help="image height (default: %(default)s)")
    parser.add_argument("--cprofile", action="store_true",
                        help="run under cProfile and print the top functions")
    parser.add_argument("--sort", default="tottime",
                        help="cProfile sort key (default: %(default)s)")
    parser.add_argument("--limit", type=int, default=25,
                        help="cProfile rows to print (default: %(default)s)")
    return parser.parse_args()


def run(args):
    return raytrace.bench_raytrace(args.loops, args.width, args.height, None)


def main():
    args = parse_args()

    if args.cprofile:
        import cProfile
        import pstats

        profiler = cProfile.Profile()
        profiler.enable()
        elapsed = run(args)
        profiler.disable()
        stats = pstats.Stats(profiler, stream=sys.stdout)
        stats.sort_stats(args.sort).print_stats(args.limit)
    else:
        elapsed = run(args)

    print("loops=%d geometry=%dx%d total=%.3fs per_loop=%.1fms"
          % (args.loops, args.width, args.height,
             elapsed, elapsed / args.loops * 1000.0))


if __name__ == "__main__":
    main()
