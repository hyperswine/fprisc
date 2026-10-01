# Signatures are never dropped; Sol replaces its frame on a tail call

Date: 2026-10-02. Kind: implementation record. Fixes items 1 and 2 of
[2026-10-02-TOOLING-SEMANTICS-AUDIT.md](2026-10-02-TOOLING-SEMANTICS-AUDIT.md).

## 1. A signature the grammar cannot read is a parse error

`signature` in `compiler/FPRISC.hs` was

```haskell
try (fullSig n) <|> (skipTillDot >> pure TSkip)
```

When the full signature grammar failed anywhere after `name :`, the parser
skipped to the terminator and emitted nothing. The function was then inferred
from its body alone, with no diagnostic. The fallback is gone: `fullSig n` runs
without `try`, and its error (at the offending token) is what the user sees,
because megaparsec keeps the furthest error when `topDecl`'s alternatives all
fail.

### What the fallback had been hiding

Re-parsing the corpus with the fallback removed refused 13 std modules and 2
Sol examples, every one at a `{`. Record types (`{ f : T, g : U }`, and the
open form `{ f : T | r }`) were not in the signature grammar at all. Every
std signature mentioning one had been silently dropped since it was written:

```
std/config.fpr:28   load : { defaults : J.Value, file : O.Option String, ... } -> Result J.Value String .
std/live.fpr:83     http : { method : String, url : String, ... } -> (Result {...} String -> msg) -> Cmd msg .
std/term.fpr:155    loop : unsafe Int -> { update : Ev msg -> model -> ..., view : ... | r } -> ...
std/json.fpr:369    encode : { enc : a -> Wire | r } -> a -> String .
```

plus `ble`, `file`, `http`, `httpcore`, `proc`, `store`, `view`, `wifi`, `ws`,
and `sol/examples/example.sol`, `mlpipe.sol`. None of these declarations had
ever been checked against its definition or used at a call site.

### Record types in signatures

`Ty` gains `TRecT [(Name, Ty)] (Maybe Name)`. `tyAtom` parses
`{ f : T, g : U }` (closed) and `{ f : T | r }` (open on the row variable `r`,
shared by name across the signature). Field types are full arrow chains.
`tyToTypeA` (`Infer.hs`) lowers it to `TRec` over `RExt` cells ending in `RNil`
or a named row variable kept in the signature's variable table under a key no
type variable can spell (`'|' : name`). The three passes that rewrite type names
(`Modules.hs` hash qualification, `Sol/Lang.hs` alias and canonical-name
rewriting) descend into record fields. `shapeOfTy` treats a record as linear
when any field is.

Checking those signatures for the first time found one real defect in the
compiler rather than in std: the hash-qualification pass did not descend into
record fields, so `J.Value` inside `{ ... }` did not resolve to the imported
module's `Value@hash`, and `std/term.fpr`'s own `Ev`/`Cmd`/`Sub` inside its
`loop` record were left unqualified. With the traversal fixed, every std
module, every example (`logbook`, `pos1`, `service`, `todo`, `report`, `wc`)
and every Sol script type-checks under its real declarations. No std signature
needed changing.

### What it was hiding in qos

`qos/programs/mods/svc.fpr` carried 66 signature lines of the form

```
route : unsafe Caps@81bfbdefdd564023 -> String -> String -> IoV@81bfbdefdd564023 -> IoV@81bfbdefdd564023 .
```

nine or ten per function, one per past compile: the `FPR_UNSAFE_SUGGEST=1`
paste-ready suggestion printed the module's types by their hash-qualified
compile names, the grammar did not read `@`, every pasted line was dropped,
and the next compile suggested another. None of `route`, `dispatch`,
`dDisp1`, `dKeyboard`, `dModules`, `dPins` or `dStorage` ever had its
signature. The suggestion printer (`tyOf` in `Safety.hs`) now strips the
hash so it prints source (`route : unsafe Caps -> Int .`). svc.fpr keeps one
bare signature per function; `qlog.fpr` repins `svc` to the module's current
hash. `qos.py test` passes 12/12.

Two consequences worth stating. A module's identity is the hash of its AST,
and the AST now contains signatures it used to omit, so every module that had
a dropped signature has a new hash: the pin `svc#7a8f...` no longer resolves
from the working file, and the committed blob for `7a8f` in `qos/.fpr/store`
cannot be re-parsed to that hash either (its stale `@` lines are now parse
errors). A pinned version is immutable source, but its identity was computed
by one parser. And `fpr commit programs/mods/svc.fpr` cannot mint a new
version from qos: commit type-checks the module alone, and `Pin.read`,
`Pin.write`, `Pin.mode` are provided by the QOS system build, not by the
module's imports, so commit reports them unbound. That is the gap between the
audit's "commit now type-checks" and a module whose types come from a system
target; it was not addressed here.

Tests in `tests/check_cases.py`: `sig_malformed.fpr` (`| junk`) and
`sig_malformed_arrow.fpr` (`-> ->`) are refused at the token;
`sig_record_ok.fpr` (closed record and a shared row variable) compiles;
`sig_record_missing_field.fpr` (`closed record has no field .b`) and
`sig_record_wrong_type.fpr` are refused.

## 2. Sol tail calls

`compiler/Sol/Bytecode.hs` gains

```haskell
| TailCall Name [Reg]
```

`cTail` compiles a function body in tail position: through `let` bodies and
both arms of `if`, a known program global applied to exactly its arity becomes
`TailCall g rs` with no `Ret` after it. Over-application (the trailing
`Apply`s need this frame), arithmetic opcodes, HAL calls, locals and PAPs keep
the ordinary `Call`/`Ret` shape. This mirrors native `knownCall`: known
saturated self and mutual calls.

In the VM, `TailCall` evaluates its arguments and makes `execFnTail` the last
action of the activation. GHC compiles that as a jump, so neither the frame
`IORef` nor a continuation survives.

The tabling probe was the second half of the problem. `execFn` memoizes by
running the callee and then storing its result, which keeps a continuation per
call. A tail-recursive function that is tabling-eligible (pure arithmetic, at
most four parameters, which describes every measured countdown) therefore
still grew by one probe frame per iteration: 2.4 GB at 3M after the opcode
alone. `execFnTail` serves a table hit and otherwise runs the callee directly
without storing. The table still fills from non-tail calls (`fib`'s two
recursive calls are not in tail position), so `fib 27` reports the same hits
and misses as before.

The cache schema is bumped to 3: cached bytecode without `TailCall` is
rebuilt.

| Program (`fpr sol`) | Before | After |
|---|---|---|
| `count` 1M, measured self loop | 3.9 s, 1.87 GB | |
| `count` 3M | 11.6 s, 5.46 GB | 3.7 s, 30 MB |
| `count` 30M | killed at 300 s | 36.9 s, 30 MB |
| `ping`/`pong` 4M, mutual | not run | 5.5 s, 30 MB |

Test: `tests/check_sol_tail.py` runs the measured self loop and the mutual
pair at 3M iterations under a 400 MB peak-RSS ceiling (the old VM needed about
5.4 GB) and checks the listing ends in `TailCall` with no `Ret` after it.

## Not changed

- `Apply` in tail position (generic PAP application) still keeps the frame.
- The native profile already jumped; nothing there moved.
- The audit's remaining items: one measure language for `Safety.hs` and
  `StdCheck.hs`, resource bounds in signatures, commit comparing inferred
  interfaces, Sol store fallback, actor and `Mod.fn` typing.

## Verification

`tests/check_{cases,profiles,base,builtin,arc,raw,machine,export}.py`,
`tests/check_sol_tail.py`, `tools/sol-{safety,txn,proc-git,scripts,hjit-a64}-check.sh`
all pass. Every `std/*.fpr`, `examples/*.fpr`, `tests/*.fpr`, `sol/**/*.sol`
parses; every example builds. Every qos `.fpr` parses; `qos.py build` and
`qos.py test` (12/12) pass against this compiler with the svc.fpr and
qlog.fpr changes above.
