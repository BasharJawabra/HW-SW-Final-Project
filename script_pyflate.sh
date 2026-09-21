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
#   ./script_pyflate.sh flamecmp   baseline vs optimized + diff flame graph
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

    # Two separate things make a DWARF-unwound CPython flame graph
    # unreadable, and they need different fixes.
    #
    # HEIGHT, and the box count that follows from it. Reaching one Python
    # call costs a cycle of seven C frames (_PyEval_Vector,
    # _PyEval_EvalFrame, _PyEval_EvalFrameDefault, call_function,
    # PyObject_Vectorcall, _PyObject_VectorcallTstate,
    # _PyFunction_Vectorcall) and that cycle repeats once per level of
    # Python call depth. Measured on the previous graph: _PyEval_Vector
    # appeared 373 times and the image was 138 rows tall.
    #
    # Note that stackcollapse-recursive.pl does NOT help here. It merges
    # only ADJACENT duplicate frames, and this is a cycle of seven
    # distinct names with no adjacent duplicates, so it collapses
    # nothing. tools/collapse_interpreter.py folds each run of plumbing
    # frames into one [python call] frame instead, which also merges
    # identical leaves that were previously scattered across hundreds of
    # spine depths. Sample counts are preserved exactly.
    #
    # WIDTH. Even after that, sub-1% frames remain, and at 5,536 boxes
    # 96% of them were narrower than 1%. A box that thin cannot hold a
    # label, and those boxes are most of the 1.0 MB file. --minwidth
    # drops them.
    local minwidth=1

    perf script -i /tmp/pyflate_dwarf.data > /tmp/pyflate.perf
    "$fg/stackcollapse-perf.pl" /tmp/pyflate.perf \
        | "$REPO/tools/collapse_interpreter.py" > /tmp/pyflate.folded
    "$fg/flamegraph.pl" \
        --title "pyflate baseline (cpu-clock, DWARF unwind)" \
        --subtitle "interpreter call frames collapsed; frames under ${minwidth}% omitted" \
        --minwidth "$minwidth" \
        /tmp/pyflate.folded > "$RESULTS/pyflate_baseline_flame.svg"

    echo "wrote $RESULTS/pyflate_baseline_flame.svg"

    say "perf self-time ranking"
    perf report -i /tmp/pyflate_dwarf.data --stdio --no-children -g none \
        2>/dev/null | head -30
}


stage_flamecmp() {
    say "flame graph comparison: baseline vs optimized"

    local fg
    fg="$(dirname "$(find "$HOME" -name stackcollapse-perf.pl 2>/dev/null \
          | head -1)")"
    if [ ! -x "$fg/stackcollapse-perf.pl" ]; then
        echo "FlameGraph not found; run '$0 setup' first" >&2
        return 1
    fi

    # Both profiles MUST be collected with identical parameters, otherwise
    # the difference between them reflects the collection settings rather
    # than the optimizations. The baseline is therefore regenerated here
    # rather than reusing whatever is already on disk.
    local loops=2 freq=299

    local variant
    for variant in "$BASE_DIR" "$OPT_DIR"; do
        echo "--- profiling $variant ---"
        perf record -e cpu-clock -F "$freq" --call-graph dwarf \
            -o "/tmp/${variant}.data" \
            -- python3-dbg "$REPO/profile_pyflate.py" \
                  --variant "$variant" --loops "$loops"
        perf script -i "/tmp/${variant}.data" > "/tmp/${variant}.perf"
        "$fg/stackcollapse-perf.pl" "/tmp/${variant}.perf" \
            | "$REPO/tools/collapse_interpreter.py" \
            > "/tmp/${variant}.folded"
    done

    # collapse_interpreter.py (see stage_flame) fixes the height. What
    # remains is the rendering threshold, and it has to be expressed in
    # ABSOLUTE time rather than as a percentage.
    #
    # flamegraph.pl's --minwidth is a percentage of the run's OWN total.
    # The optimized run is shorter, so the same percentage is a smaller
    # absolute threshold on that side and admits thinner stacks: the two
    # graphs would then differ in shape because of the rendering
    # setting rather than because of the optimizations, which is exactly
    # what this stage otherwise takes care to avoid.
    #
    # So 1% of the BASELINE is the common threshold, and the optimized
    # percentage is scaled up by the ratio of the totals to land on the
    # same absolute number of nanoseconds.
    local base_total opt_total base_mw opt_mw
    base_total=$(awk '{s+=$NF} END {print s}' "/tmp/$BASE_DIR.folded")
    opt_total=$(awk '{s+=$NF} END {print s}' "/tmp/$OPT_DIR.folded")
    base_mw=1
    opt_mw=$(awk -v b="$base_total" -v o="$opt_total" \
             'BEGIN {printf "%.3f", b/o}')
    echo "minwidth: baseline ${base_mw}%, optimized ${opt_mw}%" \
         "(equal absolute time)"

    local sub="interpreter call frames collapsed; frames under 1% of baseline time omitted"

    "$fg/flamegraph.pl" \
        --title "pyflate BASELINE (cpu-clock, DWARF unwind)" \
        --subtitle "$sub" \
        --minwidth "$base_mw" \
        "/tmp/$BASE_DIR.folded" > "$RESULTS/pyflate_baseline_flame.svg"

    "$fg/flamegraph.pl" \
        --title "pyflate OPTIMIZED (cpu-clock, DWARF unwind)" \
        --subtitle "$sub" \
        --minwidth "$opt_mw" \
        "/tmp/$OPT_DIR.folded" > "$RESULTS/pyflate_optimized_flame.svg"

    # Differential flame graph. Sampling is time-based at a fixed
    # frequency, so sample counts are proportional to elapsed time and
    # the raw (un-normalized) diff shows where time was actually
    # removed. Red means slower, blue means faster.
    "$fg/difffolded.pl" "/tmp/$BASE_DIR.folded" "/tmp/$OPT_DIR.folded" \
        | "$fg/flamegraph.pl" \
            --title "pyflate: optimized vs baseline (blue = time removed)" \
            --subtitle "$sub" \
            --minwidth "$base_mw" \
            --negate \
        > "$RESULTS/pyflate_diff_flame.svg"

    echo
    echo "wrote:"
    ls -la "$RESULTS"/pyflate_baseline_flame.svg \
           "$RESULTS"/pyflate_optimized_flame.svg \
           "$RESULTS"/pyflate_diff_flame.svg

    # stackcollapse-perf.pl sums the cpu-clock PERIOD, which for this
    # event is nanoseconds of CPU time, not a count of samples. That is
    # the more useful quantity here, but it has to be labelled correctly.
    say "cpu-clock time attributed by the profiler"
    local base_ns opt_ns
    base_ns=$(awk '{s+=$NF} END {print s}' "/tmp/$BASE_DIR.folded")
    opt_ns=$(awk '{s+=$NF} END {print s}' "/tmp/$OPT_DIR.folded")
    awk -v b="$base_ns" -v o="$opt_ns" 'BEGIN {
        printf "baseline  : %.3f s\n", b/1e9
        printf "optimized : %.3f s\n", o/1e9
        printf "ratio     : %.1f%% of baseline (%.2fx faster)\n", \
               100*o/b, b/o
    }'
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
        flamecmp)  stage_flamecmp ;;
        hw)        stage_hw ;;
        all)
            stage_baseline
            stage_optimized
            stage_compare
            stage_cprofile
            stage_flame
            stage_flamecmp
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
