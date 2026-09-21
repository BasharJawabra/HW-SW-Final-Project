# HW/SW Project: Benchmark Optimization, Analysis and Hardware Acceleration

Optimization of two `pyperformance` benchmarks, **raytrace** and **pyflate**,
followed by a SystemVerilog hardware accelerator for the bottleneck that
software optimization could not remove.

| Benchmark | Baseline | Optimized | Speedup | Correctness |
|---|---|---|---|---|
| raytrace | 800 ms | 498 ms | **1.60x** | rendered output byte-identical |
| pyflate | 1.12 s | 696 ms | **1.61x** | bundled MD5 gate + 24,000 differential decode tests |

Plus a canonical Huffman decoder in SystemVerilog, simulated at **1.02 cycles
per symbol**, estimated to give a further **~2.0x** on pyflate for roughly
**3.2x** overall.

Full write-ups: [`report_raytrace.txt`](report_raytrace.txt) and
[`report_pyflate.txt`](report_pyflate.txt).

---

## Quick start

```bash
./script_raytrace.sh      # baseline, optimized, compare, verify output
./script_pyflate.sh       # baseline, optimized, compare
./script_pyflate.sh hw    # regenerate vectors, compile and simulate the RTL
```

Each script is staged, so slow steps can be run on their own:

```bash
./script_raytrace.sh flame     # perf record + flame graph (slow)
./script_pyflate.sh cprofile   # per-function profile of both variants
```

Run `./script_pyflate.sh bogus` to print the stage list.

### Dependencies

On a fresh machine:

```bash
./script_pyflate.sh setup
```

This installs `python3-dbg`, `linux-tools`, `iverilog`, `pyperf` and clones
FlameGraph. It uses `sudo`; skip it if you are already root and the tools are
present.

`python3-dbg` is required for profiling specifically: the stock interpreter is
stripped, and DWARF unwinding needs its debug information.

---

## Repository structure

### Benchmarks

Each benchmark is kept twice. The `_opt` directory starts as a byte-identical
copy of the pristine pyperformance source, and every optimization is applied to
it as a separate commit. Keeping the original means any measurement can be
re-run and any claim re-checked.

```
bm_raytrace/          pristine pyperformance source
bm_raytrace_opt/      optimized (3 changes)
bm_pyflate/           pristine pyperformance source, with test data
bm_pyflate_opt/       optimized (5 changes)
```

### Reports and scripts

```
report_raytrace.txt   full write-up: analysis, optimizations, hardware decision
report_pyflate.txt    full write-up: analysis, optimizations, hardware proposal
script_raytrace.sh    reproduces every raytrace measurement
script_pyflate.sh     reproduces every pyflate measurement and the simulation
presentation_outline.md   talk structure and anticipated questions
```

### Profiling drivers

```
profile_raytrace.py   single-shot driver: --variant, --cprofile, --ppm
profile_pyflate.py    single-shot driver: --variant, --cprofile
```

`pyperf` forks a new worker process per measured value, which scatters `perf`
samples across short-lived children. These drivers run the identical workload
in one long-lived process so a profile can be attributed. `--variant` selects
which copy of the benchmark to load, so both are profiled through an identical
harness.

### Hardware

```
hw/huffman_decoder.sv      the accelerator
hw/huffman_decoder_tb.sv   testbench
hw/gen_test_vectors.py     generates vectors from the Python implementation
hw/vectors/*.hex           generated stimulus and expected results
hw/block_diagram.txt       ASCII block diagrams
hw/block_diagram.svg       the same diagrams as SVG
```

```bash
iverilog -g2012 -o /tmp/hd_tb hw/huffman_decoder.sv hw/huffman_decoder_tb.sv
vvp /tmp/hd_tb                 # sink always ready
vvp /tmp/hd_tb +backpressure   # sink stalls ~25% of cycles
```

Run from the repository root — the testbench loads its vectors by relative
path.

### Results

Every measurement is recorded at the time it was taken, one file per step.

```
results/optimization_summary.txt          START HERE: both benchmarks, every
                                          step, predicted vs measured

results/raytrace_baseline.txt             timing and environment
results/raytrace_cprofile_baseline.txt    hotspot analysis
results/raytrace_perf_baseline.txt        perf profile, C-level
results/raytrace_opt1..3_comparison.txt   one per optimization

results/pyflate_baseline.txt              timing and hotspot analysis
results/pyflate_perf_baseline.txt         perf profile, C-level
results/pyflate_opt1..5_comparison.txt    one per optimization
results/pyflate_accel_analysis.txt        speedup estimate for the hardware
results/huffman_sim.txt                   accelerator verification
```

Flame graphs, three per benchmark, all from `perf`:

```
results/<name>_baseline_flame.svg         before
results/<name>_optimized_flame.svg        after
results/<name>_diff_flame.svg             differential
```

These are collected with `perf record -e cpu-clock --call-graph dwarf` and
rendered with Brendan Gregg's `flamegraph.pl`. Two things about them need
stating up front, because both look like defects otherwise.

They are collected with frame-pointer unwinding (`-g`) against the **stock**
`python3`, not DWARF against `python3-dbg`. Those two choices are inseparable:
DWARF needs debug information that only the debug build carries, and `-g` on
the debug build is actively broken, because the frame-pointer unwinder walks
the allocator's `0xFD`/`0xDD` paint bytes and reports them as return addresses
(section 1b of `results/raytrace_perf_baseline.txt`). Profiling the stock build
removes the ~12% debug-allocator overhead, which is why perf now reports 1.59x
for both benchmarks against pyperf's 1.60x and 1.61x, where the debug build
read 1.54x. The cost is that Ubuntu compiles `python3` with
`-fomit-frame-pointer`, so some stacks unwind into runs of unresolvable frames;
those are collapsed to a single `[unresolved]` frame and account for 2.6–4.6%
of self time.

They show **C-level interpreter symbols, not Python function names.** CPython
3.10 predates the `perf` trampoline support added in 3.12, so `perf` cannot
attribute a sample to a Python function — it sees only the interpreter's own
C stack. `cProfile` supplies the Python-level attribution instead, in
`results/<name>_cprofile_baseline.txt`, and the two are cross-checked against
each other in `results/<name>_perf_baseline.txt`.

They are **post-processed to be readable**, by `tools/collapse_interpreter.py`.
Reaching one Python call costs a cycle of seven C frames — `_PyEval_Vector`,
`_PyEval_EvalFrame`, `_PyEval_EvalFrameDefault`, `call_function`,
`PyObject_Vectorcall`, `_PyObject_VectorcallTstate`, `_PyFunction_Vectorcall` —
repeated once per level of Python call depth. Unprocessed, the raytrace
baseline was 127 rows tall with `_PyEval_Vector` appearing 809 times, and
9,525 boxes of which 92% were too narrow to label. The tool folds each run of
that plumbing into a single `[python call]` frame, which also merges identical
leaves that were previously scattered across hundreds of spine depths, so
`frame_dealloc` and the `pymalloc` functions become single wide labelled boxes.
Sample counts are preserved exactly; `--minwidth 1` then drops the residual
unlabelable slivers.

`stackcollapse-recursive.pl` from the FlameGraph toolkit does not help here: it
merges only *adjacent* duplicate frames, and this is a cycle of seven distinct
names. Per-symbol self time is unaffected and remains in the `perf report`
output saved in `results/<name>_perf_baseline.txt`.

That C-level view is not merely a fallback: it is the *only* view that can show
frame-allocation cost — `call_function`, `frame_dealloc`,
`_PyEval_MakeFrameVector` — and that ~10.9% is what drove every raytrace
optimization toward eliminating calls rather than improving arithmetic. A
Python-level profiler cannot show it, because frame allocation is not a Python
function.

Regenerate with `./script_<name>.sh flamecmp`, which collects both profiles
with identical parameters — a differential graph is only meaningful if the two
sides differ by the optimizations rather than by the collection settings.

In the differential graphs, width is time and colour is the change: **blue
means time removed**, red means time added. The profiles are deliberately not
normalized, so the blue area is real time deleted. Some red is expected — the
length-indexed Huffman decode adds dictionary work even as it removes the table
scan.

Note that the flame graphs are collected under `python3-dbg` and their ratios
are **not** the benchmark speedups: the debug allocator inflates the value of
optimizations that work by not allocating, which makes raytrace look 1.79x
there against 1.60x in reality. `results/optimization_summary.txt` explains
this. Quote the `pyperf` numbers; treat the graphs as qualitative.

Each `*_comparison.txt` records the change, the predicted gain, the measured
gain, and the correctness evidence — including the cases where the prediction
was wrong and why.

### Tests

```
tests/test_huffman_equivalence.py
```

```bash
python3 tests/test_huffman_equivalence.py
```

The bundled pyflate data is bzip2, which only decodes with `reversed=False`, so
the benchmark's own MD5 check cannot exercise the `reversed=True` path that
DEFLATE uses. This test drives the original and optimized decoders with
identical random tables and bit patterns in both directions, requiring
agreement on the returned symbol, the bits consumed, and whether the lookup
raised.

---

## What was changed

### raytrace — 1.60x

| # | Change | Gain |
|---|---|---|
| 1 | Hoist the loop-invariant shadow ray out of `_lightIsVisible` | 22.2% |
| 2 | Remove no-op `mustBeVector` / `isPoint` assertions | 7.9% |
| 3 | `__slots__` on `Vector`, `Point`, `Ray`, `Sphere`, `Halfspace` | 13.3% |

None of these touches the arithmetic. Profiling found 3.1 million Python
function calls per 100x100 frame, with ~11% of `perf` self time in frame setup
and teardown, so the program was bottlenecked on calling functions rather than
on the work the functions did.

### pyflate — 1.61x

| # | Change | Gain |
|---|---|---|
| 1 | Inline the `_mask` bit-mask helper (655,017 calls removed) | 6.3% |
| 2 | Rewrite `move_to_front` as `l.insert(0, l.pop(c))` | 16.8% |
| 3 | Length-indexed Huffman decode instead of a linear scan | 7.6% |
| 4 | Hoist `len()` out of the RLE loop, index instead of slicing | 7.6% |
| 5 | Batch literal spans instead of appending single bytes | 6.5% |

---

## The hardware accelerator

After the software work, Huffman decode's share of pyflate's runtime went **up**
— from 49% to about 50% — because the other four optimizations removed
proportionally more from everything else. A component that stays expensive after
a serious software effort is a better hardware candidate than one that merely
looked expensive beforehand.

`pyflate` assigns Huffman codes canonically, so no codes need to be stored or
compared. For a candidate taken from the top L bits of the stream, a length-L
code matches exactly when

```
cand - first_code[L] < count[L]
```

one subtraction and one comparison. All 20 permitted lengths are evaluated
concurrently, which is unambiguous because a Huffman code is prefix-free.

Verified against vectors generated from the Python implementation itself, so a
passing simulation shows the hardware and software agree rather than showing the
hardware matches a hand-written guess:

```
sink always ready    230 symbols, 234 cycles, 1.02 cycles/symbol, PASS
sink stalling ~25%   230 symbols, 305 cycles, 1.33 cycles/symbol, PASS
```

This is simulation, not synthesis. The 200 MHz figure in the report is an
argument from the critical path; no timing or area report exists.

For raytrace the recommendation is *against* building an accelerator, and
[`report_raytrace.txt`](report_raytrace.txt) section 5 explains why: a
dot-product unit would remove five floating-point operations per call while
leaving the interpreter overhead that actually dominates.

---

## Environment

Measurements were taken in a QEMU/KVM guest:

```
Ubuntu 22.04.5 LTS, kernel 5.15.0-1106-kvm x86_64
Python 3.10.12, pyperf 2.10.0
perf 5.15.209, python3-dbg 3.10.12
Icarus Verilog 11.0 (stable)
```

Two constraints of that environment shaped the profiling and are documented in
the reports rather than worked around silently:

- **No PMU is exposed to the guest**, so `perf`'s hardware `cycles` event
  collects zero samples. All profiling uses the `cpu-clock` software event,
  which measures elapsed time rather than retired cycles. No IPC or cache-miss
  data is available.
- **CPython 3.10 has no `perf` trampoline support** (added in 3.12), so `perf`
  cannot see Python-level functions at all. The flame graphs show interpreter
  internals; `cProfile` supplies the Python-level attribution. The two are
  cross-checked against each other in both reports.

All measurements use the same `pyperf` configuration, `-p 10 -w 1 -n 5`, so
figures from different stages are directly comparable.
