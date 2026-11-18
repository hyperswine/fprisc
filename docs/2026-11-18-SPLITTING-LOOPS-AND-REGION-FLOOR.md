# Splitting loops build front to back; a floor before a region copies (18 November)

Item 3 of the application-overhead list (docs/2026-11-18-OWNED-MAP-FOLDS.md
names the list): the text workloads' remaining time after the owned map folds
was in producing their pieces, `String.lines`, `String.split` and
`String.words`, and in the loop region that collects each iteration's garbage.

## Guard clauses defeated the list builder (`Core/Typed/Trmc.hs`)

std/string gathers pieces in an accumulator and ends every exit with
`rev acc Nil`, the shape the typed TRMC pass turns into a builder that writes
the list front to back (one cell per piece, no reverse pass). The profile
still showed `rev`: the allocation sites of the 18 November wordfreq had 2M
cells from `rev` beside 2M from `wordsGo`. `wordsGo`, `linesGo` and
`splitCharGo` were compiled as plain loop regions, while `chrs` in the same
module was a builder.

The difference was the clause form. Small copies of `wordsGo` showed it: the
same body written with `if`/`else` became a builder, written as guard clauses
it did not, even a two-clause `f n acc | n <= 0 = rev acc Nil` /
`f n acc = f (n - 1) (n :: acc)`. A function of several clauses is a
`MatchTail (FunctionMatch _)` over the parameters, and every clause rebinds
each parameter under its own name. TRMC's check saw the accumulator as an
argument of that match (and only aliases of it in the clauses) and declined.

`canonical` already dissolved a single unguarded clause into its body. It now
also reads clauses that only bind the parameters (names or wildcards) and
carry at most one Bool guard each as an if-chain: guards still run in clause
order, and the first clause without a guard ends the chain (anything after it,
and the fallback, was unreachable). The rewritten form reaches generated code
only when TRMC then transforms the function; a function it declines keeps its
original body. tests/TypedTrmc.hs has the two-clause case; it fails without
the change. `codegenRev` 257.

## A byte floor before a loop region copies (`runtime/runtime.c`)

With the builders in place, csv's largest cost was `g_region_cycle`: 28% of
the main thread's samples, in two sizing walks and a copy of its loop state
(the owned map's thousand keys and tuples, about 70 KB) at each cycle. The
region copies once the arena has grown by `FPR_REGION_GROWTH` (2) times what
the last copy produced, so a small state was walked and copied every 140 KB of
allocation. A growth factor of 32 took csv from 0.127 to 0.105 s with no
change in memory, but as a default it would let a 100 MB state hold 3.2 GB of
garbage.

`FPR_REGION_FLOOR` (1 MB) is the bound instead: a loop region with a live
state does not copy until it has allocated at least the floor since its last
copy. The copy work is then at most live/FLOOR of the allocation, an open
region holds at most a floor more garbage, and a state larger than half the
floor keeps the 2x rule. A receive loop still cycles every slab (its cycle
also releases the messages its turns took), and a state with nothing to copy
cycles as before.

`fpr_mutmap_note` now tests for an Int or static before it looks up the hart
(a thread-local read on macOS): 13 samples of wordfreq's profile.

## Results

Apple M4, standard inputs, best of five; outputs identical to `expected/`.

| workload | after owned map folds | now | C |
|---|---|---|---|
| csv | 0.128 s, 133 MB | 0.110 s, 98 MB | 0.023 s |
| wordfreq | 0.136 s, 240 MB | 0.126 s, 180 MB | 0.044 s |
| wordfreq (`_mutmap` variant) | 0.113 s, 231 MB | 0.104 s, 170 MB | |

RSS ceilings lowered: csv 150 MB, wordfreq 270 MB, wordfreq-mutmap 255 MB.

format, records, treemap and sim are unchanged.

## What item 3 did not do, and why

- **Fusing the word list into the fold.** wordfreq also takes the list's
  length after the fold, so `String.words` has two consumers; fusing them
  would need a rewrite for that one shape. `String.foldWords` already exists
  for programs that consume the words once (`wordfreq_stream`, 0.084 s).
- **Substring slices.** csv's fields and wordfreq's words are a few bytes: a
  slice cell would be about the size of the copy it replaces. The time in
  `g_substr` is the allocation, not the byte copy.
- **A native `MutMap.alter`.** The rewritten `Map.update` costs 0.02 s more
  than `insertWith` on wordfreq: two probe primitives each hand back a pair.
  One primitive would need the runtime to build and read `Option` values,
  whose constructor tags it does not know, and a second implementation in the
  Sol VM. Left as a follow-up.

The string hash now leads wordfreq's profile; most of it is the cache miss on
words built long before the fold reads them, the cost of the materialised
list above.
