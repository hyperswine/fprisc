# Instruction-cache synchronization for loaded images

Date: 2026-10-01.

QOS now places process code in reusable buddy blocks. A local `fence.i`
only updates the loading hart: another hart may remember old instructions
at the reused address. QEMU coherence does not demonstrate hardware safety.

`fpr_code_publish`, called on the kernel runtime after relocation and before
entering or spawning the image, fences the caller and release-increments a
shared generation. Immediately before each actor context switch, the scheduler
acquire-loads that generation and executes its own `fence.i` if it changed.
The generation is remembered on the scheduler stack, separately per hart.
The acquire follows acquisition of the queued actor, so an actor published
after the code publication cannot execute with an older generation.

No synchronous acknowledgement or IPI rendezvous is needed. Sleeping harts
are woken by the existing spawn/ship doorbell. Busy harts synchronize before
their next dispatch. Existing actors cannot execute a newly spawned image
without that dispatch; process functions crossing image boundaries are refused.
The direct image-entry call on the loading hart is covered by the local fence.
Multiple publications may coalesce into one fence. Every dispatch adds one
acquire load and comparison, rather than an unconditional instruction fence.

`tests/base/codepublish.fpr` publishes 100 generations and spawns a new actor
on hart 1 after each. An instrumented weak platform fence records that every
remote dispatch fences before entering the actor. This works on coherent
Unix hosts and is registered in `check_base.py`. It tests the scheduling
protocol, not a physical instruction cache. The Native QEMU image regression
also passes with the actual RV64 `fence.i` implementation. Physical RISC-V
hardware verification remains outstanding.

Callers must publish through the runtime that owns the scheduler. This API
is for loaders, not separately linked process-local runtime copies. It is
not an arbitrary live-code patching protocol: code must be fully written
before publication and inaccessible to actors until then.
