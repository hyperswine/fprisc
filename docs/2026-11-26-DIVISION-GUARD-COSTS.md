# Integer division: nonzero divisors and hot-loop guard costs

Kind: **design direction**, not implemented. Written 2026-11-26 against
`7ed74a6a`. Narrows the integer `/` case of the preconditions question in
[v1.0 semantics §7](2026-11-26-V1-SEMANTICS.md#7-failure).

## Rule

Integer `x / y` requires `y != 0`. The operator supplies the precondition;
callers do not have to write a signature or a check just to divide.

- **Proved nonzero:** no runtime zero check is needed at the division.
- **Not proved, ordinary code:** compile with runtime enforcement. On zero,
  take the defined division fault. One check is enough: if the division
  implementation already enforces the condition, do not add a duplicate.
- **Not proved, check remains inside a hot loop:** give an efficiency
  diagnostic and refuse the build by default. An explicit option, provisionally
  `--allow-inefficient-hot-loop`, allows the guarded build. The option accepts
  the recurring cost; it never disables the check or changes the failure rule.

Start with integer `/` only. Floating-point division, other operators,
and whether a visibly false constant such as `1 / 0` should be rejected
at compile time remain separate decisions.

## Make the cost visible

Apply the hot-loop gate to the runtime check that actually remains after
proof and legal loop transformations, not merely to a division that appears
syntactically inside a loop. A check proven outside the loop, or legally
moved to run once, should not trigger the gate. Do not move a fault ahead of
observable effects or introduce one on a zero-trip path.

A diagnostic should point to the division and loop, state the unproved
condition, and say where the runtime check will execute. For example:

> Integer division in this hot loop still checks `y != 0` on each
> execution of the division. Establish that `y` is nonzero before the loop,
> or pass `--allow-inefficient-hot-loop` to keep the check.

Use the same location and reason in cost remarks for builds that opt in.
Distinguish the divisor check from the cost of the divide itself, including
any applicable exact-`Int` fallback. Where lowering supplies the check
inside a primitive, report that rather than inventing a separate branch or
a cycle count. If the iteration count or cost is unknown, say so.

Choose and document a reproducible definition of “hot” before enabling the
gate. Start with an explicit or compiler-classified loop, not an implicit
profile from somebody else's machine. The threshold or marking syntax, the
flag's final spelling, and whether a later override can be scoped to one
site are open.

## Acceptance cases

1. An opaque divisor outside a hot loop compiles without annotations or
   override, divides correctly when nonzero, and faults on zero.
2. A divisor proved nonzero in a hot loop compiles without an override and
   has no residual zero check at the division.
3. A varying, unproved divisor in a hot loop fails the default build with a
   source-located diagnostic. With the override it compiles, still faults
   on zero, and reports the retained check as a recurring cost.
4. A loop-invariant divisor checked once does not incur a repeated check.
   A zero-trip loop does not begin trapping solely because a check moved.

Baseline: on macOS arm64, both native Base and Sol already accepted integer
division with an unproved divisor and with literal zero, and faulted at
runtime for zero. The current builtin division path supplies that fault.
The hot-loop gate and its diagnostics are proposed, not evidence about
the current compiler.
