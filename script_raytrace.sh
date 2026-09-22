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
#   ./script_raytrace.sh flameraw   unfiltered graph, as the built-in
#                                   perf report would have drawn it
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
    #
    # Frame-pointer unwinding (-g) on the STOCK interpreter. The two
    # choices are tied together and cannot be made separately:
    #
    #   * -g must not be combined with python3-dbg. The debug build
    #     paints memory with 0xFD (PYMEM_FORBIDDENBYTE) and 0xDD
    #     (PYMEM_DEADBYTE), and the frame-pointer unwinder walks that
    #     painted memory and reports the fill bytes as return addresses
    #     (0xfdfdfdfdfd000053 and similar). See section 1b of
    #     results/raytrace_perf_baseline.txt. Those graphs are garbage,
    #     not merely shallow.
    #
    #   * DWARF unwinding needs debug information, which the stock
    #     interpreter does not carry, so dropping python3-dbg means
    #     dropping DWARF with it.
    #
    # What this configuration buys: the profile now measures the same
    # interpreter that produced the headline timings, so the ~12%
    # debug-allocator overhead (_PyMem_DebugCheckAddress, read_size_t,
    # write_size_t) is gone and the perf-attributed speedup should agree
    # with pyperf instead of reading low.
    #
    # What it costs: Ubuntu builds python3 with -fomit-frame-pointer, so
    # there are frequently no frame pointers to walk and stacks come
    # back short, sometimes only the leaf. The stock binary is also
    # stripped, so static internal functions resolve as [unknown].
    # Frame pointers carry no per-sample stack snapshot, which is why
    # the rate and loop count go back up: DWARF forced them down to keep
    # perf.data manageable.
    perf record -e cpu-clock -F 999 -g \
        -o /tmp/raytrace_fp.data \
        -- python3 "$REPO/profile_raytrace.py" \
              --variant "$BASE_DIR" --loops 5

    # The interpreter collapse still applies to whatever call chain does
    # come back. Its measured justification was taken from the DWARF
    # profiles, where reaching one Python call cost a repeating cycle of
    # seven C frames (_PyEval_Vector, _PyEval_EvalFrame,
    # _PyEval_EvalFrameDefault, call_function, PyObject_Vectorcall,
    # _PyObject_VectorcallTstate, _PyFunction_Vectorcall) and
    # _PyEval_Vector appeared 809 times in a 127-row graph. With frame
    # pointers the stacks are shorter, so the filter has less to do, but
    # it is a no-op when the pattern is absent and stays in the pipeline
    # so both stages render identically.
    #
    # stackcollapse-recursive.pl is not a substitute: it merges only
    # ADJACENT duplicate frames, and this is a cycle of seven distinct
    # names. Sample counts are preserved exactly either way.
    #
    # HEIGHT, and the box count that follows from it. Reaching one Python
    # call costs a cycle of seven C frames (_PyEval_Vector,
    # _PyEval_EvalFrame, _PyEval_EvalFrameDefault, call_function,
    # PyObject_Vectorcall, _PyObject_VectorcallTstate,
    # _PyFunction_Vectorcall) and that cycle repeats once per level of
    # Python call depth. Measured on the previous graph: _PyEval_Vector
    # appeared 809 times and the image was 127 rows tall.
    #
    # Sub-1% frames are too thin to carry a label and are most of the
    # file size, so they are dropped rather than rendered.
    local minwidth=1

    perf script -i /tmp/raytrace_fp.data > /tmp/raytrace.perf
    "$fg/stackcollapse-perf.pl" /tmp/raytrace.perf \
        | "$REPO/tools/collapse_interpreter.py" > /tmp/raytrace.folded
    "$fg/flamegraph.pl" \
        --title "raytrace baseline (cpu-clock, frame pointers)" \
        --subtitle "stock python3; frames under ${minwidth}% omitted" \
        --minwidth "$minwidth" \
        /tmp/raytrace.folded > "$RESULTS/raytrace_baseline_flame.svg"

    echo "wrote $RESULTS/raytrace_baseline_flame.svg"

    # How deep the stacks actually came back. With -fomit-frame-pointer
    # this is the number that decides whether the graph is usable, so it
    # is reported rather than left for the reader to discover.
    say "stack depth returned by the unwinder"
    awk -F';' '{d=NF; s+=d; n++; if(d>m)m=d}
               END {printf "mean %.1f frames, max %d, over %d stacks\n", s/n, m, n}' \
        /tmp/raytrace.folded

    say "perf self-time ranking"
    perf report -i /tmp/raytrace_fp.data --stdio --no-children -g none \
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
    #
    # -g on stock python3 rather than DWARF on python3-dbg; see
    # stage_flame for why those two choices are inseparable and what the
    # trade is. Frame pointers store no per-sample stack snapshot, so
    # the rate and loop count are higher than the DWARF runs needed.
    local loops=5 freq=999

    local variant
    for variant in "$BASE_DIR" "$OPT_DIR"; do
        echo "--- profiling $variant ---"
        perf record -e cpu-clock -F "$freq" -g \
            -o "/tmp/${variant}.data" \
            -- python3 "$REPO/profile_raytrace.py" \
                  --variant "$variant" --loops "$loops"
        perf script -i "/tmp/${variant}.data" > "/tmp/${variant}.perf"
        "$fg/stackcollapse-perf.pl" "/tmp/${variant}.perf" \
            | "$REPO/tools/collapse_interpreter.py" \
            > "/tmp/${variant}.folded"

        # Frame pointers may be absent, in which case stacks come back
        # only a frame or two deep and the graph degenerates. Report it
        # per variant so that is visible immediately.
        awk -F';' '{d=NF; s+=d; n++; if(d>m)m=d}
                   END {printf "  %d stacks, mean depth %.1f, max %d\n",
                                n, s/n, m}' "/tmp/${variant}.folded"
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
    # what this stage otherwise takes care to avoid. Measured with a
    # flat 1%: baseline 6.706 s rendered 40 rows, optimized 3.799 s
    # rendered 73.
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

    local sub="stock python3; frames under 1% of baseline time omitted"

    "$fg/flamegraph.pl" \
        --title "raytrace BASELINE (cpu-clock, frame pointers)" \
        --subtitle "$sub" \
        --minwidth "$base_mw" \
        "/tmp/$BASE_DIR.folded" > "$RESULTS/raytrace_baseline_flame.svg"

    "$fg/flamegraph.pl" \
        --title "raytrace OPTIMIZED (cpu-clock, frame pointers)" \
        --subtitle "$sub" \
        --minwidth "$opt_mw" \
        "/tmp/$OPT_DIR.folded" > "$RESULTS/raytrace_optimized_flame.svg"

    # Sampling is time-based at a fixed frequency, so sample counts are
    # proportional to elapsed time and the raw diff shows where time was
    # actually removed rather than merely how the shape shifted.
    "$fg/difffolded.pl" "/tmp/$BASE_DIR.folded" "/tmp/$OPT_DIR.folded" \
        | "$fg/flamegraph.pl" \
            --title "raytrace: optimized vs baseline (blue = time removed)" \
            --subtitle "$sub" \
            --minwidth "$base_mw" \
            --negate \
        > "$RESULTS/raytrace_diff_flame.svg"

    echo
    echo "wrote:"
    ls -la "$RESULTS"/raytrace_baseline_flame.svg \
           "$RESULTS"/raytrace_optimized_flame.svg \
           "$RESULTS"/raytrace_diff_flame.svg

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


stage_flameraw() {
    say "unfiltered flame graph"

    local fg
    fg="$(dirname "$(find "$HOME" -name stackcollapse-perf.pl 2>/dev/null \
          | head -1)")"
    if [ ! -x "$fg/stackcollapse-perf.pl" ]; then
        echo "FlameGraph not found; run '$0 setup' first" >&2
        return 1
    fi

    # The course slides show perf's built-in shortcut:
    #
    #     perf record -a -g -F 99 sleep 60
    #     perf script report flamegraph
    #
    # That report cannot run in this VM. perf is not linked against
    # libpython, so it executes no Python report scripts at all;
    # /usr/libexec/perf-core/scripts does not exist; and the template
    # package the report needs (libjs-d3-flame-graph) is not in the
    # archive. Only the last of those is installable, and it is useless
    # without the first, so the literal command would require building
    # perf from source against libpython.
    #
    # The renderer is not the interesting difference anyway. The
    # built-in draws whatever perf script emits, with no frame folding
    # and no width threshold, while flamecmp applies both. So this
    # stage reproduces what the built-in would have SHOWN by dropping
    # those two processing steps and changing nothing else. That is
    # also the form the slide's own screenshot is in: the image on it
    # is a flamegraph.pl SVG, not perf's HTML output.
    #
    # Two departures from the slide's flags, both forced rather than
    # chosen:
    #
    #   -e cpu-clock  the guest exposes no PMU, so the default cycles
    #                 event returns zero samples; see stage_flame.
    #   no -a         the slide samples the whole system for a fixed
    #                 60 s. The subject here is a single process that
    #                 runs to completion, so perf follows that process
    #                 and there is nothing to time-box.
    #
    # -F 999 rather than 99 follows from the same reasoning: 99 Hz for
    # the slide's 60 s is roughly 6000 samples, and this benchmark
    # finishes in a few seconds, so the rate has to rise by about the
    # same factor to land on a comparable number.
    local variant
    for variant in "$BASE_DIR" "$OPT_DIR"; do
        echo "--- profiling $variant ---"
        perf record -e cpu-clock -F 999 -g \
            -o "/tmp/${variant}_raw.data" \
            -- python3 "$REPO/profile_raytrace.py" \
                  --variant "$variant" --loops 5

        # No collapse_interpreter.py in the pipe, and no --minwidth on
        # the renderer below. Those two omissions are the entire point
        # of the stage, so they are deliberate, not oversights.
        perf script -i "/tmp/${variant}_raw.data" \
            | "$fg/stackcollapse-perf.pl" > "/tmp/${variant}_raw.folded"
    done

    local sub="every frame as perf reports it: no folding, no width filter"

    "$fg/flamegraph.pl" \
        --title "raytrace BASELINE (unfiltered, cpu-clock)" \
        --subtitle "$sub" \
        "/tmp/${BASE_DIR}_raw.folded" \
        > "$RESULTS/raytrace_baseline_flame_raw.svg"

    "$fg/flamegraph.pl" \
        --title "raytrace OPTIMIZED (unfiltered, cpu-clock)" \
        --subtitle "$sub" \
        "/tmp/${OPT_DIR}_raw.folded" \
        > "$RESULTS/raytrace_optimized_flame_raw.svg"

    echo
    echo "wrote:"
    ls -la "$RESULTS"/raytrace_baseline_flame_raw.svg \
           "$RESULTS"/raytrace_optimized_flame_raw.svg

    # The processed graphs sit beside these, so the cost of leaving the
    # stacks unprocessed is worth stating in numbers rather than
    # leaving to the eye: distinct frames drive the box count and the
    # file size, and depth drives the height.
    say "what the processing steps remove"
    local v
    for v in "$BASE_DIR" "$OPT_DIR"; do
        # The trailing " <count>" belongs to the leaf frame, not to the
        # frame name, so it comes off before the stack is split.
        awk -v tag="$v" \
            '{sub(/ [0-9]+$/, ""); d=split($0, p, ";")
              s+=d; n++; if(d>m)m=d
              for(i=1;i<=d;i++) if(!(p[i] in f)) {f[p[i]]=1; u++}}
             END {printf "%-18s mean depth %.1f, max %d, %d distinct frames\n",
                          tag, s/n, m, u}' "/tmp/${v}_raw.folded"
    done
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
        flameraw)  stage_flameraw ;;
        all)
            stage_baseline
            stage_optimized
            stage_compare
            stage_verify
            stage_cprofile
            stage_flame
            stage_flamecmp
            stage_flameraw
            ;;
        default)
            stage_baseline
            stage_optimized
            stage_compare
            stage_verify
            ;;
        *)
            echo "unknown stage: $1" >&2
            sed -n '3,23p' "${BASH_SOURCE[0]}" >&2
            exit 1
            ;;
    esac
}

main "$@"
