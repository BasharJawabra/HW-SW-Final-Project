# Presentation Outline

20–25 minutes of material, 5–10 minutes of questions.

The structure follows the project's actual arc, which is also what the brief
recommends. The through-line worth holding onto: **profiling tells you not only
where the time goes but what kind of work it is, and the second question is the
one that decides whether hardware can help.** Raytrace and pyflate land on
opposite sides of that question, which is why the talk has a point beyond
"we made two things faster".

Timings are speaking time, not slide count. Assume ~22 minutes of delivery so
there's slack.

---

## Part 0 — Framing (2 min)

**Slide 1: Title**
Name, course, the two benchmarks.

**Slide 2: Results first**

| | Baseline | Optimized | Speedup |
|---|---|---|---|
| raytrace | 800 ms | 498 ms | 1.60x |
| pyflate | 1.12 s | 696 ms | 1.61x |

Plus: Huffman accelerator in SystemVerilog, 1.02 cycles/symbol simulated,
~2.0x further on pyflate → ~3.2x overall.

> Lead with the numbers. The audience can then spend the whole talk
> understanding *how*, instead of waiting to find out *whether*.

---

## Part 1 — Methodology (3 min)

**Slide 3: How everything was measured**

- `pyperf -p 10 -w 1 -n 5`, identical for every measurement in the project
- Each benchmark forked into `bm_*_opt/`, byte-identical at the start
- One optimization per commit, measured in isolation
- Every claim has a file in `results/` written when the measurement was taken

> Say why the fork matters: any number in the report can be re-derived, and a
> later change can't silently invalidate an earlier measurement.

**Slide 4: Two constraints that shaped everything**

This slide earns credibility. Don't skip it.

1. **The QEMU guest exposes no PMU.** `perf`'s hardware `cycles` event returns
   *zero samples*. Everything runs on the `cpu-clock` software event, which
   measures elapsed **time**, not retired cycles — no IPC, no cache misses.
2. **CPython 3.10 has no `perf` trampoline support** (added in 3.12). `perf`
   literally cannot see a Python function. Our flame graph has 577 frames and
   not one is a pyflate function.

> The honest framing: this is why the project uses *two* profilers. cProfile
> gives Python-level attribution; perf gives C-level "what kind of work".
> Neither alone would be convincing. They agree, and that agreement is the
> evidence.

**Slide 5 (optional, only if time is comfortable): the DWARF detour**

Frame-pointer unwinding on `python3-dbg` produced return addresses like
`0xfdfdfdfdfd000053`. Those aren't addresses — a debug build paints freed
memory with `0xFD`/`0xDD`, and the unwinder was reporting fill bytes as stack
frames. Switched to DWARF unwinding.

> Good slide to have ready as a backup answer rather than to present, unless
> you're running early.

---

## Part 2 — Raytrace (5 min)

**Slide 6: What it is**
100×100 ray-traced image. Pure Python, `math.sqrt` is the only library call in
the hot path. Per pixel: cast ray → nearest object → shade → shadow ray per
light, looping over every object.

**Slide 7: The baseline profile**

```
2,549,355  Vector.dot
1,389,325  Point.__sub__
2,264,715  Vector.__init__
2,602,695  Vector.mustBeVector
```

**3.1 million Python function calls per frame.** `math.sqrt`: 584,105 calls —
the only transcendental work in the entire render.

**Slide 8: What perf added**

```
call_function            3.44%
frame_dealloc            3.37%
_PyEval_MakeFrameVector  2.99%
_PyFrame_New_NoTrack     1.13%
-------------------------------
~10.9% in call/frame machinery
```

> **This is the pivot of the whole talk.** The program is bottlenecked on the
> cost of *calling* functions, not on the work the functions do. So the
> optimizations that pay are the ones that eliminate calls. Say this sentence
> out loud; everything in Part 2 and Part 5 follows from it.

**Slide 9: Three optimizations, none of them arithmetic**

| Change | Gain |
|---|---|
| Hoist loop-invariant shadow ray out of `_lightIsVisible` | 22.2% |
| Delete no-op `mustBeVector` / `isPoint` assertions (~4M calls) | 7.9% |
| `__slots__` on the geometry classes | 13.3% |

Show the shadow-ray diff — it's three lines and it's the biggest win.

> Worth emphasising on #1: the cost isn't one allocation. `Ray.__init__`
> normalizes, so each redundant construction drags in `Point.__sub__`,
> `normalized`, `magnitude`, `sqrt` and `scale`. One hoisted line deletes a
> subtree.

**Slide 10: Correctness**
Raytrace does **not** check its own output — a broken renderer just draws the
wrong picture quickly. So: render from both variants, compare raw pixels.

```
f3c700588a9b6320fb1e46027142f205  base.ppm
f3c700588a9b6320fb1e46027142f205  opt.ppm
```

Byte-identical, not approximately equal — none of the three changes
reassociates arithmetic, so any difference at all would be a bug.

---

## Part 3 — Pyflate (5 min)

**Slide 11: What it is**
Pure-Python bzip2 decompressor. Deliberately does *not* call `bz2` or `zlib`.
Path: bit reader → Huffman decode per symbol → MTF → inverse BWT → RLE.

> Pre-empt the obvious question: "why not just use `zlib`?" Because that
> defeats the benchmark. There is no library swap available here — every gain
> has to come from how the Python is written.

**Slide 12: The baseline profile**

```
148,271  find_next_symbol     1.052s cum  (~49% of decode)
655,017  _mask                one-line helper
 92,803  move_to_front        l[:] = l[c:c+1] + l[0:c] + l[c+1:]
674,570  len()
```

**Slide 13: The author started this optimization and abandoned it**

- `tables_by_bits` builds a length-keyed dict and **never returns it**
- `find_next_symbol` contains a length-indexed loop placed **after an
  unconditional `raise`** — unreachable
- `min_max_bits` *is* called, so the groundwork is present and unused

> A nice moment in the talk: the intended design was already visible in the
> source. Optimization 3 finishes what the author left.

**Slide 14: Five optimizations**

| Change | Gain |
|---|---|
| Inline the `_mask` helper (655,017 calls) | 6.3% |
| `move_to_front` → `l.insert(0, l.pop(c))` | 16.8% |
| Length-indexed Huffman decode | 7.6% |
| Hoist `len()` out of the RLE loop | 7.6% |
| Batch literal spans | 6.5% |

**Slide 15: Where the estimates were wrong (keep this slide)**

- `move_to_front`: predicted 4–8%, **measured 16.8%**. The prediction used its
  own self time and missed the allocator/GC work its three temporaries created
  *elsewhere* — visible in perf as `list_dealloc` and `_PyObject_Malloc`,
  attributed by cProfile to no single function.
- Huffman decode: predicted 15–25%, **measured 7.6%**. The 49% figure was
  *cumulative* time, which includes the `snoopbits`/`readbits` calls it makes.
  The new code eliminates the scan, not the bit reading. The right number was
  its **self** time, 15.5%.

> Showing a wrong prediction and explaining it is worth more than showing only
> the ones that landed. It also sets up the hardware proposal directly — see
> the next part.

**Slide 16: Correctness**
The benchmark self-verifies with MD5 — but the bundled data is bzip2, which
only decodes with `reversed=False`. The DEFLATE path (`reversed=True`) is
**never exercised**, so a wrong answer there would pass silently.

Hence `tests/test_huffman_equivalence.py`: drives both implementations with
identical random tables in both directions.

```
compared 24000 decode attempts across both directions
no mismatches
```

---

## Part 4 — The finding that motivated the hardware (2 min)

**Slide 17: Optimizing it made it bigger**

```
find_next_symbol's share of runtime
    baseline    49.3%
    optimized   50.1%   (corrected for profiler overhead)
```

Huffman decode's share went **up** after we optimized it — because the other
four optimizations removed proportionally more from everything else.

> This is Amdahl's law read in reverse, and it's the strongest argument in the
> project: **the bottleneck worth building hardware for is the one that
> survives a serious software effort.** A component that merely looked
> expensive before anyone tried is a much weaker candidate.

Mention the correction honestly: raw cProfile says 56.4%, but 6.63M of the
run's 10.81M calls are in that subtree and cProfile charges ~0.412 µs per call.
Corrected: ~50%. Quote it as "about half".

---

## Part 5 — Hardware (6 min)

**Slide 18: Why pyflate and not raytrace**

Raytrace *looks* like the ideal accelerator target — 2.5M dot products, a
classic MAC workload. It isn't.

`Vector.dot` is 3 multiplies and 2 adds. What costs is the 2,549,355 ×
(frame alloc + locals vector + attribute lookups + teardown) *around* them. A
perfect dot-product unit removes the 5 operations and none of the overhead —
and the C API call to reach it costs more than the multiplies it replaces.

Even granting a free unit: f ≈ 0.12 → **1.14x ceiling**, versus 1.29x from
hoisting one line.

> The evidence is that our three raytrace optimizations contain **zero**
> arithmetic improvements. The benchmark responded to call elimination. It
> would not have responded to faster floating point.

**Slide 19: The idea**

pyflate assigns codes **canonically** — for each length, codes are consecutive
integers from `first_code[L]`. So no codes need storing or comparing:

```
match  ⟺  cand - first_code[L] < count[L]
symbol =  base_index[L] + (cand - first_code[L])
```

One subtract, one compare. **All 20 lengths tested concurrently** — unambiguous
because a Huffman code is prefix-free, so at most one can match.

> The software searches because it discovers the length by trying lengths in
> turn. The hardware doesn't search at all. That's the whole design.

**Slide 20: Block diagram**
Use `hw/block_diagram.svg`. Walk it: bit buffer → parallel compare → arbiter →
symbol RAM → EOB detect, with group control switching tables every 50 symbols
autonomously.

**Slide 21: The integration constraint that decides everything**

Symbols must leave by **DMA in bulk**.

Per-symbol memory-mapped reads would mean ~148,271 Python-level accesses per
decompression. At 1 µs each that's ~148 ms — most of the ~345 ms the
accelerator was supposed to save. *The decoder would be fast and the system
would not be.*

> Say plainly: this is a software-side constraint, not a hardware one, and it's
> the thing most likely to sink a real deployment.

**Slide 22: Verification**

Vectors are generated **from the Python implementation itself** — real
`OrderedHuffmanTable` objects, encoded with the exact inverse of
`populate_huffman_symbols`. So a pass shows hardware and software *agree*,
not that hardware matches a hand-written guess.

```
sink always ready    230 symbols, 234 cycles, 1.02 cycles/symbol, PASS
sink stalling ~25%   230 symbols, 305 cycles, 1.33 cycles/symbol, PASS
final_bit_pos exact in both: 1359 of 1359 bits
```

Two groups alternating every 50 symbols, so table switching is actually
exercised.

**Slide 23: A bug worth admitting**

The first generator drew code lengths **at random**. A Python round-trip
decoded 231 bits for 231 symbols — one bit each.

Random lengths don't satisfy the **Kraft equality**, so canonical assignment
over them isn't prefix-free: a 1-bit code can prefix a longer one and
shortest-match always takes it. *The decoder was correct; the stimulus was
meaningless.* Fixed by building a real Huffman tree and asserting
`Σ 2^-L = 1`.

> Strong slide. It shows the verification flow caught a problem before the
> simulator did, and that you understand why Huffman lengths aren't arbitrary.

**Slide 24: Expected speedup and trade-offs**

At 1.02 cycles/symbol, 148,271 symbols cost **0.76 ms at 200 MHz** — against
~345 ms of remaining software. Even at 100 MHz it's under half a percent.

**Bounded by Amdahl, not by the hardware.** f ≈ 0.50 → **2.0x**.

Trade-offs, briefly: ~2,000 LUTs and ~14.3 KB memory (85% of which is the
selector list, sized for bzip2's worst case). The parallel-all-lengths choice
costs 20 comparators to save 19 cycles — and a sequential version would *still*
be fast enough, so this is a genuine choice the workload doesn't force.

---

## Part 6 — Conclusion (2 min)

**Slide 25: What was learned**

- Both benchmarks: **1.6x**, correctness proven not assumed
- Hardware: ~2.0x further on pyflate, ~3.2x overall
- Raytrace was bottlenecked on *calling functions*; pyflate on *sequential
  bit-serial search*. Same profile shape, opposite conclusions about hardware.
- Optimizing Huffman decode **raised** its share of runtime — which is what
  identified it as the right hardware target.

**Slide 26: Honest limits**

State these before you're asked:

- The hardware is **simulated, not synthesized**. 200 MHz is an argument from
  the critical path; area figures are estimates. No timing report exists.
- Error path never driven with a malformed stream; only 2 of 6 groups tested;
  code lengths outside 4–10 untested; no real bzip2 stream run end-to-end
  through the RTL.
- The ~2.0x depends on the bulk-DMA assumption in slide 21.
- Profiling used `cpu-clock`, so all of it is time, not cycles.

> Volunteering limits is the single easiest way to look like you understand
> your own work. It also defuses most of the hostile questions.

---

## Anticipated questions

**"Why did Huffman decode's share go *up* after you optimized it?"**
Because the other four optimizations removed proportionally more from
everything else. Absolute Huffman time fell; the denominator fell faster.
That's Amdahl's law, and it's exactly why it became the hardware target.

**"Why not just call `zlib` / `bz2`?"**
It would defeat the benchmark, which exists to measure interpreter throughput
on pure-Python bit manipulation. There's no library swap available — every gain
had to come from how the Python is written.

**"Your Huffman optimization only gained 7.6% but you said it was 49% of
runtime."**
49% was *cumulative* time, including the `snoopbits`/`readbits` calls it makes.
The optimization removed the table scan, not the bit reading. Self time was
15.5%, and 7.6% sits sensibly below that. It's also precisely why the hardware
targets the bit reader and the decode *together* — in hardware they're one
operation.

**"Why is raytrace not a good hardware candidate? It's ray tracing."**
Because its cost is interpreter overhead, not arithmetic. `Vector.dot` is 5
floating-point ops surrounded by frame setup, attribute lookup and teardown. A
perfect accelerator removes the 5 ops and none of the overhead. Evidence: all
three of our raytrace optimizations eliminate *calls*, and none touches the
arithmetic.

**"How do you know the hardware is correct?"**
The test vectors are generated from the Python implementation itself, so the
simulation compares hardware against software rather than against my
expectations. 230 symbols across two alternating Huffman groups, correct under
output backpressure, with `final_bit_pos` exact.

**"What's `final_bit_pos` and why does it matter?"**
The decoder is pipelined, so when EOB retires, stage 1 has already consumed
bits for the code behind it. Reporting the current position would put software
mid-code at every block boundary. We report the position after EOB itself, and
the testbench checks it numerically — that's why the expected bit count is in
the vector metadata.

**"Would this actually be faster in a real system?"**
Only if decoded symbols cross into Python in bulk. Per-symbol MMIO reads would
cost ~148 ms of Python-level access and eat most of the saving. That's the
main integration risk and it's on the software side.

**"Why 200 MHz?"**
It's an argument from the critical path — peek, 20 parallel compares, arbiter,
64-bit barrel shift — not a synthesis result. It also doesn't matter much: at
100 MHz the decoder is still under half a percent of the new runtime. If timing
closure failed, retime the barrel shift into its own stage: one more cycle of
latency, same throughput.

**"What would you do next?"**
Synthesize it for real numbers; drive the error path and the 1-bit/20-bit
length extremes; run a real bzip2 stream end-to-end through the RTL. On the
software side, `bwt_transform` still sorts the block and does 256 `bytes.find`
calls where a histogram plus prefix sum would do — documented and deliberately
left, because it was worth less than the changes we made.

---

## Practical notes

- **Have the code open**, not on slides. The brief says don't put it all in the
  deck, but you'll be asked to show something — likely the shadow-ray hoist,
  `find_next_symbol`, or the parallel compare loop in the RTL.
- **Be ready to run the simulation live.** `./script_pyflate.sh hw` takes
  seconds and produces `RESULT: PASS` twice. It's the most convincing 30
  seconds available to you.
- **Know the three numbers cold**: 1.60x, 1.61x, 1.02 cycles/symbol.
- If you're running long, cut slides 5 and 13 — they're the most enjoyable and
  the least load-bearing.
