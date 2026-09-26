# What is Sol?

**Date:** 19 September 2026  
**Kind:** design rationale and proposed architecture.  
**Status:** the profile model exists; the standalone tools and deployable bytecode
format described below are proposals, not shipped capabilities.

**Sol is FP-RISC's scripting environment: a named profile, a standard library
experience, and tools for running scripts and interactive programs.** It can have
its own identity and executable without requiring a separate language definition.

## 1. From a sibling language to a profile

Sol began as a separate language intended to feel like FP-RISC. As the design
converged, most ordinary language behavior was shared: functions, data, pattern
matching, strict evaluation and the functional programming model. The visible
differences were increasingly the scripting surface, default libraries and the
execution environment: top-level `>` statements, bytecode execution, transactions
and host services.

That suggests treating Sol as a profile of FP-RISC. A programmer should be able
to move between application, systems and scripting work without learning another
set of meanings for ordinary expressions.

The name Sol still has a useful role. It identifies the scripting product and its
conventions, just as the name FP-RISC identifies the broader language and toolchain.
Separate branding, file extensions and command-line tools do not require forked
syntax, type rules or unrelated libraries.

## 2. A profile is a contract

A practical implementation of a profile may be a bundle of configuration options,
a prelude and runtime components. But the profile itself is the contract that
those components implement.

A declaration such as:

```text
profile sol.
```

means that the program expects a specified surface, library environment and set
of execution guarantees. It should not merely enable whatever collection of flags
happens to be associated with the current `sol` command.

The proposed Sol contract covers:

- Script entry, top-level sequencing and the meaning of `>` statements.
- Default imports, the prelude and module-resolution rules.
- The value/ownership model and the treatment of linear resources.
- Transaction boundaries, conflicts, retries and explicit effect escapes.
- Standard arguments, files, processes and other declared host facilities.
- Failure, diagnostics and the behavior of interactive execution.

The implementation can choose interpreter dispatch techniques, JIT thresholds and
storage optimizations provided they preserve the contract. Observable resource
failure and ownership behavior still need specification even when internal memory
management is an implementation choice.

## 3. Language, profile, target and host

These are separate questions:

| Concept | Question | Sol example |
| --- | --- | --- |
| Language | How are programs expressed and ordinary expressions evaluated? | FP-RISC |
| Profile | Which facilities and execution guarantees does this program require? | Sol scripting surface, prelude and transactional effects |
| Target | What executable representation is produced? | FP-RISC bytecode |
| Host implementation | How is that representation executed and connected to the environment? | POSIX runtime; potentially a QOS runtime |

The current compiler also uses `--system` to select supported execution systems.
See [2026-09-19-PROFILES.md](2026-09-19-PROFILES.md) for the implemented terminology and compatibility
matrix. The conceptual separation here does not claim every combination works.

Bytecode is a sensible default target for Sol, but it need not define Sol forever.
Other FP-RISC profiles could eventually target the same VM. Sol could potentially
be compiled to native code if that implementation supplied the same profile
contract, including transactional effects.

Conversely, executing FP-RISC bytecode does not automatically mean executing a Sol
program. The artifact's profile requirements and imported runtime facilities must
also be satisfied.

## 4. Shared meaning and observable profile differences

The goal is to preserve the meaning of ordinary language constructs across
profiles. This does not mean all observable program behavior is identical.
Transactions are semantics, not merely an interpreter optimization. A staged
file write differs from an immediate write; conflict retry can repeat computation
and some external actions. Programs must be able to reason about those differences.

Top-level `>` statements can largely be understood as script-entry sequencing
syntax. Their grouping still matters: in the current documented model, the script
run is the transaction, rather than each `>` statement being an independent commit.
See [2026-08-25-TRANSACTION.md](2026-08-25-TRANSACTION.md) for the actual contract and its exceptions.

The existing process interface makes important distinctions:

- `Proc.query` is intended for read-only queries and may run again on retry.
- `Proc.afterCommit` queues work under the documented commit/recovery rules.
- `Proc.runNow` performs an explicit immediate escape, outside rollback guarantees
  and subject to ordering restrictions.

Those names do not prove that arbitrary subprocesses are read-only or execute
exactly once. Network operations, interactive input and display operations also
need explicit effect contracts; filesystem transaction guarantees cannot simply
be assumed to cover them.

Interactive execution needs a separately settled boundary. One submitted cell per
transaction is a possible design. A whole session as one transaction is another
policy with very different consequences. Neither should emerge accidentally from
how the REPL calls the VM.

## 5. The library experience

Sol should make scripting, automation, scientific computation and exploration
convenient. It should share ordinary names and data abstractions with FP-RISC Base,
while choosing a suitable prelude and supplying scripting-oriented facilities.

Examples include prominent maps, structured external values, decoding into records,
file traversal, process execution, numerical arrays, statistics and interactive
display. Convenience does not require all modules to become unqualified globals or
all data to become dynamically typed.

The proposed scope is recorded in
[2026-09-19-PRELIM_BASE_LIBRARY_DESIGN.md](2026-09-19-PRELIM_BASE_LIBRARY_DESIGN.md). That inventory is
preliminary and is independent of whether the command is named `sol` or `fpr sol`.

## 6. Tools and packaging

A combined development tool and separate executables are compatible choices.
They should share implementation components rather than introduce separate copies
of the compiler or language semantics.

| Proposed tool | Responsibility | Source frontend required? |
| --- | --- | --- |
| `fpr` | Compile, build, run, inspect and package FP-RISC programs | Yes |
| `sol` | Run source scripts and provide interactive use | Yes |
| `fpr-vm` (working name) | Load and execute already-compiled bytecode artifacts | No |

A separate `sol` executable could omit native backends and unrelated development
commands. However, accepting source still requires parsing, checking, elaboration
and bytecode generation. It is not the same thing as a runtime-only deployment.

The independent runner is the important boundary for a device that should execute
programs without carrying the development toolchain. A compiler elsewhere produces
an artifact; the device carries a compatible runner and the required host services.

An illustrative future workflow is:

```sh
sol analysis.sol
sol                         # proposed interactive entry

fpr compile --profile=sol --target=bytecode analysis.sol -o analysis.fprbc
fpr-vm analysis.fprbc
```

**These artifact/runner commands and the `.fprbc` extension are proposed**, not
instructions for the current implementation. The supported combined entry today
includes `fpr sol script.sol`.

Executable packaging is also distinct from implementation language. A runner built
in Haskell would still require the Haskell runtime and whichever native libraries
it links, but need not ship the GHC compiler. Producing that runner for a new host
still requires a viable port of those dependencies, or an alternative runtime
implementation.

## 7. Where the current implementation stands

The current [tool entry point](../compiler/Main.hs) bundles Sol into `fpr` and
routes the Sol command to `Sol.Main`. The current build describes the combined
executable in [fp-risc.cabal](../fp-risc.cabal).

`fpr compile --target=bytecode` currently selects the bytecode-disassembly path.
A listing is not yet a versioned, serialized deployment artifact with an independent
loader and runner.

The [bytecode compiler](../compiler/Sol/Bytecode.hs) lowers the program to a register
machine representation. Its application operation handles PAP application after
lambda lifting; a separate runtime closure instruction is not needed for that model.

The [VM](../compiler/Sol/VM.hs) currently uses Haskell-hosted values and host
facilities. It is not yet a freestanding VM that can be moved to QOS simply by
implementing an opcode loop. The host runtime participates in value management,
external calls and transactions.

The documented supported Sol system is currently POSIX. A QOS host for the Sol
profile is a future direction, not an implemented compatibility claim.

## 8. A portable bytecode deployment boundary

To separate compilation from deployment, the next architectural steps would be:

1. **Define a serialized artifact.** Include a format version, code and constants,
   entry points, profile requirements and imported runtime operations.
2. **Validate at load time.** Reject malformed or incompatible artifacts with
   explicit errors. Validation and bytecode execution alone do not establish a
   security sandbox.
3. **Expose a runtime entry independent of source compilation.** The runner loads
   the artifact and invokes it without importing the parser or compiler pipeline.
4. **Specify the host interface.** Define values crossing the boundary, required
   services, ownership/lifetimes, failures and effect behavior.
5. **Provide host adapters.** Start with existing POSIX facilities, then implement
   other hosts against the same contracts where feasible.
6. **Check conformance across hosts.** Shared programs should establish agreement
   on ordinary values and effects, including retry and failure cases.

Bytecode format versions, profile/library versions and host API versions answer
different compatibility questions. An initial format can be simple, but its loader
must know which combinations it understands.

For QOS, supporting the instruction set is only part of this work. The runtime
must also supply the required value behavior, transactional services and other
imports. Unsupported requirements should be reported explicitly rather than
silently replaced with weaker behavior.

## 9. Proposed direction and open decisions

The working direction is:

- **Sol:** the user-facing scripting environment and product name.
- **Sol profile:** its language-surface, library and execution contract.
- **FP-RISC bytecode:** its default execution target and potential shared backend.
- **Independent runner:** the eventual portability and deployment boundary.
- **Shared components:** the implementation basis for both combined and separate
  development tools.

Still to decide:

- Whether the first distribution ships `sol`, only `fpr sol`, or both.
- The runner's name, artifact format and minimum host dependencies.
- The exact Sol prelude and versioned library requirements.
- Interactive transaction/session boundaries and persistent session state.
- Which profile/target/host combinations to support first.
- Whether and when to provide an alternative VM implementation for hosts that
  cannot support the current Haskell-based runtime.

These decisions can be made incrementally. Defining Sol as a profile preserves
one language model while leaving room for distinct tools, runtimes and deployment
sizes.
