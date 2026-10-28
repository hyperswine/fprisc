# Loop motion: the identity finding

2026-10-27, re-checked 2026-10-28 against codegen rev 136.

Loop-invariant code motion (`Codegen.LoopOptimize`, opt-in via
`FPR_TYPED_IR_LOOP_MOTION=1` since the 11% regression led to the
pressure gate, `docs/2026-10-27-REGISTER-PRESSURE.md`) was re-measured
before considering a default-on flip. The answer is structural, not
a tuning matter:

- On the whole bench suite, motion on vs. off emits **byte-identical
  root and prelude unit assembly** (the only difference is the `-licm`
  unit filename). The pressure gate does not block anything here; the
  pass simply finds no loops to move in.
- The hot loops of the suite — `byteloop`'s `sumB`, `floatcmp`'s
  `loop`, the fib recursion — are self tail calls that become loops in
  `Codegen.Allocate.loopForm`, *below* the typed IR. `LoopOptimize`
  works on IR natural loops; where it does see one (entry-header
  loops like `sumB` report `loops=1`), the header is the function's
  entry block with no external predecessor, so `loopPreheader` is
  `Nothing` and the pass skips it — no motion on exactly the functions
  whose iterations dominate runtime.
- Two paired timing rounds under load ~7 disagreed with each other
  (floatcmp 0.890, then 0.977); with identical assembly that can only
  be noise. Recorded in `bench/2026-10-27-loop-motion-identity.json`.

## Consequence

Default-on is unjustified — there is nothing to gain and a pass to pay.
The real item is loop formation order: self tail calls must become IR
loops *before* lowering, not in the allocator. That one change unlocks
three planned steps at once:

- loop motion (#3): the pass would finally see the hot loops;
- interval analysis (plan step 4.4, #2): difference bounds over the
  recursion's counter and accumulator discharge the per-iteration
  overflow checks and the new string-read guards;
- tick amortization (step 8, #5): the countdown belongs to the loop
  header, which today exists only after the allocator forms it.

Until then the allocator's `loopForm` loops remain invisible to every
IR-level loop pass.
