# `fpr commit` re-pinning and prior versions (2026-11-25)

QOS could not bump its fprisc pin because `fpr commit` refused most of the
modules in its `release.toml`. Three of the refusals were tooling problems, not
code problems. This note records what changed in `compiler/Commit.hs` and how to
use the new `fpr pin` command.

## What was wrong

1. **The prior version was re-checked with today's safe/unsafe lint.** To
   classify a new version as a patch or a major, `fpr commit` derives the prior
   version's interface. It did that with the full checker, safety lint included.
   The lint tightens between releases (an `unsafe` marker the analysis now proves
   unnecessary, a recursion that must now be declared), and a committed blob is
   immutable, so no edit could ever fix it. QOS worked around this by adding each
   prior blob's hash to `core/trusted-modules.txt`. With `std/actor#2de24bf2`
   pinned by 88 files, that did not scale.
2. **A prior blob from before the closure rule could not reload.** A blob with an
   unpinned `use` resolves that use to today's file, so it no longer hashes to its
   own name, and the commit died with `prior version blob hash mismatch`.
3. **Refusals did not say what to do.** A module that failed the checker exited 1
   with only the checker's diagnostics. An unpinned-use refusal printed the pins
   to paste, one module at a time, but not in dependency order.

## What changed

- The prior version's interface comes from `Compile.recordedInterface`: the same
  normal checker with `--no-safety`. Types, arity and written contracts are still
  derived by the normal checker; only the lint is skipped. This admits nothing
  into a build. Every build still runs the full checker over whatever it links,
  so the safe/unsafe line, WCET and fuel are unchanged.
- A prior version that cannot load, does not reproduce its hash, or no longer
  type-checks is reported with the reason (for example its unpinned uses). The
  commit is then refused, because compatibility cannot be shown. `--major` mints
  the next major version past it.
- When the only incompatibilities are exports that mention the module's own
  nominal types (`Type@<version hash>`, whose runtime tid follows the unit hash),
  the refusal says so in one line instead of listing every export.
- A module that fails the checker now ends with
  `commit refused: <file> does not pass the checker (diagnostics above); nothing was written`.
- An unpinned-use refusal ends with `fix: fpr pin <file> --deps`.

## `fpr pin`

```
fpr pin <module.fpr>                      pin every unpinned use in the file
fpr pin <module.fpr> --deps               ...and first in every scratch module of
                                          its closure under the current directory,
                                          dependencies first
fpr pin <module.fpr> --update             also re-pin pinned uses whose scratch
                                          source has moved on
fpr pin <module.fpr> --update=std/actor   re-pin only these specs, plus any pin
                                          whose module this run rewrote (cascade)
fpr pin ... --dry-run                     print the edits, write nothing
```

Only the string literal after `use` changes, so comments and layout survive. The
hash is the module's own Merkle pin hash, so pinning an unpinned use never changes
the pinning module's hash. A rewritten file that no longer loads is restored and
reported. The command never writes under `.fpr/` or outside the current directory,
so toolchain files such as fprisc's `std/` are never edited. It commits nothing:
it prints the files in the order to commit them.

`--update` is the supported migration for an old pin such as
`std/actor#2de24bf2`. Until it is run, an old pin keeps resolving from
`.fpr/store`, which is still correct.

## Coverage

`tests/sol-checks/commit-pin.sol` covers the unpinned refusal and its fix, `pin
--deps` keeping comments, plain `pin` leaving a moved pinned dependency alone,
`--update=<spec>` re-pinning it, a patch over a prior blob the lint flags, and an
unreproducible prior refused without `--major` and minted past with it.
