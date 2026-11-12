# Structural refinements for sorted lists

Proposal, 13 November 2026. FP-RISC already checks scalar preconditions, including calls through higher-order functions, and accepts structural termination measures. The proposed extension makes checked result facts about recursive data available to callers across module boundaries. [Application contracts](2026-10-17-CONTRACTED-APPLICATION-CORES.md)

## First proof

Start with nondecreasing lists of integers. Define Sorted and AllAtLeast as pure predicates by structural recursion. Sorted (h :: t) requires Sorted t and AllAtLeast h t. Both predicates hold on the empty list. To insert x, place it before h when x <= h; otherwise keep h and recursively insert into t.

The result contract preserves Sorted and every input lower bound lo for which lo <= x. In the recursive branch, instantiate lo with h. The branch condition and the input contract supply both premises, so the returned tail can follow h. Pattern matching exposes constructor facts; a strictly smaller recursive argument justifies use of the induction hypothesis. Treat lo as an erased proof parameter. The initial order is built-in integer comparison. General comparators require explicit order laws.

## Acceptance

Compile ordinary recursive insertion, including duplicate keys, and reject a branch that prepends a larger key. Reject an unchecked cast from external list data. Validate untrusted input once, preserve the checked fact through calls, and inspect generated code for unnecessary proof traversals. A second milestone proves preservation of element multiplicities: returning the empty list passes sortedness alone but loses the input.

A Terra II tactical shortlist could use a bounded, deterministically sorted insertion helper. Dungeon's breadth-first frontier instead needs a FIFO whose queued cells remain in bounds. A work budget per search step is a separate resource obligation. [Game tasks](2026-11-12-GAME-MVU.md)
