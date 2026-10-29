# Sol: incremental prelude compilation (2026-10-29)

Problem (docs/2026-10-29-SOL-STARTUP-ANALYSIS.md, the REPL latency analysis in
PR #25): every compile parsed, typechecked, specialized, lowered and
bytecode-compiled the whole ~450-line prelude. On the box that was ~37 ms of
every REPL command (typecheck 25, bytecode 8.5) and ~100 ms of every first run
of a new script (prelude parse 30, typecheck 39, bytecode 9). The program was
then shaken down to the handful of functions the run can reach.

## Options considered

**A. Environment snapshot.** Typecheck the prelude once, keep the inference
state (schemes, substitution, operator sites, deferred declarations, struct
tables), check user code against it, and link the new bytecode against
prelude bytecode compiled once. Rejected for now. `Infer.inferTopsResult` and
the passes after it are whole-program:
- struct conformance runs over the final environment;
- deferred signature revalidation runs against the final substitution;
- operator-site resolution and the rebuild rewrite prelude bodies too;
- precondition splicing (`Precond.applyPreconds`) runs over the combined tops;
- `Struct.specialize` and `Mono.specializeFunctions` clone prelude functions
  per user call site;
- lowering numbers lifted lambdas, join points and specializations from
  global counters.

Making each pass incremental, with an exact-equivalence argument for each,
is days of work. A mistake would be silent: a stale scheme or a wrongly
resolved operator.

**B. Demand-driven prelude slice (chosen).** Run the *unchanged* pipeline,
but over only the prelude declarations the program can name. Most of the
prelude is never named by a given script, and an unnamed declaration cannot
change how the rest of the program types or compiles (the exceptions are
listed under the invariants). The pipeline is unchanged and only its input
shrinks, so every whole-program step still sees the whole program it
compiles.

## Mechanism (compiler/Sol/Slice.hs, Sol/Main.hs `compilePrepared`)

1. **Seeds.** These are every identifier-like string in the user program
   (including `use`d modules), plus their dotted prefixes. They are taken
   after alias and path-literal expansion, so the path codecs' `wire*` names
   count as mentions.
   - Fixed seeds are names the compiler introduces later: `and`/`or`/`not`,
     `Ok`/`Err`, `Cons`/`Nil`, `Int.mod`/`Int.pow` for `%`/`^`, the float
     splices, `$unsafe`, and others.
   - Builtin names are also fixed seeds, so a prelude definition that shadows
     a builtin is never dropped.
2. **Closure.**
   - A seed reaches a declaration by its name. A bare member or operator also
     reaches every struct or sig that has that member (`x.len` and `a + b`
     are resolved by operand type).
   - Inside kept prelude code, references are followed by name only. Prelude
     code spells struct calls qualified, and its own operators are resolved
     by its own operand types.
   - Type declarations are always kept.
3. **Trial compile.** The sliced program goes through the normal
   `compileScript`. Its diagnostics are held (`Sol.Diagnostic.withBufferedDiagnostics`)
   and its result is deep-forced. If the trial is rejected for any reason
   (type, safety, linearity or struct errors; `error` calls in later passes;
   an unbound name), the program is compiled again with the whole prelude,
   exactly as before. That compile's diagnostics are the ones the user sees.
4. **Parsed prelude cache.** The parsed prelude is a `Binary` `[STop]`. It is
   cached under `prelude/` in the cache directory, keyed like a module (cache
   schema, executable identity, prelude text). A first run of a new script
   decodes it (~3 ms) instead of parsing (~30 ms). `SOL_CACHE=0` always
   parses. The REPL loads it once per session.

## Invariants (why the output is the same)

- **Under-inclusion is never silent.** A missing prelude name is unbound or
  has no operator target, so the trial fails and the full compile runs. A
  silent change would need a candidate *set* that differs. The cases are:
  - Builtin shadowing: prevented by the fixed builtin seeds.
  - Operator or member dispatch: a user-written member or operator keeps
    every struct and sig that has it. Prelude-internal operators are typed
    by prelude code alone.
  - User-defined names that collide with prelude names: user names are
    mentions, so the colliding prelude declaration is kept.
- **Constructor tags** are numbered by type-declaration order. All prelude
  types are kept, so tags are identical.
- **Record shape ids** are numbered by first appearance. The prelude's only
  records are its structs' first-class values. `Sol.Slice.shapeSeed` puts
  them first, taken from the whole prelude, in both modes. With
  `SOL_INCREMENTAL=0`, output is byte-identical to main.
- **Diagnostics.** Errors always come from the full compile. Successful
  compiles can print notes:
  - Notes that name only user code (realtime escapes, the notypes pragma)
    are printed from the trial.
  - Typed-hole notes print type-variable names, which come from the whole
    program's fresh-variable supply. A trial that has one is redone in full.
  - `SOL_TYPES=1` and `SOL_WIDTHS=1` always compile in full, because they
    print inferred types.
- **What does differ.** Compiler-generated names (`lifted_N`, `f_fb_N`,
  `$spec...mono.N`, `case_join_N`) are numbered from global counters, so they
  start at different values. They are internal: they never reach program
  output and are not persisted. The compile-cache schema is bumped (4 → 5)
  so no entry mixes the two numberings.

## Escape hatch

- `SOL_INCREMENTAL=0` always compiles against the whole prelude. With it,
  `--asm` output, stderr and exit status are byte-identical to main on all
  112 `.sol` files in the tree.
- `SOL_INCREMENTAL=trace` prints the slice size and any fallback, with its
  reason.

## Evidence

- `tools/sol-incremental-check.py` (in `tools/sol-ci.sh`) checks 169 cases:
  - `--asm` of every `.sol` in the tree plus 24 generated programs. These
    cover type errors, holes, shadowed prelude names and structs, method and
    operator dispatch, sig carriers, `%`/`^`, Vec operators, interpolation,
    wire codecs and `main`.
  - Executed output of the generated programs.
  - 10 REPL sessions: redefinition, prelude shadowing, `use` libs, type
    errors mid-session followed by recovery, panics, parse errors and
    multi-line input.

  Each case is compared under `SOL_INCREMENTAL=0` and the default, with the
  cache off. stdout, stderr and the exit status must be equal. Listings are
  compared up to renaming of compiler-generated functions.
- All Sol suites pass.

## Measurements (box, Linux x86-64; see the PR for the tables)

- REPL marginal cost per trivial command: ~50 → ~4.9 ms.
- First run of a new hello script: ~113 → ~26 ms.

## Limits / next steps

- **Large libraries.** A program that pulls in large libraries (json + csv)
  still typechecks the libraries themselves. First run: 165 → 125 ms. The
  next step is the same idea one level up: cache checked library modules.
- **REPL error path.** A command that fails to compile now costs a trial plus
  a full compile (~5 + ~37 ms). This is only on the error path.
- **Approach A** is still the way to make the REPL O(new input) for very
  large sessions. Session text is still recompiled, but a session no longer
  carries the prelude.
