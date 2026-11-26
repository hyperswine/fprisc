# Sol: statement results, `x = > e.` (27 November)

Kind: owner decision (26 Nov 2026) and its delivery record. Branch
`sol-progressive`. It follows [progressive commits](2026-11-26-SOL-PROGRESSIVE-COMMITS.md),
which made each `>` statement its own transaction and left one gap: statements
shared no values.

## The decision

The owner's direction: allow values between statements, but with discipline.
They proposed returning the value from the statement itself:

```text
x =
  >
   ...
```

## The form

```sol
total = > List.fold (fn a x -> a + x) 0 (List.range 1 10).
label =
  > "sum={total}".
out = >! ProcessResult c o e = unwrap (Proc.runNow (ProcessSpec ["git","rev-parse","HEAD"] "" [] "" 5000)); Str.trim o.
> writePath "build/commit.txt" out.
> print label.
```

`x = > e.` is a transactional statement and `x = >! e.` an immediate one. Each is
numbered with the other statements in file order and follows their rules. Once
the statement commits, its value is bound to `x`.

## The discipline

1. **Only a statement may read a result.** A top-level definition that names one
   is refused:

   ```text
   `double` reads statement result `n`: only a statement may read one (pass it as an argument)
   ```

   Definitions stay pure functions of their arguments; a result reaches one only
   as an argument.
2. **A statement may read only results bound before it.** File order is
   execution order:

   ```text
   statement 1 (`>`) reads `later`, which statement 2 binds: a statement may read only results bound before it
   ```

3. **A result exists once its statement has committed.** A retried statement
   recomputes its value. An aborted statement leaves no value, and the run stops
   there anyway.
4. **Reading a result does not run its statement again.** The value is stored;
   the realtime check treats a result as a plain value, so a `>` statement can
   read the output of a `>!` one.

Not checked yet: a result whose value is a handle, a process job or another
linear resource. Those belong to the transaction of the statement that made them
and are invalid in the next one. Plain data (strings, numbers, lists, records)
is what a result is for.

## How it is built

- **Parser** (`Frontend/Parser.hs`, `resultDecl`): `x = > e.` is the top-level
  definition `x = Stmt.result (-1) (fn _$result -> e)`. The thunk is never
  called. It exists so that inference, which runs before statements are
  numbered, gives `x` the type of `e`. The statement body is shared with
  `evalDecl` (`statementBody`), `>!` marker included.
- **Builtin** `Stmt.result : Int -> (Unit -> a) -> a` (`Sol.Infer`, `Sol.Hal`):
  it answers slot `i` of a per-process table and never calls the thunk.
- **Numbering** (`numberEvals`): such a definition becomes statement `i` (body
  `e`, `top__i` or `topnow__i`), and `x`'s slot argument becomes `i`.
- **Rules 1 and 2** (`resultOrderErrors`) use free variables (`sFree` minus each
  definition's own parameters), so a parameter that happens to be named like a
  result is not a read.
- **Run loop:** `runTxAttempts` keeps each statement's value and records it in
  the table only after a clean commit.
- **Safety:** the result definition is checked as a statement (a clause of
  `main`), like any `>`.

The native compiler parses the form but has no `Stmt.result`, so a native
program that uses it fails with an unbound name: statements are a Sol facility.

`tests/sol-checks/statements.sol` covers carrying a value, both refusals, and a
retried statement recording its result once.
