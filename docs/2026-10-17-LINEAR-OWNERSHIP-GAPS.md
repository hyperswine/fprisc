# Linear ownership propagation audit

Audited source: `ee84d90ae524263c9f38a57e76cfc017ad2fb7bc` (2026-10-17).
All checks ran locally. No printer, remote host, or production service was used.

Subsequent implementation and remaining gaps are tracked in
[ownership corrections](2026-10-17-OWNERSHIP-CORRECTIONS.md). The measurements
below retain the original pre-fix audit snapshot.

## Conclusion

There are confirmed soundness gaps in ordinary typed FP-RISC code. Ownership
information can disappear through polymorphic calls, generic constructor
patterns, records, returned/higher-order closures, indirect partial applications,
case results, and pattern guards. These bypasses do not require `keep`, raw
native IDs, or deliberate owner reconstruction.

The explicit printer owner APIs and their direct-flow tests remain useful, but
they do not establish ownership safety for arbitrary compositions. The
[printer ownership document](2026-10-17-PRINTER-OWNERSHIP.md#trust-and-language-boundary)
already identifies general ownership propagation as separate compiler work.
Native resource checks remain a necessary backstop.

## Fresh evidence

[Diagnostic source](../tools/audit_linear_ownership.py) contains 24 small programs
using a nominal linear `Token` with a harmless printing consumer. The token has
no destructor or external resource. Both frontends check each program; Sol runs
accepted programs, and `--native-run` also builds/runs accepted native programs.
[Recorded output and complete sources](evidence/2026-10-17-linear-ownership-gaps.json)
show:

| Probe group | Count | Native | Sol |
| --- | ---: | --- | --- |
| Direct duplicate, captured lambda, tuple, direct partial application controls | 4 | All refused for linearity | All refused for linearity |
| Unintentional ownership bypasses shared by both frontends | 17 | All accepted | All accepted |
| Unannotated parameter/result ownership | 2 | Both refused for linearity | Both accepted |
| Deliberate `keep` escape, recorded separately | 1 | Accepted | Accepted |

Thus 19 invalid ownership probes were accepted by at least one frontend. These
are test cases, not 19 independent root causes. Every accepted execution printed
the consumer twice, except `Box _`, which silently discarded the owner. Native
execution confirmed all 18 accepted native probes, including the explicit escape.

Reproduce from the repository root:

```sh
XDG_CACHE_HOME=/private/tmp/fpr-pure-cache python3 tools/audit_linear_ownership.py --native-run --json /private/tmp/linear-ownership-gaps.json
```

Exit status 1 means an invalid program was accepted. This diagnostic deliberately
remains outside the passing regression suite while the gaps exist; its goal is
eventual refusal of every invalid non-escape probe.

### Actual frame buffer consequence

This separate native program was compiled and executed locally:

```fpr
profile base.
FB = use "examples/printer-dashboard/framebuffer".
duplicate : a -> (a, a).
duplicate x = (x, x).
main = case FB.open 4 of
    FB.Refused why -> error why
  | FB.Opened owner ->
      (first, second) = duplicate owner;
      print (FB.close first, FB.close second).
```

It compiled successfully and returned `(Ok (), Err closed)`. The compiler
allowed two owners for one four-byte native buffer. The native registry safely
rejected the second close. This demonstrates a static ownership failure even
through the normal buffer API; it does not demonstrate an actual native
double-free, leak, or remote connection failure.

## Confirmed gaps and source causes

| Area | Accepted example | Current source mechanism |
| --- | --- | --- |
| Polymorphic functions | `duplicate : a -> (a,a)` duplicates a linear owner; `identity : a -> a` returns an owner that can then be reused | `shapeOfTy` treats type variables as unrestricted; call results use declaration-level shapes without instantiated ownership (`compiler/FPRISC.hs:2544`, `:2773`) |
| Generic containers | Matching `Box Token`, `Result Token String`, or `List Token` permits duplicate payload consumption; `Box _` permits loss | Constructor fields use generic declaration types and `bindPat` does not substitute actual payload ownership (`compiler/FPRISC.hs:2567`, `:2647`) |
| Records | Literal/projection/pattern loses field ownership; update permits consumption through both old and updated records | `SRec`, `SProj`, `SUpd`, and record patterns return/bind unrestricted shapes (`compiler/FPRISC.hs:2643`, `:2680`) |
| Higher-order and returned closures | A callback used twice accepts a linear captured closure; returned closures and closures forwarded through identity can be invoked twice | Arrow types are unrestricted, lambda parameters begin unrestricted, and signatures do not express closure ownership/call multiplicity (`compiler/FPRISC.hs:2548`, `:2694`) |
| Indirect partial applications | Aliasing the function or choosing it in a case before partial application hides the captured owner | Partial-application detection depends on the named head's signature/arity; non-variable call heads return unrestricted ownership (`compiler/FPRISC.hs:2773`) |
| Case result joins | A case with one unrestricted closure arm and one linear closure arm can return a reusable linear closure | Input-use agreement is checked, but result ownership comes only from the first live arm (`compiler/FPRISC.hs:2712`) |
| Pattern guards | `t <- Token 7` followed by two consumptions is accepted | Guard pattern bindings are assigned unrestricted shape instead of the RHS shape (`compiler/FPRISC.hs:2598`) |
| Sol inference parity | Unannotated functions can create or duplicate owners that native checking tracks | `compiler/Sol/Infer.hs:43` discards inferred linear signatures; Sol builds declaration-only ownership info (`compiler/Sol/Main.hs:249`), whereas native merges inferred signatures and builtins (`compiler/Compile.hs:714`) |

The central representation is `LShape = LU | LL | LTupS [LShape]`
(`compiler/FPRISC.hs:2530`). It preserves tuple structure but has no field-level
record/container structure or function ownership metadata. Inferred signatures
also collapse unresolved and functional types to unrestricted
(`compiler/Infer.hs:1671`). Adding more named owner wrappers cannot close these
general propagation gaps.

## Recommended implementation order

1. **Restore Sol parity.** Retain inferred ownership signatures through the Sol
   inference wrapper and merge them into checking. Turn the two inferred cases
   into refusal regressions. This is a bounded fix, not the general solution.
2. **Check instantiated ownership throughout typed expressions.** Preserve
   generic payload and record-field ownership instead of re-deriving shallow
   shapes from uninstantiated declarations. Polymorphic identity must preserve
   ownership; polymorphic duplication must require a duplicable/unrestricted
   argument. Pattern matching and wildcard loss must use instantiated fields.
3. **Track function values and call multiplicity.** Preserve captured ownership
   through returns, higher-order parameters, aliases, and dynamic partial
   applications. A callback that may run twice must refuse a single-use closure.
   This information must survive lowering and specialization.
4. **Define record moves and consistent control-flow joins.** Projecting an owner
   needs a rule for the remaining owned fields, whether through complete
   destructuring, explicit moves, or constrained borrowing. Merely marking a
   projection linear is insufficient. Updates must consume/transfer the old
   record, joins must account for every arm, and guards must preserve RHS ownership.
5. **Harden deliberate escape boundaries separately.** Opaque owner constructors,
   typed disposal, `keep`/`drop`, and native/actor transfer contracts need explicit
   trust rules. Restricting these escapes alone would not fix the safe-language
   bypasses above.

For each fix, add positive examples of legal single-use composition alongside
the relevant refusal probes. Do not make rejection of all generic ownership
composition the permanent solution.

## Limits

This is a focused audit, not a proof of whole-language ownership soundness.
Deep row polymorphism, recursive ownership, additional alias combinations,
borrowing lifetimes, and actor/native transfers were not exhaustively audited.
No claim about physical-printer operation or long-duration resource behavior is
made. This change records evidence and a diagnostic; it does not change the
compiler.
