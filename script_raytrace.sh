#!/usr/bin/env bash
#
# script_raytrace.sh - reproduce the raytrace half of this project.
#
# Stages can be run individually or all at once:
#
#   ./script_raytrace.sh setup      install dependencies
#   ./script_raytrace.sh baseline   time the pristine benchmark
#   ./script_raytrace.sh optimized  time the optimized benchmark
#   ./script_raytrace.sh compare    statistical comparison of the two
#   ./script_raytrace.sh verify     byte-for-byte output equivalence
#   ./script_raytrace.sh cprofile   per-function profile of both variants
#   ./script_raytrace.sh flame      perf record + flame graph
#   ./script_raytrace.sh flamecmp   baseline vs optimized + diff flame graph
#   ./script_raytrace.sh all        everything except setup
#
# With no argument it runs: baseline, optimized, compare, verify.
#
# Unlike pyflate, raytrace does not check its own output, so the verify
# stage is not optional bookkeeping: it is the only thing standing
# between "faster" and "faster and still correct".

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="$REPO/results"
BASE_DIR="bm_raytrace"
OPT_DIR="bm_raytrace_opt"

# Identical to the pyflate script so that every measurement in the
# project is directly comparable.
PYPERF_ARGS=(-p 10 -w 1 -n 5)

mkdir -p "$RESULTS"

say() { printf '\n=== %s ===\n' "$*"; }


stage_setup() {
    say "installing dependencies"
    sudo apt-get update
    sudo apt-get install -y \
        python3 python3-pip python3-dbg \
        linux-tools-common "linux-tools-$(uname -r)" \
        git

    pip3 install --user pyperf

    if [ ! -d "$HOME/FlameGraph" ]; then
        git clone --depth 1 \
            https://github.com/brendangregg/FlameGraph "$HOME/FlameGraph"
    fi

    sudo sysctl -w kernel.perf_event_paranoid=1 || true
    sudo sysctl -w kernel.kptr_restrict=0 || true
}


stage_baseline() {
    say "baseline: $BASE_DIR"
    python3 "$REPO/$BASE_DIR/run_benchmark.py" \
        -o "$RESULTS/raytrace_baseline.json" "${PYPERF_ARGS[@]}"
}


stage_optimized() {
    say "optimized: $OPT_DIR"
    python3 "$REPO/$OPT_DIR/run_benchmark.py" \
        -o "$RESULTS/raytrace_optimized.json" "${PYPERF_ARGS[@]}"
}


stage_compare() {
    say "comparison"
    python3 -m pyperf compare_to \
        "$RESULTS/raytrace_baseline.json" \
        "$RESULTS/raytrace_optimized.json" \
        --table
}


stage_verify() {
    say "output equivalence"

    # Render one frame from each variant and compare the raw pixels.
    # The optimizations reorder floating-point work only in the sense of
    # not repeating it; no arithmetic is reassociated, so the images are
    # expected to be identical bit for bit, not merely close.
    local base_ppm=/tmp/raytrace_base.ppm
    local opt_ppm=/tmp/raytrace_opt.ppm

    python3 "$REPO/profile_raytrace.py" --variant "$BASE_DIR" \
        --loops 1 --ppm "$base_ppm" >/dev/null
    python3 "$REPO/profile_raytrace.py" --variant "$OPT_DIR" \
        --loops 1 --ppm "$opt_ppm" >/dev/null

    md5sum "$base_ppm" "$opt_ppm"

    if cmp -s "$base_ppm" "$opt_ppm"; then
        echo "IDENTICAL: optimized output matches the baseline exactly"
    else
        echo "DIFFER: optimized output is not equivalent" >&2
        return 1
    fi
}


stage_cprofile() {
    say "cProfile: baseline"
    python3 "$REPO/profile_raytrace.py" --variant "$BASE_DIR" \
        --loops 5 --cprofile --limit 18

    say "cProfile: optimized"
    python3 "$REPO/profile_raytrace.py" --variant "$OPT_DIR" \
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

    # cpu-clock rather than cycles: the QEMU guest exposes no PMU.
    # DWARF rather than frame pointers: on python3-dbg the frame-pointer
    # unwinder reports allocator fill bytes (0xFD / 0xDD) as return
    # addresses, which makes the resulting graph meaningless.
    perf record -e cpu-clock -F 299 --call-graph dwarf \
        -o /tmp/raytrace_dwarf.data \
        -- python3-dbg "$REPO/profile_raytrace.py" \
              --variant "$BASE_DIR" --loops 3

    perf script -i /tmp/raytrace_dwarf.data > /tmp/raytrace.perf
    "$fg/stackcollapse-perf.pl" /tmp/raytrace.perf > /tmp/raytrace.folded
    "$fg/flamegraph.pl" --title "raytrace baseline (cpu-clock, DWARF unwind)" \
        /tmp/raytrace.folded > "$RESULTS/raytrace_baseline_flame.svg"

    echo "wrote $RESULTS/raytrace_baseline_flame.svg"

    say "perf self-time ranking"
    perf report -i /tmp/raytrace_dwarf.data --stdio --no-children -g none \
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

    # Both profiles MUST use identical collection parameters, or the
    # difference between them reflects the settings rather than the
    # optimizations. The baseline is regenerated here for that reason.
    local loops=3 freq=299

    local variant
    for variant in "$BASE_DIR" "$OPT_DIR"; do
        echo "--- profiling $variant ---"
        perf record -e cpu-clock -F "$freq" --call-graph dwarf \
            -o "/tmp/${variant}.data" \
            -- python3-dbg "$REPO/profile_raytrace.py" \
                  --variant "$variant" --loops "$loops"
        perf script -i "/tmp/${variant}.data" > "/tmp/${variant}.perf"
        "$fg/stackcollapse-perf.pl" "/tmp/${variant}.perf" \
            > "/tmp/${variant}.folded"
    done

    "$fg/flamegraph.pl" \
        --title "raytrace BASELINE (cpu-clock, DWARF unwind)" \
        "/tmp/$BASE_DIR.folded" > "$RESULTS/raytrace_baseline_flame.svg"

    "$fg/flamegraph.pl" \
        --title "raytrace OPTIMIZED (cpu-clock, DWARF unwind)" \
        "/tmp/$OPT_DIR.folded" > "$RESULTS/raytrace_optimized_flame.svg"

    # Sampling is time-based at a fixed frequency, so sample counts are
    # proportional to elapsed time and the raw diff shows where time was
    # actually removed rather than merely how the shape shifted.
    "$fg/difffolded.pl" "/tmp/$BASE_DIR.folded" "/tmp/$OPT_DIR.folded" \
        | "$fg/flamegraph.pl" \
            --title "raytrace: optimized vs baseline (blue = time removed)" \
            --negate \
        > "$RESULTS/raytrace_diff_flame.svg"

    echo
    echo "wrote:"
    ls -la "$RESULTS"/raytrace_baseline_flame.svg \
           "$RESULTS"/raytrace_optimized_flame.svg \
           "$RESULTS"/raytrace_diff_flame.svg

    say "sample counts (proportional to elapsed time)"
    printf 'baseline  : %s samples\n' \
        "$(awk '{s+=$NF} END {print s}' "/tmp/$BASE_DIR.folded")"
    printf 'optimized : %s samples\n' \
        "$(awk '{s+=$NF} END {print s}' "/tmp/$OPT_DIR.folded")"
}


main() {
    case "${1:-default}" in
        setup)     stage_setup ;;
        baseline)  stage_baseline ;;
        optimized) stage_optimized ;;
        compare)   stage_compare ;;
        verify)    stage_verify ;;
        cprofile)  stage_cprofile ;;
        flame)     stage_flame ;;
        flamecmp)  stage_flamecmp ;;
        all)
            stage_baseline
            stage_optimized
            stage_compare
            stage_verify
            stage_cprofile
            stage_flame
            stage_flamecmp
            ;;
        default)
            stage_baseline
            stage_optimized
            stage_compare
            stage_verify
            ;;
        *)
            echo "unknown stage: $1" >&2
            sed -n '3,21p' "${BASH_SOURCE[0]}" >&2
            exit 1
            ;;
    esac
}

main "$@"
