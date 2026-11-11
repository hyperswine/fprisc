# Fixed live state and digit-parser probes

Run from the repository root on macOS with the current native compiler. The
runner checks every result and reports medians of three whole-process runs
including launch and the timing wrapper. Peak RSS includes runtime memory.

```sh
make fpr
out=$(mktemp -d)
export FPR_HOME="$PWD"
./fpr build tests/bench/reclamation/fixed_state.fpr -o "$out/state"
for flag in 0 1; do
  FPR_TYPED_IR_EARLY_LOOPS=1 FPR_TYPED_IR_STRING_SCAN=$flag ./fpr build tests/bench/unbox/parse_digits.fpr -o "$out/parser$flag"
done
python3 tests/bench/reclamation/measure.py "$out/state" "$out/parser0" "$out/parser1"
```

On 53a1dbd7, hosted arm64, incrementing the same 2,048 logical integers on
every step gave the following peak RSS in MiB.

| Steps | Persistent list | List under Sys.loop | Linear vector |
|---:|---:|---:|---:|
| 64 | 7.0 | 3.4 | 3.1 |
| 512 | 35.0 | 3.4 | 3.1 |
| 2048 | 131.1 | 3.4 | 3.1 |

At 2048 steps elapsed times were 25, 83 and 25 ms respectively. Vector storage
changes layout as well as ownership. It is a control for explicit in-place
updates. A compiler prototype should next reproduce flat RSS on the list
itself, include a retained alias whose old contents must survive, and compare
with the region path on identical list layouts.

The second fixture sums digits and returns None on the first non-digit. Its
scalar control reserves -1 for the same failure. Each build checks empty,
invalid and valid input. With two million successful eight-byte parses,
Option/scalar took 57/55 ms with scan versioning disabled and 56/56 ms with
it enabled. All four peaked at 3.0 MiB. These small differences are within
the resolution of this experiment.

Inspect the generated functions separately with FPR_TYPED_IR=dump and
`fpr compile --system=posix tests/bench/unbox/parse_digits.fpr parser.s`.
With both loop flags enabled the compiled scan had one load.byte site,
zero spills and native-insns-v1 segmax 94. It did not acquire the guarded
fast copy that the existing string-scan pass emits on admitted loops.
The standalone parse function constructed Some, while the specialized
options loop called scan directly and had no Some constructor. The next
unboxing test should keep the producer across a private non-inlined call
and also exercise a use that stores the returned Option. RSS cannot count
constructor allocations.

## Early returns and the private parser ABI

With codegen revision 213 the opt-in guarded scan accepts a branch from the
body to a return block. On hosted arm64 the parser now emits two byte-load
sites (checked and guarded). Spills stayed at zero, while segmax rose from
94 to 126 native instructions. Median whole-process times across eight
interleaved runs per configuration were 53.5/48.5 ms for two million
eight-digit parses (checked/guarded), 13.1/15.8 ms for rejection on the
first byte, and 55.0/45.0 ms for 20,000 parses of 1024 digits. Early failure
can cost more than it saves; the optimization remains opt-in.

With inlining disabled, 10 and 1010 successful private parser calls both
needed six process-wide allocation requests with variant returns enabled.
Disabling pair returns gave 16 and 1016. The stored path passes a list
containing the parse result through keep and recovers the expected payload
or absence. tests/check_base_variant_returns.py checks both the worker and
the allocation slope, and exercises the stored path with both settings.
