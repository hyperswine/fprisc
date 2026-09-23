# QOS and FP-RISC: project progress summary

**Snapshot:** 18 September 2026  
**Kind:** historical record and implementation status, not a language specification.

This document summarizes the work from the initial QOS review through the
repository split and the latest BareMetal–Builtin implementation. It separates
implemented changes from design direction and deployment work still outstanding.
Earlier discussion is summarized from the conversation and its recorded review
notes; the present implementation and Git state were checked against the local
repositories. Test results below are from the preceding implementation work, not
new tests run while writing this document.

## 1. Starting point: reviewing QOS as a usable system

We began with the combined `qos-fpr` repository and asked where QOS stood, what
could realistically be released, and how it could become a practical desktop or
appliance environment.

The review covered QOS Native, QOS Portable, the compiler/runtime boundary,
application loading, persistence, input, graphics, memory management and resource
limits. A recurring distinction was between a working demonstration, a supported
execution path, and release readiness under failure or resource exhaustion.
Native application execution was treated as trusted-code execution, not as proof
of hardware-enforced process isolation. Allocator and ordinary persistence checks
were useful evidence, but did not establish power-loss durability or complete
process-lifetime correctness.

The older [QOS review](../../qos/docs/FPR-QOS-REVIEW.md) remains historical context.
Its percentages, source references and defect list describe an earlier tree and
must not be treated as current findings without verification.

## 2. Raspberry Pi and the fullscreen appliance direction

The intended Pi experience was a fullscreen graphical application with keyboard
and mouse, launched by systemd, with a custom startup logo instead of a screen full
of boot logs. QOS Portable was the likely route for testing QOS userspace semantics
on Linux.

We discussed:

- X11 display connections, window creation and fullscreen requests.
- OpenGL ES and EGL as the proposed rendering/context path for the Pi setup.
- GLFW as a possible window/context/input layer when built and configured for the
  appropriate backend; the initial assumption that GLFW could not be used was
  reconsidered.
- Display selection and fullscreen placement, which must be distinguished from
  the display server's mirroring or multi-monitor configuration.
- Startup ordering between the display server and the application, systemd service
  configuration, and a quiet-boot/splash handoff such as Plymouth.

A mouse-oriented variant of `interactive_desktop_gl.fpr` was added during this
phase: holding LMB orbits the camera using yaw/pitch, alongside the existing
keyboard controls. Compilation and linearity checks were recorded, and the user
reported that it worked.

**Boundary:** this conversation did not complete or validate the entire Pi image,
GPU/Xorg setup, input hotplug, boot splash or systemd handoff on physical hardware.
These remain a separate integration project from the standalone language work.

## 3. Making the runtime mechanisms explicit

We traced how FP-RISC reaches the outside world. An unresolved global can become
an `fpr_g_<name>` symbol supplied by a HAL/runtime implementation. `FPR_FN` defines
a static callable descriptor (`pap0_t`) with a code pointer and arity; the symbol
is not merely a C function pointer.

We also explained saturation, partial application and the role of `fpr_applyN`.
Supplying fewer arguments produces a PAP containing supplied arguments; saturation
calls the function, and over-application applies remaining arguments to its
result. This describes the existing general runtime. It does not imply that the
new automatic ARC subset already supports every such case.

The design requirement was clarified: lambdas should be lifted to named functions,
with captured values made explicit as arguments. Partial applications should
remain possible without introducing a separate closure mechanism. Supporting
ownership-aware PAPs in the new ARC mode is still unfinished.

## 4. Reviewing bounds, slots and arenas

The user wanted simplicity derived from explicit rules, rather than incidental
limits left over from testing. We reviewed function arity, application slots,
actor mailboxes, ARC bookkeeping and allocator arenas with that distinction in
mind.

We separated physical resource limits and deliberate bounded-cost policies from
implementation artifacts and dangerous silent truncation. Application slots were
discussed primarily as runtime capacity rather than disk capacity. An arena was
explained as an allocation region and policy, not as a fundamental language rule
requiring one permanently fixed block of memory.

The user reported improvements to ARC capacity and actor mailbox growth. The
follow-up review recorded dynamically growing ARC bookkeeping and static/dynamic
mailbox policies, while identifying remaining ceilings and failure/lifetime
questions. Those actor-runtime changes should not be confused with the later,
separate BareMetal automatic ARC implementation.

Growing a Unix allocation region through host allocation was discussed, but this
summary does not claim that every QOS arena became automatically extensible or
that all arity and capacity limits have been removed.

## 5. Language, library and profile design

The discussion shifted from “what belongs in the standard library?” to a clearer
separation of language meaning, library contracts and execution mechanisms.

The platform documentation introduced a versioned pair `(L_n, S_n)`: a language
specification and its corresponding Base contract. It also distinguished
specifications, references, plans, tutorials, examples, reviews and historical
records. Base membership was kept separate from the existing `std/` bounded-cost
verification discipline.

Naming evolved through proposals involving Builtin, Base, Core, Std and an
extended standard library. The later preference was **ExtBase**, with its own
prelude, rather than ExtStd. These names and their complete inventories remain
design work; the earlier proposals are not all simultaneously settled tiers.

The direction that emerged was:

- A small strict, linear functional language with functions, types, pattern
  matching and enough primitive memory/bit operations for systems programming.
- Allocation and ownership mechanisms sufficient for algebraic data and sharing,
  with operational behavior selected by the execution profile.
- A seamless transition between low-level programming, applications and Sol
  scripting, preserving ordinary declarative meaning while profiles supply ARC,
  scheduling or transactions where appropriate.
- Actors, vectors and maps should not become fundamental language features solely
  because they are convenient or currently implemented as builtins. Their precise
  placement remains open.
- QOS should be a reference operating environment for richer FP-RISC profiles,
  with little mismatch between language and OS facilities. Running FP-RISC itself
  should not require QOS.

BareMetal–Builtin and bytecode/Sol were intended to remain independently usable.
A standalone POSIX backend was requested as a future direction; the repository
split did not implement one. (Since done: the `posix` system, docs/PROFILES.md, which also says
how it differs from `qos-portable`.) Likewise, the proposed QOS/Base relationship is not
a completed Base conformance claim.

See [PLATFORM.md](PLATFORM.md) and [DOCUMENTATION.md](DOCUMENTATION.md). Their
terminology records stages of this evolving design and needs eventual alignment
with the final profile and library naming.

## 6. Splitting QOS from FP-RISC

We separated the combined source into two local repositories:

| Repository | Responsibility |
| --- | --- |
| `Documents/GitHub/fprisc` | Compiler, native backends, Sol implementation, language libraries, runtime and standalone machine support |
| `Documents/GitHub/qos` | QOS hosts, process/application loaders, services, Unix devices, applications, packaging and `qos.py` |

The original history and tags were retained. Old tags describe the combined
layout, not newly qualified releases of the separated projects. The obsolete
`FP-RISC` checkout was removed at the user's request after they confirmed it was
backed up; the original combined checkout was retained according to the split
record.

The first separation was refined to remove cross-repository source symlinks.
QOS now uses an explicit compiler dependency:

```sh
export FPRISC_ROOT=/Users/jasonqin/Documents/GitHub/fprisc
```

`FPR_HOME` and `FPR_PATH` support module resolution. The compiler checkout need not
be a sibling of QOS. Installed bundles copy the toolchain into their distribution;
they do not depend on development symlinks. Compiler revision pinning is separate
from QOS module pinning.

Finder metadata was cleaned up and ignore rules added. Neither repository
currently tracks `.DS_Store` files. The split and path changes are committed.
QOS currently has `git@github.com:hyperswine/qos.git` as its origin; remote visibility
and publication state were not rechecked while preparing this summary.

The [split record](../../qos/docs/REPOSITORY-SPLIT.md) documents ownership and
validation. Its original “uncommitted” and “no remotes” statements are historical.
It also records a Mac Portable arena-mapping failure reproduced in the unchanged
monorepo; the split did not claim to fix that issue.

## 7. Establishing standalone BareMetal–Builtin

We added an unsafe, scheduler-free execution path for RV64 QEMU `virt`:

```sh
make bare-metal-builtin-run PROG=tests/builtin.fpr
```

This path has no implicit prelude, QOS process, actor scheduler, fuel decrement,
filesystem service or transaction layer. Type and linearity checks remain active;
bounded-cost/termination checking is not required for this unsafe profile.

The implementation includes startup code, linker-defined RAM/stack regions,
console output, panic/exit behavior and a standalone coalescing allocator. It
supplies allocation, reallocation and freeing without fixed allocation-slot or
reference-table capacities. Available RAM still bounds allocation, and exhaustion
has an explicit failure path. The allocator is single-threaded and non-reentrant.

The API includes full-width `Word` and `Addr`, bitwise operations, shifts, masks,
bit set/clear/test, address arithmetic, and byte/halfword/word memory reads and
writes. Memory validity, lifetime and device protocol remain caller obligations.

The manual ownership mode exposes explicit retain/release operations for its
supported values. Raw buffers always require explicit `Mem.free`; an address
value does not own its pointee.

## 8. Automatic reference counting

The next milestone introduced opt-in compiler-generated ARC:

```sh
make bare-metal-builtin-run ARC=1 ARC_CHECK=1 PROG=tests/builtin_arc.fpr
```

The ownership pass operates after lambda lifting. It handles managed arguments,
locals, branches, constructors, projections and returned values, including
structural sharing. Cleanup precedes tail transfers so direct tail recursion
keeps constant stack use.

Compiler-created objects record their fields explicitly. Releasing a graph uses
an intrusive worklist stored in dead allocation headers, avoiding recursive
C destruction, new allocations during destruction and a fixed work-queue bound.
Audited primitive adapters bridge borrowed-input runtime functions to the owned
calling convention.

This began as a conservative first-order subset that rejected raw floats and
partial/indirect calls. It was not a complete implementation of “ARC only where
linearity cannot be proved”: redundant retain/release removal, last-use moves and
uniqueness-based reuse remain optimization work.

## 9. Assembly-backed machine operations

The machine interface was extended with opaque assembly implementations for
memory and bit operations, CSR reads/writes, interrupt masking/restoration,
atomic exchange/compare-exchange, memory barriers, instruction fencing and wait.

The purpose was to let FP-RISC express low-level control through a small explicit
primitive boundary instead of requiring inline C throughout systems code.
Invalid arguments have defined diagnostic paths where checked; invalid or
read-only CSR accesses can still raise architectural faults. The initial trap
entry reported faults and terminated rather than resuming execution.

See [MACHINE-PRIMITIVES.md](MACHINE-PRIMITIVES.md).

## 10. Latest milestone: raw representations and resumable interrupts

The latest working-tree changes remove two important obstacles to low-level use.

### Representation-aware ARC

`Word`, `Addr`, F32 and F64 now remain unboxed in automatic ARC mode. Scalar machine
arithmetic and address conversion do not allocate wrapper objects. Manual mode
retains its previous boxed Word/Addr ABI.

A whole-program representation analysis tracks values across calls, locals and
constructor fields. Immutable field descriptors distinguish managed references
from raw scalars. ARC never follows a raw field merely because its bits look like
a heap pointer. Raw-aware equality/rendering use that metadata; float equality
covers NaN and signed zero. Existing frontend limits on generic rendering of
float-containing structures still apply.

**Tradeoff:** ARC currently compiles root and imported definitions together.
Separate ARC module caching is disabled until representation signatures can be
serialized and checked. Representation/layout inference is conservative;
incompatible uses are rejected rather than assigned an unsafe shared ABI.

### Checked resumable interrupt handlers

An ARC program may define `machineInterrupt cause pc value`, taking three raw
Words and returning Unit. Startup installs the runtime entry stub for that named
function. The handler must acknowledge its interrupt source.

The RV64IMAFD entry uses a dedicated stack and preserves integer registers,
floating-point registers, floating-point status and return state before resuming
with `mret`. Interrupts remain disabled during the handler; synchronous faults
use the fatal emergency path. `mscratch` and the installed `mtvec` are reserved
by this arrangement.

The compiler checks the reachable handler call graph. It rejects allocation,
managed construction/projection, string/printing work, indirect calls, CSR writes,
interrupt re-enabling and functions exceeding the eight-register argument ABI.
This avoids entering the non-reentrant allocator or shared argument-spill area.
Raw writes remain unsafe: the check cannot prove that an address does not corrupt
managed objects, runtime state or stacks.

Examples: [raw values](../tests/builtin_raw.fpr) and
[resumable interrupts](../tests/builtin_interrupt.fpr).

## 11. Validation achieved

The preceding implementation work passed all four focused suites:

| Suite | Evidence |
| --- | --- |
| `tests/check_builtin.py` | Standalone boot, scheduler-free link, manual ABI, invalid inputs, module resolution and allocator checks under ASan/UBSan |
| `tests/check_machine.py` | Bit/CSR operations, atomics, fences, interrupt masks, manual compatibility and actual hardware-fault/software-interrupt delivery in QEMU |
| `tests/check_arc.py` | 10,000 sharing/escape cycles in 16 KiB; zero live allocations; tail calls; a returned 6,000-node graph; imported ownership; 12,000-node destruction under sanitizers |
| `tests/check_raw.py` | 10,000 allocation-free word iterations; mixed raw/managed fields; raw main results; float equality; imported raw ABI; full register/fcsr preservation; 1,000 resumed interrupts; handler restrictions and fatal faults inside handlers |

The sanitizer layout test also stores the exact bits of a live heap pointer in
raw Word, Addr and float fields, confirming that destruction follows only the
managed ownership edge.

These are host/sanitizer and QEMU results. They are not Raspberry Pi GPU/input
acceptance, physical-board interrupt validation, multicore validation or proof
that every QOS subsystem is release-ready.

## 12. Snapshot and remaining work

At this snapshot, FP-RISC's latest commit is `45fc0e7` (`Mass Updates: BareMetal +
Builtin`). The raw-representation and resumable-interrupt milestone is present as
uncommitted working-tree changes. QOS's latest local commit is `748c976` (`Remove
FP-RISC Tree`), and its existing compiler pin is still `5a42e66`; that pin does not
include the newer Builtin work.

The main remaining work is:

1. Ownership-aware PAPs and indirect application for lifted functions, without a
   separate closure mechanism.
2. Representation specialization, less restrictive data-layout inference, and
   checked representation metadata for separate compilation.
3. ARC optimization and broader ownership/FFI contracts; cycles remain unsupported.
4. Further reduction of coupling to the shared runtime and its `tp` context.
5. Broader targets, a standalone POSIX path, and physical-hardware validation.
6. Final Base/ExtBase naming, API inventories, ownership laws and conformance tests.
7. The Pi graphical appliance integration: display/input setup, startup service,
   splash handoff, restart/shutdown behavior and hardware acceptance.
8. Release coordination between the two repositories, including compiler pins and
   reproducible cross-repository builds.

The practical result is a substantial move from a combined language/OS prototype
toward independently usable FP-RISC systems programming. BareMetal–Builtin now has
working memory, arithmetic, ownership and interrupt foundations, but remains an
experimental subset rather than a complete C replacement.
