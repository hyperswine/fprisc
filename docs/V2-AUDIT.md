# V2-AUDIT -- the reported issues, re-checked against the tree

`docs/FPR-QOS-REVIEW.md` (2026-08-29, commit 614a9e9) is the standing
issue list.  V2 cannot plan around a list that is a month stale, so
every finding in it was re-read against the source at HEAD
(`03bf0d9`).  This file is the result: status, the evidence, and the
v2 disposition.  It is a REGISTER, not a narrative -- when an issue is
closed, the row says so and points at what closed it.

Status vocabulary: **FIXED** (the mechanism that caused it is gone),
**PARTIAL** (the sharp edge is blunted, the shape remains), **OPEN**
(reproduces as described), **CHANGED** (the finding no longer applies
because the design moved).

Method: source reading only.  GHC and cabal are not installed in this
environment, so nothing here was reproduced by running the compiler;
rows that would need a run to settle say so.

---

## 1. The verified bugs

| # | finding | status | evidence |
| --- | --- | --- | --- |
| 1 | `Sys.arena` leaves `bigfree` uninitialized | **FIXED** | `fpr_pool_init` exists (`runtime/fpr.h:127-132`) and sets all four fields; all 7 creation sites call it (`runtime.c:65,978`, `actors.c:1371,1410`, `entry.c:209`, `proc_entry.c:160`).  The arena site carries the war story as a comment (`runtime.c:978-980`). |
| 2 | `Vec.filter` skips copy-on-write | **CHANGED** | CoW is gone entirely -- `send` deep-copies (`vec.c:76-82`).  `fpr_vec_filter` compacts in place and the header now states why that is sound: "one owner, real copies" (`vec.c:399`).  The finding does not apply; the *replacement* invariant (one owner) is a SEMANTICS clause with no test -- see §4. |
| 3 | Sol auto-tabling unsound-by-spelling, on by default | **PARTIAL** | The spelling heuristic is gone: `tabEligible` walks the fn's Core and requires every call head to be in `arithOps` ∪ {self} ∪ locals (`Sol/VM.hs:124-145`).  Still **on by default** (`Sol/Main.hs:234-235`: only `SOL_TABLE=0` disables), and the `[table] ... dropped` diagnostic still goes to stderr unasked (`VM.hs:184`). |
| 4 | Malformed signatures silently swallowed | **OPEN** | `FPRISC.hs:967`: `try (fullSig n) <|> (skipTillDot >> pure TSkip)`.  A signature that does not parse still becomes a no-op, and signatures carry `unsafe`, contracts, and StdCheck's all-Int safety declaration.  This is the single highest-value "compiles anyway" hole left. |
| 4b | Non-adjacent clauses silently dropped | **FIXED** | `compileTop.groupClauses` now collects every clause of a name wherever it sits, matching `Infer.clausesOf` (`FPRISC.hs:1602-1610`), with the bug recorded in the comment.  Gated by check-all's "clause groups" leg (`tests/split.fpr`). |
| 5 | Sol's transaction net has half-outside members | **MOSTLY FIXED** | `txStat` consults the write view first (`Sol/Txn.hs:346-361`); `txExists`/`txIsDir` consult a new `txDirView` (`Txn.hs:90,320-339`); locks are PID-stamped with dead-owner reclaim (`Txn.hs:557-570`).  Remaining: `txIsDir` falls through to `doesDirectoryExist` on a view miss without joining a read set, so a dir decision taken on disk state is still not validated at commit (`Txn.hs:337-339`). |
| 6 | qosp crash diagnostics dead on Linux | **OPEN** | `qos/portable/main.c:308-312`: `pc` is extracted only under `#ifdef __APPLE__`; on Linux `pc = 0` and `in_image` is therefore always 0 -- the one fact the handler exists to report.  `_exit(139)` at :322 still skips `atexit`, leaving the terminal raw after a fault. |
| 7 | No fsync anywhere in the storage path | **OPEN** | `grep -rn "fsync\|fdatasync\|F_FULLFSYNC" hal/ qos/` returns **nothing**.  `store_call_locked` appends through buffered stdio and `fclose`s (`qos/portable/store.c:80-88`); `qos_blkraw_write` pwrites and returns (`machine/unix/blk_raw.c:103-111`).  DISK.txt's torn-write-rollback story is still a design, not a property. |
| 8 | The actor layer panics where an OS must degrade | **FIXED** | `send` returns `Err "mailbox full"` / `Err "dead actor"` rather than panicking (`actors.c:1591-1601`); the ARC table grows (`arc_grow`, `runtime.c:1099-1123`) instead of `fpr_cpanic("ARC table full")` on first pressure; `MAXSND`'s 9th sender falls into the shared ring `SHIDX` (`actors.c:65-72,1136`).  The remaining `cpanic`s are type errors and genuine invariant breaks. |
| 9 | Hardcoded matrix library inside type inference | **PARTIAL** | Still pattern-matches `w/x/y/z` and `m00..m33` and rewrites `*` into `mulMM`/`mulMV` (`Infer.hs:982-995`), but now gated on `ipMat4 (icProf ctx)` -- a profile flag, so it is at least a declared capability rather than a silent assumption.  The library naming convention is still baked into the HM engine. |
| 10 | Vestigial mass | **PARTIAL** | `Target.hs` is still imported by **nothing** (`grep -rn "^import Target"` is empty; `Compile.hs:6` gets the `Target` *type* from `Codegen`, and `Target.hs` survives only as a name in a comment at `Compile.hs:49`).  The README still sells it as "the profile model"; the model is six backend booleans in `Compile.Opts` (`:32-37`) with nothing rejecting the meaningless combinations.  `StdCheck.hs` still carries its `runghc CheckPoC.hs` header and its embedded demo programs (`StdCheck.hs:6,32,961`).  Closed since: `elfload.c` is live (`process.c:3`), the dead evaluators and `VBStr` are gone (`Sol/Val.hs:197`). |

## 2. The cross-cutting themes

| theme | status | evidence |
| --- | --- | --- |
| **The frontend fork** ("ONE frontend" was true only of the parser) | **FIXED** | `Sol/Infer.hs` 1012 -> **118** lines (a profile shim), `Sol/Lang.hs` -> **216** (tids, decode, splicing only).  A ratchet holds it: `fp-risc/tools/dedup-ratchet.sh` fails the sweep if either file grows past its ceiling, and it is a check-all leg. |
| **Operator-vocabulary drift** (`/=` whitelisted in three tiers where the language's operator is `!=`) | **FIXED** | One table, `Sol/Bytecode.arithOps` (`Bytecode.hs:60-77`), with every tier deriving its fragment from it and the drift recorded as the reason.  The only surviving `"/="` is `StdBridge.hs:148`, a different (StdCheck) surface. |
| **Sol's inverted pyramid** (quadratic interpreter under four acceleration tiers) | **OPEN** | `Sol/VM.hs:219` still builds frames as `IORef (M.Map Reg Value)`; `:229` still fetches with `drop pc code`; `:220`'s `let codeArr = code` is still the vestigial marker of an array conversion that never happened.  The LLVM ORC tier is gone (replaced by `HandJIT` 388 + `AsmX64` 176 + `AsmA64` 146 + `KIR`/`JitCore`), which shrinks the pyramid but does not fix its base. |
| **`BStr` does not deliver its own bound** | **OPEN** | `bsAppendStr` still rebuilds with `BS.take ... <> new <> BS.drop ...` on every append (`Sol/Val.hs:177-195`) -- O(n) per append, O(n²) for the loop it exists to fix. |
| **Five hand-copied walkers over one tid switch** | **OPEN** | `dc_release`, `dc_size`, `dc_dup`, `kp_dup`, `has_vec` (`runtime.c:574,610,680,843,941`).  Every new tid must still be threaded through all five by hand. |
| **Invariants in comments** | **PARTIAL** | The A64 TLS post-pass still pattern-matches an exact instruction-text sequence (`A64.hs:382-400`), and module identity is still FNV-64 over `Show` output (`Modules.hs:91-99`) -- but the latter now has a stated SPAN-PROOF seam (`stripPosTops`) so the coming span work cannot churn pins. |
| **Diagnostics have no source positions** | **PARTIAL** | Steps 0-3 of a retrofit have landed: `SMark !Int SExpr` statement marks (`FPRISC.hs:38`), `Sources`/anchors plumbed through `Modules.hs:80-83`, and `anchorMsg` rewrites `in NAME:` diagnostics to `file:line[:col]` (`FPRISC.hs:1854-1900`).  A check-all leg asserts four shapes including a spliced module's own file.  It is a string-rewriting layer over a positionless AST, not spans in the tree -- good enough to stop the bleeding, not the end state. |
| **Name magic** | **OPEN** | `isUnsafeName n = "unsafe" \`isInfixOf\` map toLower n` (`StdBridge.hs:270`); postconditions still ride a sibling sig literally named `post_f`. |

## 3. Usability and deployment

| finding | status | evidence |
| --- | --- | --- |
| No install story / toolchain undocumented | **FIXED** | `docs/INSTALL.md`, a brew tap, `./qos.py install --prefix`, and `qos/tests-host/install-check.sh` proving a scratch-prefix install from an empty directory.  The LLVM-18-hardcoded-path problem is gone with the LLVM tier (the cabal file's only platform dependency is now `EGL`/`GL` on non-darwin). |
| No CI | **PARTIAL** | `.github/workflows/release.yml` exists and builds a tag's bundles on ubuntu with distro GHC.  There is still **no push/PR workflow that runs check-all** -- the 12-15 minute sweep runs when a human remembers. |
| `qos.py` swallows build stderr | **OPEN** | `sh(..., quiet=True)` sets `stdout=DEVNULL, stderr=STDOUT` (`qos.py:141-151`), i.e. stderr lands in devnull.  Eleven call sites use it, including every `make -s fpr`.  A missing toolchain still yields `failed (2): make -s fpr` and nothing else. |
| Linux `fpr` hard-links libEGL/libGL | **OPEN** | `fp-risc.cabal`: `if !os(darwin) extra-libraries: EGL GL`.  A sol-only install still needs mesa present at link AND load time.  V2.md workstream 5 wants these `dlopen`ed. |
| Plaintext passwords taught as the sign-in pattern | **OPEN** | `sol/lib/auth.sol:21-27`: `Put "user:{model.pendu}" model.pendp` stores the password as given. |
| DRM/evdev appliance has no build target | **NOT RE-CHECKED** | Needs a build to settle; the Makefile reading in the original review is not contradicted by anything found here. |

## 4. What the audit adds to the plan

Three things the review did not flag, found while checking it:

- **The stale counts in V2.md.**  The three service idioms are bigger
  than the plan says: **73** `/services/*` string uses (not 13),
  **67** `device "..."` uses across 5 device names, and **28**
  `Sys.*` builtins (not ~15).  The migration in workstream 1 is a
  three-figure edit, not a dozen call sites.
- **The gensym leak is in the shipped library, not just in apps.**
  93 inference gensyms (`c29`, `p36`, `l31`, ...) appear in
  `core/prelude.fpr`, `std/*.fpr` and `programs/mods/*.fpr` --
  including `std/std.fpr`'s own `foldRange : unsafe Int -> Int -> (Int
  -> p36 -> p36) -> p36 -> p36 .`, the first signature a reader of std
  ever sees.
- **`Vec.filter`'s new invariant is untested.**  Dropping CoW for
  "one owner, real copies" is the right call, but nothing in
  `tests/` asserts that a vector reachable from two places cannot be
  filtered.  Issue 2 closed as a bug and re-opened as a missing
  SEMANTICS clause (§11) with an empty test slot.

## 5. The disposition

Ordered by (silent-corruption first, then blocks-another-workstream,
then cost).  Each row is a 2.0-alpha.2 item unless marked.

| do | issue | why now |
| --- | --- | --- |
| 1 | fsync at the QLOG commit points and in `blk_raw` (#7) | Silent durability loss; DISK.txt claims the property today.  Small. |
| 2 | Refuse unparseable signatures (#4) | A dropped `unsafe` or contract is a silently weakened safety proof -- it undermines the std workstream's own evidence.  ~5 lines + a negative leg. |
| 3 | `txIsDir` joins the read set (#5 remainder) | Closes the last hole in the transaction net's own promise. |
| 4 | Sol tabling default-off, or gated on an explicit effect judgment (#3) | A semantics-affecting experiment should not be on by default in the release that freezes semantics. |
| 5 | qosp `pc` on Linux + restore the terminal before `_exit` (#6) | Linux is the stated host; the handler is dead exactly where it is needed. |
| 6 | push/PR CI running check-all (§3) | Everything below is a conformance claim; conformance claims need a gate that runs. |
| 7 | Un-swallow build stderr in `qos.py` (§3) | One line.  Turns the most common first-run failure from mute to diagnostic. |
| 8 | Sol interpreter data structures: array frames, vector code (theme) | Re-baselines every acceleration tier before 2.0 freezes their behaviour. |
| 9 | `bsAppendStr` real amortised append (theme) | The type exists only to provide this bound. |
| 10 | One walker over the tid switch (theme) | Every new tid is five hand edits today; 2.0 adds tids. |
| 11 | `Target.hs`: make it real or delete it (#10) | The README sells it.  Decide in workstream 1 -- the profile model is exactly what the service-idiom decision needs a home for. |
| 12 | `dlopen` EGL/GL on Linux (§3) | Blocks "brew install for a sol user" in workstream 5. |
| 13 | Hash `auth.sol` passwords (§3) | It is taught as a pattern. |
| 14 | Retire `isUnsafeName`'s substring rule and `post_f` (#theme) | 2.1 -- language-visible, needs the deprecation cycle. |
| 15 | Real spans in the AST (#theme) | 2.1 -- the anchoring layer bought the time; the refactor is still the right end state. |
