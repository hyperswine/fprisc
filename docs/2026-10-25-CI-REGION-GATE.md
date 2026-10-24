# Region classifier gate after collector retirement

Date: 2026-10-25. Kind: CI contract repair. Applies after compiler cleanup
checkpoint `2d5575d`; the runtime and emitted classifier code are unchanged.

Hosted run [40131550545](https://github.com/hyperswine/fprisc/actions/runs/40131550545)
passed native and RISC-V checks and reached the Tang Nano examples after the
Git-ownership fix. The classifier completed all ten exact iterations, but its
suite gate still expected multiple collector samples, an intermediate live
figure below 1 MiB, and a `collections` counter. The region runtime reports
one cumulative `HEAP` summary at exit, with `regions` instead of collections.

The captured CI run measured an 8,052,496-byte usable heap, 2,532,832-byte peak,
1,254,336 bytes live at exit, 25,321 regions and 183,472,640 reclaimed bytes.
The compiler's region-stage evidence already described this behavior. This was
a stale gate, not evidence that the ten-iteration program ran out of memory.

`validate_classifier` now requires:

- Successful validation of exactly ten output iterations.
- A positive usable-heap budget and at least one region summary.
- Valid nonnegative live/peak/region/reclamation counters.
- Every reported live figure at most its peak, and every peak within the
  actual usable heap budget; a nonzero final peak proves instrumentation exists.
- At least ten regions and more than ten heap budgets reclaimed.

The cumulative peak bounds the whole run. A periodic collector sample count or
an intermediate collector live-size threshold is not part of this contract.
This gate certifies the ten-iteration workload within its heap budget with
substantial reclamation; it does not establish flat memory for an unbounded
persistent application.

Seven example-gate unit tests pass, including ten adversarial classifier
mutations. A fresh `tools/run_tangnano20k_examples.py --target qemu --cases
classifier` passed after the frontend split. The final gate was also checked
against that fresh result. Local evidence is in
`/private/tmp/fpr-frontend-classifier/`; the preceding CI measurements were
retrieved from its `tangnano-qemu-evidence` artifact. No physical FPGA run is
claimed. The CI argument-step label no longer advertises removed GC roots.
