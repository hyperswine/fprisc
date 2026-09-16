# FP-RISC and QOS

ONE language, ONE frontend, FOUR execution profiles, and a provable std.

## One entry point

`./qos.py` is the pipeline layer over the tree -- the Makefiles stay
the mechanism (each component's build knowledge), qos.py is the policy
you actually drive it with:

    ./qos.py run tests/dtree.fpr          # compile + host on qosp
    ./qos.py run tests/fmath.fpr --on virt   # ... bare-metal QEMU
    ./qos.py run sol/examples/todo.sol    # .sol -> the sol profile
    ./qos.py serve tests/mvuweb.fpr --port 8080   # LiveView app
    ./qos.py native --smoke               # kernel + disk + boot check
    ./qos.py test                         # the fast smoke set (~30s)
    ./qos.py test --all                   # the full sweep (check-all.sh)

Everything delegates to make for staleness, so a fresh tree costs one
compile and an up-to-date one costs nothing.

## Where it is going

`SEMANTICS.md` is the contract 2.0 commits to -- the language and the
OS, one clause per rule, a test slot on each; `docs/V2.md` is the plan
around it: the bounds register, the std inventory, hardware, the order.
Dot points for now, systematic later.  Two companion files carry what
outgrew dot points: `docs/V2-AUDIT.md` (every reported issue
re-checked against the tree -- status, evidence, disposition) and
`docs/STD-PLAN.md` (the library workstream in full: the tier model,
the missing surface, the promotion table, the gate).

## Install

One toolchain, one command, macOS and Linux (docs/INSTALL.md):

    brew tap hyperswine/tap && brew install qos-fpr
    ./qos.py install --prefix ~/.local          # the same layout, from a checkout

    qos new myapp && qos run myapp/app.fpr      # a project of your own
    sol script.sol                              # the sol profile (= fpr sol)
    fpr compile app.fpr app.s                   # the prelude is found beside the binary

Nothing a run does writes into the installed tree: the `.qa`, the
intermediates, the host's disk and the app's kv state land in `.qos/`
under the directory you invoke from, packs in `dist/` beside it.  A
project outside the tree reaches the library with `use "std/mvu"` --
resolved under the toolchain's home after the file-relative path
misses.  `qos/tests-host/install-check.sh` installs to a scratch prefix
and proves all of that from an empty directory.

## Versions and releases

Three layers, each built from the one below (docs/VERSIONING.md):
`fpr commit` mints immutable module versions into `fp-risc/.fpr/`
(tracked); `./qos.py lock` writes `fp-risc/fpr.lock`, every
`use "x#hash"` pin in the tree resolved to its committed version;
`./qos.py release X.Y.Z --push` commits the modules named in
`release.toml`, checks the lock, runs the smoke set, packs the release
apps as stamped bundles under `dist/qos-fpr-vX.Y.Z/`, and mints the
annotated tag `vX.Y.Z` -- which `.github/workflows/release.yml` turns
into a GitHub Release with the same bundles rebuilt from the tag.

    ./qos.py lock --check                 # check-all leg: pins resolvable, lock current
    ./qos.py release 0.2.0 --push         # cut + publish v0.2.0

The exact build tools currently installed on the development Mac are recorded
in [docs/TOOLCHAIN.md](docs/TOOLCHAIN.md).

## Layout

    fp-risc/            the language project
      compiler/         the SHARED frontend (parse, infer, modules,
                        structs, contracts) + AOT backends (rv64 IR,
                        X64/A64 lowerings) + Target.hs (the profile
                        model) + StdCheck/StdBridge (the std proof pass)
      compiler/Sol/     the HostedBytecode pipeline (bytecode VM, the
                        hand-rolled native JIT for x86-64 and A64 --
                        no LLVM -- transactional runtime) — ALL Haskell lives
                        under compiler/; compiler/cbits/ holds its C FFI
      sol/              the sol PROFILE'S CONTENT only: lib/ (base, ui,
            matrix, rand, …), examples/, and scripts/ — no source tree,
                        no separate build.  `fpr sol script.sol` is the
                        profile
      std/              the SAFE TIER — standalone.  std.fpr (FP-RISC
                        side), std.sol (sol side), checkdemo.fpr (the
                        proof-pass demo).  sol USES std; std needs no sol.
      core/             the bare tier (prelude.fpr) — unsafe by license
      docs/STYLE.md     source style: builtin-first, abstraction exceptions
      docs/SCRIPTING.md functional and transactional host scripting patterns
      targets/qos.fpr   the Struct QOS-targeted programs link against
                        (thin re-export of Svc/Caps/IoV: re-homing the
                        definition would churn pinned content hashes)

    qos/                the QOS backend — built SEPARATELY
      portable/         qosp: hosts ONE .qa on Unix through qos_hal_t
      native/           (build dir) the kernel: system.fpr AOT'd for
                        RISC-V, loaded by QEMU as -kernel
      appside/          the app-linked C: table-dispatch HAL, link
                        scripts, qos_abi.h

    hal/                the C layer, explicitly a HAL — not an
                        implementation either project may reach around
      core/             portable runtime contract (actors, buddy, vec…)
      virt/             bare-metal machine layer (QEMU virt)
      unix/             raw device layer ONLY (net_raw, evdev, gfx,
                        tty, drm, ctx).  The old co-compiled `posix`
                        target is GONE — hosting on Unix is qos/portable.

## The four profiles (compiler/Target.hs)

| profile        | guarantees discharged by            | runs as                    |
| -------------- | ----------------------------------- | -------------------------- |
| BareMetal      | AOT + static exclusion              | image.elf, hal/virt, no OS |
| QOSNative      | AOT + QOS capabilities/URLs         | .qa process on the kernel  |
| QOSPortable    | AOT + the qos_hal_t table           | .qa hosted by qosp on Unix |
| HostedBytecode | runtime rollback net (transactions) | sol VM + JIT               |

ISA (rv32/rv64/x64/a64/…) is a SEPARATE axis; profiles pick discharge
strategy, Makefiles pair the two.

## std, and the proof pass

std's defining rule: NO operation with unbounded worst-case behavior.
`fprc --stdcheck file.fpr` is the discharge mechanism (StdBridge lowers
the checkable fragment of real parsed .fpr into the StdCheck engine):

* an all-Int signature DECLARES a function safe; `(n : Int | n > 0)`
  contracts feed the interval domain; `post_f : (r : Int | r >= 1)`
  sibling sigs declare postconditions
* termination by certified measure (=> closed-form WCET) or by the
  once-proven foldRange/Fold recursion scheme
* unproven obligations get DYNAMIC checks at exactly those sites
* core_* names are ALWAYS opaque unsafe externs (cost ω(name)) even
  when defined — unsafety is infectious upward, and the WCET
  equations show exactly where ω enters and how it composes
