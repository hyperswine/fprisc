# Clobber-free ticks and noreturn kernel traps

Date: 2026-10-27. Step 6 of [the performance plan](2026-10-26-PERFORMANCE-PLAN.md),
first part: the fuel tick's slow path no longer clobbers allocatable
registers. Follows [register pressure](2026-10-27-REGISTER-PRESSURE.md).

## Why

Every native loop ticks once per iteration (`EntryTick` at a self-loop's
label, `OSafepoint` in a CFG loop) and its slow path called
`fpr_fuel_exhausted`, a C function that may deschedule the actor. The
protocol declared every caller-saved register clobbered, so every value
live across the tick, which is every value carried around a loop, had to
sit in the scheduler-preserved budget: nine registers on A64 (x19..x27),
five on x86-64, eleven on RISC-V. Anything beyond that was spilled. The
same applied to a vector kernel's checked arithmetic, whose failure path
calls `fpr_int_overflow_kernel` or `fpr_div_zero_kernel`, although both
never return.

## The change

- **A register-saving wrapper per unit.** Every tick's slow path calls
  `fpr_fuel_save_local`, a local (non-exported) symbol emitted once into
  each assembly unit that ticks (`Codegen.emitProgram`). It saves the
  caller-saved registers the allocator may use on the actor's own stack,
  calls `fpr_fuel_exhausted`, restores them and returns:
  A64 x0..x15 and d0..d7 (208 bytes with the frame record), x86-64 rax,
  rcx, rdx, rsi, rdi, r8..r11 (nine pushes, which also realign the stack
  for the C call), RISC-V ra, t0..t6, a0..a7.
  The actor may resume on another hart: its stack moves with it, and the
  tick's own temporaries (x9..x11, r10/r11/rax, t3..t5) are implicit
  definitions that nothing reads after it. The hart register (x28) is
  callee-saved and restored by the context switch, as before.
- **No runtime or ABI change.** The wrapper calls the same
  `fpr_fuel_exhausted` symbol, so QOS app images (which import it through
  their table), the Tang Nano board runtime (which defines its own) and
  ESP-IDF keep working without changes.
- **The protocol.** `Tick` and `CountedTick` declare no clobbers and a
  `PreservingFuel` call event (`Codegen.Call.callPreserves`; still a
  safepoint for accounting and the shallow-entry rule). The allocator does
  not count such a call when deciding that a value must be callee-saved,
  and its physical oracle does not require preserved registers across it.
  The self-loop's tick half split off by `loopForm` and the tick that
  `shallowEntry` leaves behind take the same form. `CheckAndTick` (the
  entry's stack check and tick together) keeps its clobbers, because
  `fpr_stack_grow` is a real C call.
- **Noreturn kernel traps.** A new transfer result `Calling.NeverReturns`
  gives a call control `Return`: its block ends there, so nothing is live
  after it. The kernels' overflow and zero-divisor calls use it on A64,
  x86-64 and RISC-V; the per-target form checks accept a call with that
  contract. Ordinary checked arithmetic still re-enters the C primitive
  (a returning call) and is unchanged.
- `Codegen.Pressure` follows: ticks and kernel arithmetic no longer count
  as clobbering operations.

## Results

The loop-motion benchmark's fold kernel (A64): callee-saved registers
used 9 -> 4, values that must survive a call 15 -> 4, no spills. Its time
moved little (233 -> 228 ms under load): its critical path is the
accumulator's moves between integer and float registers and the fuel
counter's load and store, not register pressure.

The benchmark set (`tools/bench.py --c`, fastest of seven, Apple M4 under
background load, both compilers built and run back to back):

| Benchmark | `c94c64e` | this change |
|---|---|---|
| fib | 48.8 ms (2.53x C) | 44.9 ms (2.36x C) |
| pingpong | 229.7 ms | 213.4 ms |
| sha | 113.6 ms | 112.8 ms |
| xpingpong | 288.6 ms | 281.1 ms |
| byteloop, helpers, nbody, strbuild, vecread, floatcmp | | within 2% either way |

`workers` fails to link in both (its benchmark needs a C helper the tool
does not pass). Compile cost against the recorded baseline: std/live +6.2%
allocation and +2.6% peak, pos1 +3.0% and -7.7%.

The first version decided whether a unit needs the wrapper by searching the
unit's text for its name. That held the whole unit's text in memory until
the end and put std/live's peak residency at +30%, over the gate. Each
function now reports whether it ticks (`NativeFn.nfTicks`). Test harnesses
that link function bodies cut out of a unit append the unit's wrapper
(`tests/fuel_wrapper.py`).

`codegenRev` 132.

## Evidence

- `tests/check_typed_ir_{a64,x64,rv}_frames.py` link the generated code
  against a stub `fpr_fuel_exhausted` that zeroes every caller-saved
  integer register (x0..x17 on A64) before returning; the frame emitters
  now append the wrapper as `Codegen` does. A64 also passes in the
  production actor runtime with forced yields on one and four harts.
- `tests/AllocIR.hs`: three values across a preserving tick stay in
  caller-saved registers with a callee budget of two, nothing spilled, and
  the straight-line simulator checks every value.
- `tests/SelectedIR.hs`: a tick declares no clobbers and a preserving
  event; a tick declaring clobbers is refused; the shallow rewrite yields
  the tick protocol's form.
- The harnesses that link sliced native code (float trees, kernels, self
  loops, scalar, RV module/QRV64/ESP probes, captured SIMD, float inline).
- The full Base suite: 141 jobs in 633 s on six workers.

Not run: the QOS sweep and physical boards. QOS app images take the
wrapper (it calls the imported `fpr_fuel_exhausted`); their kernels'
plane path is unchanged.
