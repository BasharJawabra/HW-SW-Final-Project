#!/usr/bin/env bash
#
# script_pyflate.sh - reproduce the pyflate half of this project.
#
# Stages can be run individually or all at once:
#
#   ./script_pyflate.sh setup      install dependencies
#   ./script_pyflate.sh baseline   time the pristine benchmark
#   ./script_pyflate.sh optimized  time the optimized benchmark
#   ./script_pyflate.sh compare    statistical comparison of the two
#   ./script_pyflate.sh cprofile   per-function profile of both variants
#   ./script_pyflate.sh flame      perf record + flame graph
#   ./script_pyflate.sh hw         compile and simulate the accelerator
#   ./script_pyflate.sh all        everything except setup
#
# With no argument it runs: baseline, optimized, compare.
# That is the sequence that produces the headline speedup number and it
# takes a couple of minutes; the flame stage is much slower because it
# runs the debug interpreter under perf.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="$REPO/results"
BASE_DIR="bm_pyflate"
OPT_DIR="bm_pyflate_opt"

# pyperf configuration, identical for every measurement in this project
# so that numbers from different stages are comparable.
PYPERF_ARGS=(-p 10 -w 1 -n 5)

mkdir -p "$RESULTS"

say() { printf '\n=== %s ===\n' "$*"; }


stage_setup() {
    say "installing dependencies"
    # python3-dbg carries the symbols perf needs; the stock python3 build
    # is stripped and produces an unreadable profile.
    sudo apt-get update
    sudo apt-get install -y \
        python3 python3-pip python3-dbg \
        linux-tools-common "linux-tools-$(uname -r)" \
        iverilog git

    pip3 install --user pyperf

    if [ ! -d "$HOME/FlameGraph" ]; then
        git clone --depth 1 \
            https://github.com/brendangregg/FlameGraph "$HOME/FlameGraph"
    fi

    # The QEMU guest exposes no PMU, so profiling uses the cpu-clock
    # software event. Kernel symbols additionally need this relaxed.
    sudo sysctl -w kernel.perf_event_paranoid=1 || true
    sudo sysctl -w kernel.kptr_restrict=0 || true
}


stage_baseline() {
    say "baseline: $BASE_DIR"
    python3 "$REPO/$BASE_DIR/run_benchmark.py" \
        -o "$RESULTS/pyflate_baseline.json" "${PYPERF_ARGS[@]}"
}


stage_optimized() {
    say "optimized: $OPT_DIR"
    python3 "$REPO/$OPT_DIR/run_benchmark.py" \
        -o "$RESULTS/pyflate_optimized.json" "${PYPERF_ARGS[@]}"
}


stage_compare() {
    say "comparison"
    # The benchmark verifies itself: bench_pyflake raises on an MD5
    # mismatch, so both runs above having completed is already proof
    # that the optimized variant decompresses correctly.
    python3 -m pyperf compare_to \
        "$RESULTS/pyflate_baseline.json" \
        "$RESULTS/pyflate_optimized.json" \
        --table
}


stage_cprofile() {
    say "cProfile: baseline"
    python3 "$REPO/profile_pyflate.py" --variant "$BASE_DIR" \
        --loops 5 --cprofile --limit 18

    say "cProfile: optimized"
    python3 "$REPO/profile_pyflate.py" --variant "$OPT_DIR" \
        --loops 5 --cprofile --limit 18
}


stage_flame() {
    say "perf record + flame graph"

    local fg
    fg="$(dirname "$(find "$HOME" -name stackcollapse-perf.pl 2>/dev/null \
          | head -1)")"
    if [ ! -x "$fg/stackcollapse-perf.pl" ]; then
        echo "FlameGraph not found; run '$0 setup' first" >&2
        return 1
    fi

    # cpu-clock rather than cycles: the guest has no PMU.
    # DWARF rather than frame pointers: the debug build paints freed
    # memory with 0xFD/0xDD and the frame-pointer unwinder reports those
    # fill bytes as return addresses, producing a meaningless graph.
    perf record -e cpu-clock -F 299 --call-graph dwarf \
        -o /tmp/pyflate_dwarf.data \
        -- python3-dbg "$REPO/profile_pyflate.py" \
              --variant "$BASE_DIR" --loops 2

    perf script -i /tmp/pyflate_dwarf.data > /tmp/pyflate.perf
    "$fg/stackcollapse-perf.pl" /tmp/pyflate.perf > /tmp/pyflate.folded
    "$fg/flamegraph.pl" --title "pyflate baseline (cpu-clock, DWARF unwind)" \
        /tmp/pyflate.folded > "$RESULTS/pyflate_baseline_flame.svg"

    echo "wrote $RESULTS/pyflate_baseline_flame.svg"

    say "perf self-time ranking"
    perf report -i /tmp/pyflate_dwarf.data --stdio --no-children -g none \
        2>/dev/null | head -30
}


stage_hw() {
    say "hardware: regenerate vectors from the Python model"
    python3 "$REPO/hw/gen_test_vectors.py"

    say "hardware: compile"
    iverilog -g2012 -o /tmp/hd_tb \
        "$REPO/hw/huffman_decoder.sv" "$REPO/hw/huffman_decoder_tb.sv"

    # Run from the repo root: the testbench loads its vectors with
    # relative paths.
    cd "$REPO"

    say "hardware: simulate, sink always ready"
    vvp /tmp/hd_tb

    say "hardware: simulate, sink stalling"
    vvp /tmp/hd_tb +backpressure
}


main() {
    case "${1:-default}" in
        setup)     stage_setup ;;
        baseline)  stage_baseline ;;
        optimized) stage_optimized ;;
        compare)   stage_compare ;;
        cprofile)  stage_cprofile ;;
        flame)     stage_flame ;;
        hw)        stage_hw ;;
        all)
            stage_baseline
            stage_optimized
            stage_compare
            stage_cprofile
            stage_flame
            stage_hw
            ;;
        default)
            stage_baseline
            stage_optimized
            stage_compare
            ;;
        *)
            echo "unknown stage: $1" >&2
            sed -n '3,20p' "${BASH_SOURCE[0]}" >&2
            exit 1
            ;;
    esac
}

main "$@"
