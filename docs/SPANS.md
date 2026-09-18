# Source spans: the staged plan

Post-parse diagnostics were location-free strings — the single biggest
usability gap, and the one that gets more expensive to fix every
month.  The fix is staged so each step ships value without touching
the AST until the machinery to do that safely exists.

## Step 0 — span-proof module identity  [LANDED]

`hashAST` (Modules.hs) hashes the POSITIONLESS tree: `stripPosTops`
(FPRISC.hs) erases any future source-position node before hashing.
Today it is the identity, so the hash string is bit-compatible with
every existing pin (the sketch-tier check-all leg's printed pin is
the regression test); from now on spans can never churn a pinned
module hash.

## Step 1 — bind-level anchors, no AST change  [LANDED]

Every diagnostic carrying the `in NAME:` prefix — all Infer errors
(the per-clause prefixer), every linearity error (lcheck now prefixes
its body/guard errors too) — is anchored to `file:line:` of NAME's
definition by the error sinks (Compile.hs, Sol/Main.hs):

* top declarations start at COLUMN 0 by the grammar, so `bindAnchors`
  (FPRISC.hs) finds a bind's line by scanning for its name at line
  starts — the signature line when one precedes the clauses, which is
  the better anchor anyway;
* spliced modules anchor to THEIR files: Modules.hs computes each
  unit's anchors at parse (ModUnit.muAnchors) and qualifies the keys
  with the unit hash, so `in leak@abc123:` resolves to the module
  source, not the root;
* struct-expanded and generated binds have no col-0 definition and
  simply pass through unanchored — graceful, never wrong.

check-all's "spans" leg holds the contract: a type error anchors to
the sig line, a linearity error to the named token, a module bind to
its own file, and a repeated token to the offending statement.

## Step 2 — statement precision via a locator  [LANDED]

Most error texts name a token (a variable, an operator, a field).
`anchorMsg` (FPRISC.hs) extracts it — the first 'quoted' token, else
the name after "application of " — and scans the bind's source range
(anchor line to the next col-0 definition) with identifier-boundary
matching; a unique hit upgrades the anchor to `file:line:col`.
Printer-only, no AST change: the bind-line fallback of step 1 stays
the floor, never wrong.

## Step 3 — real spans, bounded  [LANDED]

One wrapper node `SMark !Int SExpr` (the Int is the raw source
offset) at BLOCK-STATEMENT and CASE-ARM granularity: the parser
stamps each statement's RHS and each arm's body via `getOffset`.
Infer threads the innermost mark (`iHere`) and prefixes every error
it reports with an `@OFF~ ` stamp; `anchorMsg` resolves the stamp to
`file:line:col` and strips it — so a type error points at the
OFFENDING STATEMENT even when the named token appears on many lines,
and case-arm errors land on the arm.  The token locator (step 2)
remains the refinement within a statement and the fallback for
unstamped messages (linearity, preconds, safety).

Costs held to the plan: every traversal either preserves marks
(transformE/EP, Struct's rewriter, Precond, Infer's rebuild), strips
them at its boundary (desugar's `dExpr` — Core stays markless), or
looks through them via `unmark` where a pass pattern-matches on
statement SHAPE (autodrop, linearity, Safety's measure descent).
`stripPosTops` (step 0) erases marks before hashing in BOTH hashers —
Modules.hs and Sol/Mod.hs — so every pinned hash is unchanged (the
golden sweep's printed pins are the regression test).  Infer's
marker-site machinery (newSite / markerPrefix) stays the model for
holes and operator sites.

Not chosen: a span field in every constructor.  Best precision, but
it touches every pattern match in every pass at once — statement
granularity via the wrapper reaches most of the value for a fraction
of the churn, and can widen later if it earns it.

## The LSP tie-in

The `Name -> (file, line)` anchor map plus `fpr typecheck`-style
check-only runs is exactly what an LSP diagnostics provider consumes
(the NOTES.txt cache idea); step 1 is deliberately its first day.
