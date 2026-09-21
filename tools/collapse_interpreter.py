#!/usr/bin/env python3
"""Collapse CPython's call plumbing and unresolved towers in folded stacks.

Reads folded stacks (the output of stackcollapse-perf.pl) on stdin and
writes folded stacks on stdout, so it drops into a flame graph pipeline
between stackcollapse-perf.pl and flamegraph.pl.

WHY

CPython 3.10 has no perf trampoline support (that arrived in 3.12), so
perf cannot name a Python function and instead records the interpreter's
own C stack. Reaching one Python call costs a cycle of seven C frames:

    _PyEval_Vector
    _PyEval_EvalFrame
    _PyEval_EvalFrameDefault
    call_function
    PyObject_Vectorcall
    _PyObject_VectorcallTstate
    _PyFunction_Vectorcall

and that cycle repeats once per level of Python call depth. In the
raytrace baseline profile _PyEval_Vector appeared 809 times and the
graph was 127 rows tall.

Nothing in the standard FlameGraph toolkit fixes this.
stackcollapse-recursive.pl merges only ADJACENT duplicate frames, and
this pattern is a cycle of seven distinct names, so it collapses
nothing.

WHAT THIS DOES

Every run of consecutive plumbing frames becomes a single frame named
[python call]. Two things follow:

  * Height. The repeating spine flattens to one frame, so the leaves
    that represent actual work sit near the root where they are
    readable.

  * Box count. Leaves previously scattered across hundreds of distinct
    spine depths now share one parent, so identical leaves merge into
    one wide labelled box instead of hundreds of unlabelable slivers.
    This is what shrinks the SVG.

Sample counts are preserved exactly: stacks that collapse to the same
string have their counts summed, and no sample is dropped.

WHAT IS DELIBERATELY NOT COLLAPSED

Only call plumbing is folded away. Frames that represent real work stay
separate and therefore become more visible, not less, because they
aggregate: frame_dealloc, _PyEval_MakeFrameVector, the pymalloc
functions, and the page-fault paths. Those are the frames the raytrace
analysis rests on.

Time that the interpreter genuinely spends dispatching bytecode is
attributed to [python call], since _PyEval_EvalFrameDefault is where
the eval loop runs. Per-symbol self time remains available
unmodified in the `perf report` output saved alongside these graphs.

Runs of [unknown] are collapsed the same way, into [unresolved]. Those
are an artefact of frame-pointer unwinding against a binary built with
-fomit-frame-pointer: the unwinder walks whatever is on the stack and
emits addresses that resolve to nothing. They are collapsed rather than
deleted, so the samples and their share stay visible and honestly
labelled instead of being silently reassigned.

Usage:
    stackcollapse-perf.pl out.perf | collapse_interpreter.py | flamegraph.pl
"""

import collections
import sys

# The call plumbing: frames whose only job is to get from one Python
# frame to the next. Kept as a set so the membership test is O(1) on
# what can be millions of frames.
PLUMBING = frozenset((
    # eval loop entry
    "_PyEval_Vector",
    "_PyEval_EvalFrame",
    "_PyEval_EvalFrameDefault",
    "_PyEval_EvalCode",
    "PyEval_EvalCode",
    # the generic call path
    "call_function",
    "do_call_core",
    "PyObject_Call",
    "_PyObject_Call",
    "PyObject_Vectorcall",
    "PyObject_VectorcallDict",
    "_PyObject_VectorcallTstate",
    "_PyObject_FastCallDictTstate",
    "_PyObject_MakeTpCall",
    # per-callable-type dispatch
    "_PyFunction_Vectorcall",
    "method_vectorcall",
    "method_vectorcall_NOARGS",
    "method_vectorcall_O",
    "method_vectorcall_FASTCALL",
    "method_vectorcall_FASTCALL_KEYWORDS",
    "method_vectorcall_VARARGS",
    "method_vectorcall_VARARGS_KEYWORDS",
    "cfunction_call",
    "cfunction_vectorcall_FASTCALL",
    "cfunction_vectorcall_FASTCALL_KEYWORDS",
    "cfunction_vectorcall_NOARGS",
    "cfunction_vectorcall_O",
    "slot_tp_call",
    "type_call",
))

COLLAPSED = "[python call]"

# Frame-pointer unwinding on a binary built with -fomit-frame-pointer
# walks whatever happens to sit on the stack and emits long runs of
# addresses that resolve to nothing. Measured on the frame-pointer
# profiles: the optimized raytrace graph was 128 rows tall (perf's stack
# limit) with 126 of its 180 boxes named [unknown], i.e. a single tower
# of unresolvable frames. Collapsing each run to one frame removes the
# tower while keeping the samples and stating plainly that the frames
# were not resolved.
UNRESOLVED = frozenset(("[unknown]",))

UNRESOLVED_MARKER = "[unresolved]"

# Each group maps a set of frame names to the single frame that replaces
# a consecutive run of them.
GROUPS = ((PLUMBING, COLLAPSED), (UNRESOLVED, UNRESOLVED_MARKER))


def collapse(stack):
    """Replace each run of same-group frames with a single frame."""
    out = []
    run = None
    for frame in stack:
        group = None
        for members, marker in GROUPS:
            if frame in members:
                group = marker
                break

        if group is None:
            out.append(frame)
            run = None
        elif group != run:
            # Emit the marker once per run, not once per frame. This is
            # what turns a repeating cycle or an unresolved tower into a
            # single frame. A run ends when the group changes, so
            # plumbing directly above an unresolved tower stays visible
            # as two frames rather than merging into one.
            out.append(group)
            run = group
    return out


def main():
    totals = collections.OrderedDict()

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue

        # Folded format is "frame;frame;frame <count>". Split from the
        # right: frame names can contain spaces, the count cannot.
        try:
            stack_part, count_part = line.rsplit(" ", 1)
            count = int(count_part)
        except ValueError:
            # Not a folded line. Pass it through rather than guessing.
            sys.stdout.write(line + "\n")
            continue

        key = ";".join(collapse(stack_part.split(";")))
        totals[key] = totals.get(key, 0) + count

    for stack, count in totals.items():
        sys.stdout.write("%s %d\n" % (stack, count))


if __name__ == "__main__":
    main()
