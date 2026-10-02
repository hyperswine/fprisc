# Ideal-style examples: executable comparisons

Date: 2026-10-02. Kind: implementation record. Compiler baseline: `45b9847`.

`examples/ideal/` adds six native Base programs without changing the compiler,
standard library or existing examples. `wc`, `report`, `todo` and `service`
rewrite the complete applications; `measure` and `pipeline` rewrite the
existing test fixtures. The collection's README records the intended style,
commands, reference programs and boundaries.

The structure is clauses for events/results, guards for applicability, named
transformations and pipelines for data flow. Real contracts include positive
format widths, nonnegative byte quantities and selection sizes, positive
worker counts, and a nonnegative factorial boundary. Recursive UTF-8
backspace and numeric/list traversals carry verified measures. Native work,
allocation and live declarations are checked on the bounded cores.

A checked boundary around factorial's measured helper is intentional: the
precondition pass did not discharge the direct loop's recursive value contract
from its fallthrough facts, so the inserted blame formatting made work opaque.
The wrapper validates once and leaves the measured loop free of that check.
Structural pattern-headed clauses are another remaining gap: Safety requires
a plain measured parameter and reads structural descent from a body `case`.
The list traversals retain that small case instead of using unsafe.

Verification: `python3 examples/ideal/check.py` builds all six, compares file
outputs and report documents with the originals, replays Todo transitions and
rendering, executes successful and failed saves, exercises both HTTP services
on ephemeral localhost ports, checks configuration and I/O errors, and compares
numeric results. Five violated value contracts must panic; a nondecreasing
measure and insufficient work declaration must be rejected. All declarations
in the collection must be proven during native compilation.

Scope: no interactive TTY, live-browser, QOS device or hardware timing run.
Resource bounds are native-only; std/list result sizes remain explicit
assumptions. Manifest prices in `tests/manifests/host.fprt` are placeholders.
Live equations cover the compiler's pool-cell model, not total process RSS.
No claim is made that the I/O applications have a closed whole-program WCET.
