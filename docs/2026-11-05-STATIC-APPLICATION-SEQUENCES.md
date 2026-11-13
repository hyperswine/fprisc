# Static arenas for finite builtin applications

The RV64 admission tool can now build an application consisting of several checked entry points executed in a declared order. A step may pass its scalar result into the next entry. The existing single-entry CLI and receipt remain available.

The [example source](../examples/static-arena/word-state.fpr) and [four-step input](../examples/static-arena/word-state.json) start at 7, add 3, add the largest unsigned word (wrapping to 9), and choose the carried value. Build and execute it from the repository root:

```sh
sol tools/build-static-arena.sol examples/static-arena/word-state.fpr \
  --sequence examples/static-arena/word-state.json \
  --heap-bytes 624 --stack-bytes 448 --image /tmp/word-state.elf --execute
```

With the recorded toolchain, the QEMU execution returns 9 at those exact limits. A fresh linked-stack proof selects the required stack for other builds. The adjacent `.admission.json` binds the executable hash, checked exports, canonical sequence, compiler and runtime recipe, placement and optional execution result.

## What admission establishes

- The input must contain a nonempty `steps` list. The compiler freshly analyzes every distinct entry under its own C export symbol. Each parameter and result must have a checked `Word`, `Int`, `Bool` or `Unit` boundary. Each literal is range checked. `{"previous": true}` requires an earlier result with the exact expected kind. Repeated references can use any of the 64 supported parameter positions.
- The generated dispatcher stores the finite schedule and its literals as constant data, with a direct native call site for each distinct entry. The linked proof covers the dispatcher, compiler adapters, runtime and startup on the final image. Ordinary compiler optimization can simplify short fixed schedules.
- The maximum per-entry fresh-heap requirement governs capacity. Total allocation requests and requested bytes are summed over actual steps. Every transition checks for zero live allocations and intact arena guards **before** resetting the allocator to its proved fresh geometry. A failed check stops the application. Only a scalar crosses the reset. The resulting receipt separates this enforced reuse protocol from the static per-entry bounds.
- The image, static sections, guard placement and final stack must all fit the selected target. With `--execute`, a failed run refuses publication. The scope is exclusive sequential execution under the controlled RV64 startup and audited builtin runtime. Resumable interrupts, overlapping activations, escaping heap references and arbitrary QOS applications require additional contracts. Termination and elapsed-time bounds are separate obligations.

## Executed results

| Application | Steps | Allocation requests bound | Heap bytes | Linked stack bytes | Final result |
| --- | ---: | ---: | ---: | ---: | ---: |
| Three distinct entries, wrapping state | 4 | 11 | 624 | 448 | 9 |
| Seed and accumulate 1 through 32 | 33 | 98 | 624 | 432 | 528 |
| Seed and accumulate 1 through 256 | 257 | 770 | 624 | 432 | 32,896 |
| Carry the minimum tagged Int | 2 | 0 | 0 | 352 | minimum Int |
| Carry Bool / Unit | 2 each | 0 | 0 | 160 / 144 | true / unit |
| Carry one word into all 64 arguments | 2 | see receipt | 13,120 | 2,256 | 14 |

The 33- and 257-step images occupied 5,152 and 14,112 image bytes respectively. The larger schedule adds constant input data while using the same heap and stack. An independent instruction trace of the four-step image observed 432 bytes of stack under the proved 448-byte bound. The tests refuse a short heap or stack, a late unproved entry, invalid argument kinds and a deliberately leaked allocation before reset. They verify that refusals preserve the previously admitted files. [Receipts and execution evidence](../bench/2026-11-05-static-application-sequences.json)

## Linked callback instruction budget

Pass `--callback-instructions N` to limit the total number of linked RV64 instructions in all callback activations of a static-arena image. The same option works with a single entry. The existing heap, stack, layout and execution gates also apply. The command reports the required and allowed counts. The optional `callback_work` receipt records the actual public symbols, per-entry bounds, invocation count, total and verifier hashes for the linked image.

For example, save this as `/tmp/keep.fpr`:

```text
profile builtin.
keep : Bool -> Bool.
keep b = b.
```

```sh
sol tools/build-static-arena.sol /tmp/keep.fpr --entry keep --arguments '[1]' \
  --heap-bytes 0 --stack-bytes 1024 --callback-instructions 20 \
  --image /tmp/keep.elf --execute
```

The verifier decodes the final executable, including compressed instructions, direct calls, relaxed jumps and resolved register targets. At a normal call it counts the instruction, the callee and the continuation. It follows a tail transfer as a jump and takes the larger bound at a conditional branch. Repeated calls charge the callee each time. For a sequence it sums the checked bounds in dispatch order.

Instruction admission verifies preserved registers, balanced frames and the original return link. Frame stores and full-width reloads track which saved values remain intact across branches and calls. It refuses indeterminate transfers, reachable cycles, damaged return links, out-of-frame writes and incompatible joins. The allocator's unproved stores currently keep allocating callbacks outside this optional mode. Programs admitted under the ordinary memory-only policy can continue to use that policy.

On RV64 QEMU, a Bool callback needed 20 instructions and executed exactly 20. Four Bool callbacks had a combined bound of 120 and executed 117 instructions, measured from their public entries through their returns on an uninstrumented CPU trace. Limits of 19 and 119 respectively were refused; in both cases the previous executable and receipt survived. The linked-unit tests include repeated callees, tail calls, conditional paths, nonreturning and recursive cycles, partial overwrites of a saved return link and unresolved jumps, with relaxation and compressed encoding on and off. [Single-entry evidence](../bench/2026-11-05-linked-callback-single.json) · [Sequence evidence](../bench/2026-11-05-linked-callback-work.json)

The count covers synchronous callbacks and their linked callees under the controlled startup and valid-memory assumptions. The dispatcher, resets, interrupts, memory wait time and OS scheduling need separate bounds. A 120-instruction receipt therefore cannot establish a deadline for a QOS Pi application.
