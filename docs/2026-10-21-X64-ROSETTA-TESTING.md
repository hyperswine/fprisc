# Local x86-64 execution with Rosetta

Date: 2026-10-21. Kind: implementation and validation record.
Initial record: test changes following `492dc9a`, committed in `d6f8468`.
Current direct-backend extension: [M2 x86](2026-10-21-TYPED-IR-M2-X64.md).

Run the focused local suite from the repository root:

```sh
python3 -u tests/check_x64_local.py --require-execution
```

The command checks/builds the host compiler once, then compiles x64 probes
and executes them on native Intel or through `arch -x86_64` on Apple Silicon
with Rosetta installed. `--require-execution` fails when neither execution
route is available. Without it, an unavailable route is reported as a skip.
No Linux image, container, or x86 build of GHC is required. The host C toolchain
must support x86-64; macOS links with `clang -arch x86_64` and ad-hoc signs the
probe executable.

Current status: [x64 translator retirement](2026-10-23-X64-RETIREMENT.md)
removes the legacy modes described below. The current suite executes typed
hosted x64 and QOS x64 scalar/ABI and kernel oracles, including borrowed
hart/argument cells. QOS's FS base is substituted; this is still not a QOS
runtime or Linux TLS acceptance run. The tables and original evidence below
record the earlier translator/backend migration.

## What runs

| Probe | Executed checks |
|---|---|
| `check_x64_scalar.py` | 31,689 C-reference cases per mode: signed arithmetic, division, branches, all 64 shift counts on boundary inputs, nested calls, Bool workers and independently allocated foreign Bool objects |
| Scalar slow paths | Twelve overflow/division-zero/invalid-shift cases check the selected fallback kind and original tagged operands, using test-owned C hooks and `longjmp` |
| Scalar ABI | 7/8-argument non-tail calls; 7/8/9/64-argument recursive rotations; integer callee-save sentinels; fuel-call stack alignment; destruction of all volatile integer/XMM registers and private argument cells at the simulated scheduling boundary |
| `check_self_loop_x64.py` | 2,100 C-reference argument permutations each with self loops off/on; exact fuel counts and flat stack usage |
| `check_x64_vectors.py` | 100 scalar/pipeline lengths, eight pipeline arguments, nine-column map/filter, captured fold and clobbering runtime calls |

The original scalar probe executes five legacy modes: baseline, retained registers with
compact frames/self loops, costed placement, scalar workers with retained
registers/compact frames/self loops, and baseline again. Assembly assertions
prove that retained-register promotion, self loops and worker generation
actually occur. Costed placement may reject promotion and is tested separately.
The return to baseline must reproduce the original selected assembly.
The M2 extension adds two strict direct-IR modes (workers off/on) and mixed
legacy-caller/legacy-callee binaries; shifts and arities above eight remain
explicit legacy fallbacks. Unadapted output also assembles as x86 ELF with
real TLS relocations.

Arithmetic results come from independent C expressions, with `__int128` for
overflow checks and unsigned shifts to avoid undefined signed overflow.
The original generator legitimately delegates some valid operations, such as
division by minus one, to C. The harness implements these cases and checks
that the small-input arithmetic corpus does not simply fall back wholesale.

`x64_probe.py` centralizes execution detection, compilation/signing and the
limited linkage adaptation shared by the three probes. `check_base.py` also
runs the new scalar probe, so the existing x86 Linux CI umbrella includes it.

## Evidence boundary

These are selected generated functions linked to test harnesses. On macOS,
external symbol names gain Mach-O underscores. On both macOS and Linux, the
three Linux TLS references (hart and arguments seven/eight) are replaced by
single-threaded harness cells. Unsupported remaining relocations are refused.
The generated arithmetic, frame and call instructions otherwise stay intact.

The harness substitutes fuel and stack hooks; stack growth is forbidden in
this bounded probe. The trap checks establish fallback routing and operands,
not the production panic message or actor-death behavior. There is no
validation of real Linux TLS, Mach-O thread-local variables, actor migration,
multithreaded scheduling, dynamic loading, actual stack growth, or a complete
x86 macOS Base runtime. These remain separate Linux/native acceptance gates.

Rosetta timings describe local test turnaround only. They cannot establish
native x86 performance or energy efficiency, and they do not close M2's
native Linux execution gate. The fixtures now also exercise direct IR emission under strict mode;
that remains separate from real Linux runtime acceptance.

## Validation

The original five-mode local suite was executed under Rosetta on the Apple Silicon
development host. Final timings and output are recorded in
[`local-suite.log`](evidence/2026-10-21-x64-rosetta/local-suite.log).
The run includes five scalar modes, both self-loop modes and vector probes.
It completed in 6.87 seconds, including the up-to-date compiler build check:
4.49 seconds for scalar/ABI, 1.43 for self loops and 0.93 for vectors. This is
one observed local turnaround measurement, not a native x86 benchmark.
Compiler identity, source hashes and platform are in
[`validation.json`](evidence/2026-10-21-x64-rosetta/validation.json).
Linux execution of these new test changes remains for CI.

The expanded direct-IR and mixed-boundary run has separate evidence linked
from [M2 x86](2026-10-21-TYPED-IR-M2-X64.md); the original logs above are preserved.
