# Sol as a scripting language: review against its goals

Date: 2026-11-26.
Kind: assessment. Proposals only; nothing here changes code.
Source: `main` at `dcd3db0f`, macOS arm64.

Sol's goals come from three records:

- [What is Sol?](2026-09-19-WHAT_IS_SOL.md): a profile of FP-RISC, with no new
  meanings for ordinary expressions, and with transactional effects.
- [Dependable daily scripting](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md): replace
  Bash and Python maintenance scripts, with predictable failures and resource use.
- [Science vertical](2026-11-08-SOL-SCIENCE-VERTICAL.md): the "Python for data" story.

The evidence is what happened when real scripts were ported between 12 and 18
November, plus the checks rerun for this review (section 3).

## 1. Summary

Sol has met the daily-scripting goal at real scale: both repositories now carry no
Python or shell scripts of their own. The goals that set Sol apart have not held up
in practice yet:

- **Transactions:** the biggest real scripts bypass them.
- **One meaning shared with FP-RISC:** small differences still cost time on every port.
- **Data work:** it has no maths library and needs native helpers for anything binary.

## 2. Where it meets its goals

### Replacing Bash and Python

| Where | What was ported | Verified by |
|---|---|---|
| fprisc | Every repository Python and shell script ([Sol-only main](2026-11-13-SOL-ONLY.md)); checks driven by `tests/run.sol`, about 4,500 lines of Sol across 46 files under `tests/sol-checks` and `tools` | The Sol check suite |
| qos | The test runner (`checks/sweep.sol`): 18 minutes at 6 workers, against 70-75 serially | Expected-red list unchanged |
| qos | All 29 Spectre build and board scripts | Nine build artifacts hash identically to the shell build; board checks run live on the hardware |
| fprisc | The Tang Nano / Arty board runner (`machine/tangnano20k/examples.sol`) | 7/7 on QEMU and on the Arty board |
| coscad | The model scripts, from Python | Output compared with the Python originals |

### Predictable failures

Checked types, separate output and diagnostics, meaningful exit codes, structured
argv and process control all held up through these ports. None of the ports reported
a script misbehaving silently because of a type mix-up.

### Small data jobs and apps

- `sol/examples/csvplot.sol` runs CSV → robust fit → chart in 98 ms.
- The eight web examples run on the Sol MVU runtime.

## 3. Where it is under strain

### 3.1 The transaction model is mostly bypassed in long scripts

**The problem:**

- Writes land at commit, and reads such as `Try.exists` and `readPath` join the
  transaction.
- So long-running scripts switch to:
  - `readNow` / `writeNow`;
  - `Proc.start`;
  - staging folders for files that external tools must see before commit.
- The 25 November audit added `writeBytesNow` / `writeTextNow` to `sol/lib/base.sol`
  because scripts kept reimplementing them.

**How often it happens:**

- `tests/run.sol` ends with "NOT atomic overall: 24 realtime escapes".
- The qos runner bypasses transactions in the same way.

**The pattern:** transactions fit short file-editing scripts well. They do not fit
orchestration, and orchestration is most of the Sol that has been written so far.

### 3.2 Differences from FP-RISC and parser gaps

The ports kept hitting the same kinds of surprise. Each was rechecked on `dcd3db0f`:

| Item | Status now |
|---|---|
| Defining `run` | Now refused, but with four type errors about `Module -> a -> String` instead of "`run` is a reserved name" |
| Defining `read` | Works in a plain script (prints 5). It misbehaved silently in the Spectre port; not reproduced here |
| A name starting with `case` (`casesArg`) | Still a parse error, reported at the end of the line rather than at the name |
| `exists` on a missing path | Returns `False` and **still creates the missing parent folders** |
| `<=` on strings | Still a type error ("not defined for String"); use `Str.cmp` |
| `7 / 2` | Still `3` (integer division); real division is `Num.div` |
| A bare `None` | Fixed 22 November: it always means `Option`, and "no command" is `Cmd.None` |
| Prelude names shadowed | A warning since `1b1072b2` |
| `Str.words` and tabs | Fixed in `1b1072b2` |

The ports also recorded these, which this review did not recheck:

- Quotes inside `{}` interpolation do not parse, and there is no brace escape
  (scripts use `chr 123`).
- Functions defined inside a block cannot have guards.
- `fn _ ->` is not accepted.
- Module aliases are not re-exported.
- Top-level values are recomputed on every reference.

The goal is "no new meanings for ordinary expressions". The worst offenders are
reserved names that fail without a clear message, and `exists` changing the
filesystem.

### 3.3 The safety rules push scripts into opting out

- Recursion needs an `unsafe` signature, and that marking spreads to every caller.
- Ports reach for `unsafe program.` at the top of a file, which switches the
  checking off for the whole script.
- The `result-sizes` Sol check currently fails on exactly this rule.

### 3.4 Native helpers fill library gaps

- **No maths library:** coscad wrote its own `sin`, `cos`, `tan`, `atan2`, `exp` and
  `log` in `models/lib/num.sol` (`Num.sin` is still unbound).
- **No serial-port access.**
- **No binary-format support** (lz4, Gowin bitstreams, the boot header).

So the Spectre port needed `spectre-image.c` and `spectre-uart.c`, and the board
runner needed `board-host.c`. `PipeCapture` is capped at 16 MiB.

### 3.5 Speed and reach

**Speed:**

- An interpreted operation takes about 0.5-1 µs.
- That is fine for orchestration, but the Spectre stress `analyse` step takes about
  2 minutes, and data work depends on native vector operations.

**Reach:**

- Releases are macOS arm64 only (0.15.0); there is no Linux toolchain.
- Running Sol from a worktree needs a real copy of `fpr`, not a symlink, because Sol
  trusts libraries only under the binary's home.
- The `sol` skill documentation predates 0.13 and still describes older behaviour.

## 4. Proposed order

Ranked by return on effort:

1. **Report reserved names and parser gaps as clear compile errors, then remove them.**
   - Give "`run` is reserved" a direct message.
   - Accept identifiers that begin with a keyword.
   - Stop `exists`, `Try.stat` and `readPath` from creating parent folders.
   - Allow `<=` on strings.
2. **Add a step-by-step commit mode** for long scripts, with a commit per step, so
   orchestration can stay transactional instead of escaping it. Start from the
   `writeNow` / `Proc.start` patterns the runners already use.
3. **Add maths and byte or serial libraries**, so ports stop needing C helpers.
   - Maths: `libm` wrappers.
   - Bytes and compression.
   - A serial port as a linear resource.
4. **Release a Linux toolchain**, and refresh the `sol` skill documentation.
5. **Unify the library with `std`** (audit item 6), so `sol/lib` and FP-RISC's `std`
   stop drifting apart. The same applies to the MVU surface: share the typed view,
   event and command types, and keep separate drivers.

## 5. Amendment (26 November, later the same day)

A second read of this page against the tree at `f607eb59`. Sections 1-4 stand;
this section adds what they left out and gives each proposal a test.

### 5.1 Success criteria for the proposed order

Section 4 ranks five items but says how to tell none of them is done.

1. **Reserved names and parser gaps.** A Sol check holds one script per row of
   the 3.2 table. Defining `run` reports one error naming it as reserved;
   `casesArg` parses; `exists`, `Try.stat` and `readPath` on a missing path
   leave the parent folder absent; `"a" <= "b"` type-checks.
2. **Step-by-step commit mode.** `tests/run.sol` and qos `checks/sweep.sol`
   end without the "NOT atomic overall" line, with their escape counts at
   zero or each remaining escape listed with its reason.
3. **Libraries.** coscad `models/lib/num.sol` is deleted and the models
   produce the same output; `spectre-uart.c` or `board-host.c` is replaced by
   a Sol serial resource and the same board checks pass.
4. **Linux toolchain.** `fprmeta` installs a released Linux archive on a
   clean machine and `tests/sol-main-smoke.sol` passes from it.
5. **One library.** A module that exists in both `sol/lib` and `std` has one
   source.

### 5.2 Findings that section 4 does not act on

- **Safety opt-outs (3.3).** The `unsafe` marking that spreads from one
  recursive function to every caller, and `unsafe program.`, are named as a
  strain and then dropped. They belong before item 2: a commit mode that
  scripts adopt under `unsafe program.` is not checked.
- **The unrechecked list in 3.2** (quotes and braces in interpolation, guards
  on local functions, `fn _ ->`, alias re-export, top-level values recomputed
  on every reference). Recheck each at the current revision first, then put
  the ones that still hold under item 1.
- **`read`.** "Not reproduced here" leaves a silent misbehaviour open. The
  Spectre port's script at the commit where it happened is the reproducer to
  find; until it is found the item stays open rather than fixed.

### 5.3 Corrections of emphasis

- **Linux is a packaging gap, not a port.** CI builds the compiler and runs
  the Sol checks in `debian:trixie` on every push (`.github/workflows/ci.yml`,
  jobs `sol-native` and `sol-checks`). Item 4 is a release archive and an
  index entry.
- **The science vertical is cited as a goal and not assessed.** The only
  evidence here is `csvplot.sol`. That plan needs its own review against its
  milestones; this page should not be read as one.
- **`result-sizes` passes.** Section 3.3 says the check currently fails. In a
  push-tier run of `tests/run.sol` on macOS arm64 at `f607eb59` plus the
  nullary literal fold, it passed and no known-failure entry was hit.
- **QOS has no pointer to this page**, although qos `checks/sweep.sol` and
  the Spectre port are half of its evidence.

### 5.4 Order after this amendment

1. Recheck the unrechecked list; then item 1 with its Sol check.
2. Safety opt-outs: stop `unsafe` spreading to callers of a function whose
   recursion has a stated measure.
3. Step-by-step commit mode.
4. Maths, bytes and serial libraries.
5. Linux release archive; refresh the `sol` skill.
6. One library with `std`, and the shared MVU types (see
   [MVU alignment](2026-11-26-MVU-ALIGNMENT-INTENT.md), non-goals).
