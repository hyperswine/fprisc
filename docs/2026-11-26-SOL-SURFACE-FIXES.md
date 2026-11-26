# Sol: the porting gaps rechecked and fixed (26 November)

Kind: delivery record. Branch `sol-progressive`. Items 1 and 2 of the order in
the [Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md) §5.4; item 3 is
[progressive commits](2026-11-26-SOL-PROGRESSIVE-COMMITS.md).

## 1. The gap list, rechecked at this revision

Each row of the review's §3.2 table and its unrechecked list (§5.2) was run
again on this branch:

| Gap | Now | Action |
|---|---|---|
| A name beginning with `case`/`of`/`Type` | parses | fixed in the parser ([v1 defects](2026-11-26-V1-CONFORMANCE-AND-DEFECTS.md)) |
| `exists`, `Try.stat`, `Try.readPath` on a missing path create its parent folders | they do not | **fixed**, §2 |
| Defining a prelude name (`writeNow`, `collect`, ...) | refused with a clear message | **fixed**, §3 |
| Defining `run` (a runtime builtin the prelude declares by signature) | works with your own signature; a loud type error without one | unchanged: not silent |
| Defining `read` | works; a user `read` does not disturb `readPath` | not reproduced (§3) |
| A string inside `{...}` interpolation | `"{f "abc"}"` works in Sol and native | none needed; only the escaped form `\"...\"` inside the braces fails, and that is not valid expression syntax there |
| Escaping a brace | `\{` and `\}` work | none needed (the review's "no brace escape" was wrong) |
| Module aliases re-exported (`W.M.k`) | works | none needed |
| Top-level values recomputed at each reference | still true | waits on the nullary-definition rule decided 26 November, which waits on the effect bit (core spec Q3) |
| `<=` on strings | type error | **owner decision** (v1.0 semantics §5, marked [decide]) |
| Guards on local functions | parse error | **owner decision**: guards exist on top-level clauses only (semantics §3) |
| `fn _ ->` | parse error | **owner decision** (semantics §3, marked [decide]) |

`tests/sol-checks/sol-surface.sol` (push tier) runs one script per fixed or
confirmed row.

## 2. Reading a missing path no longer creates folders

**The bug:** at commit, Sol locks every path a statement read so it can validate
it, and a lock is a directory beside the path (`p.sol-lock`). Taking it created
the missing parents, so `exists "a/b/c.txt"` left `a/b` behind.
coscad's `models/lib/root.sol` carries a workaround for this.

**The fix:** commit now leaves out of its lock list any path the statement only
read whose parent folder does not exist (`Sol.Txn.commit`). This is safe for two
reasons:
- While the parent is missing, the path is missing, which is all the read
  claimed.
- A writer that creates it in the meantime changes what validation sees, and the
  statement retries.

Content and directory validation run over the read maps as before. Metadata
promises for such paths are checked inside the locked section. The paths are
removed from the list rather than skipped while locking, because the release
step would otherwise delete another process's lock of the same name.

## 3. Defining a prelude name is an error

**The cause:** a top-level definition joins the prelude's definition of the same
name, because all clauses of one name form one function. It does not replace it.
Two tracked scripts defined their own `writeNow` (a streamed write). The
prelude's clause matched first, so their definition was silently never used. The
1b1072b2 warning named the clash, but scripts kept compiling.

**Now:** it is an error:

```text
writeNow is defined by the Sol prelude; a definition of the same name joins the
prelude's instead of replacing it -- rename yours
```

Both scripts (`machine/tangnano20k/examples.sol`, `tools/build-static-arena.sol`)
call theirs `writeStreamed` now.

**Runtime builtins are different.** For a builtin the prelude only declares by
signature (`run`, `read`, `write`), a user definition with its own signature
replaces it, as `tools/archive-smoke.sol` does with `run`. That explains why
`read` could not be reproduced as broken. What the Spectre port saw remains
unexplained; the script at the commit where it happened is still the reproducer
to find.

## 4. Item 2: `unsafe` spreading

The review's item 2 was "stop `unsafe` spreading to callers of a function whose
recursion has a stated measure". That already holds: a callee with a verified
measure, linear or structural, taints none of its callers. Only an
`unsafe`-marked function spreads.

What pushes scripts to `unsafe program.` is recursion that cannot be given a
measure, such as the process pool in `tests/sol-checks/helpers.sol`. The rule
decided in outline for that is the per-invocation budget of
[recursion budgets](2026-11-26-RECURSION-BUDGETS.md): unproved recursion is
budget-checked in Base, and Sol follows Base. It is not implemented, and its
default limit and project-file questions are open. Implementing it is the real
end of item 2.
