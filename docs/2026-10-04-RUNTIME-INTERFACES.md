# Checked runtime module interfaces

Date: 2026-10-04. Implements the runtime gate following
[checked commit interfaces](2026-10-04-CHECKED-INTERFACES.md) and the
[MVU runner](2026-10-04-LIVERELOAD-RUNNER.md).

## Image contract

The normal compiler checker runs before emitting an image. Module tables now
have a three-word header (magic `0x4650524d`, schema `1`, root module hash),
followed by zero-terminated four-word rows: module hash, export name, function
descriptor and checked interface string. `codegenRev` is 36; native process ABI
is 3. Rebuild hosts and images together. Legacy/unknown table schemas refuse
attachment before registry publication; QOS's existing ABI gate refuses old
native process images before allocation.

Each supported callable export carries its canonical inferred type, preserved
nominal unit identities, complete written signature/contracts, actual runtime
arity, codegen revision, target/hard-float configuration, prelude identity and
foreign declaration identity. Canonical types retain polymorphic variable
correlations and record rows. Source parameter names in written contracts are
compared conservatively; this is equality, not logical implication or subtyping.
Unsafe-marked exports (including scoped blanket markers), declared result-size
assumptions, and builds using an external target manifest have empty stamps and
refuse reload. Target-manifest certificates are not implemented here.

`Mod.compatAt` compares all callable exports belonging to the baseline root
module against the candidate root. Missing exports, arity drift, empty stamps
and different type/contract/ABI stamps refuse. Extra exports are allowed. An
empty root export set refuses rather than passing vacuously. Non-callable
constant exports are outside this reload surface.

`Mod.findAt` also resolves only root exports. Dependencies cannot impersonate a
missing root export with the same name. Private dependency closures can change;
their nominal identities still occur in exposed types. Compiler-generated
specialization clones are private, rather than accidental public exports.
Global `Mod.find` and hash-qualified lookup retain their existing behavior.

## Adoption and limits

`std/reload.attachAt` continues to require the sole registry writer. It gates
against the env's explicit baseline and removes the candidate table on refusal.
Stored old function values remain callable. Image memory remains mapped even
when its registry entry is removed; this does not solve reclamation or concurrent
transactional publication. The legacy QOS loader still compares against the
newest global table; use the scoped MVU adapter for independent live modules.

These are compiler-generated interface claims for trusted images, not signed
proofs. A malicious image can forge them. Written bounds are checked by the
existing cost analysis, whose trusted primitive assumptions still apply; stamps
do not establish target-time WCET. Module headers carry root identity; event matching against `from`/`to` is now
implemented in [RELOAD-IDENTITY](2026-10-04-RELOAD-IDENTITY.md). Production
publication/watch policy and publisher authentication remain outside this gate.

## Regression coverage

- Base `modinterface` uses explicit test tables to check legacy/unknown-schema
  refusal without publication, root/dependency name collisions, missing exports,
  changed/empty stamps, empty baselines and registry rollback.
- QOS real plugin tests cover same-arity inferred type, precondition and work
  changes; unsafe opacity; existing arity refusal; unchanged env/model/render
  after refusal; old saved functions; unchanged checked preconditions/work
  bounds; and behavior changes involving private specialization helpers.
- Notes declares `editLine : String -> String` in both versions. Its old v1
  interpolation inferred a generic argument, which correctly fails the new gate
  against string-only v2 without this explicit intended interface.

See the verification results below for executed coverage. POSIX attachment and
a production clock are now implemented in [POSIX-RELOAD](2026-10-04-POSIX-RELOAD.md).
Watchers/publication/restart, typed env reconstruction,
new-path QOS journal/replay, native RV64 reload, browser/GL reload and long-run
memory/performance measurements remain open.

## Executed verification

- `make -s fpr`: rebuilt successfully.
- `python3 tests/check_base.py`: complete Base suite passed, including checked
  commit interfaces, MVU runner ordering, specialization/vector/x64 suites and
  the new module-table refusal/rollback test.
- QOS `python3 tools/mvu-reload-check.py`: real plugin reload/refusal and stable
  checked-contract/specialization patches passed on one and four harts.
- QOS `./qos.py run tests/pathnotes.fpr`: preserved Notes state and adopted v2;
  arity-changed v3 refused.
- QOS `python3 tools/native-integrity-check.py`: ABI/integrity refusal before
  allocation and valid vector process execution passed on one/two harts with
  both virtio variants; production placement has no test allocation counter.
- QOS focused smoke: MVU engine and `./qos.py test liveview` multi-client
  browser driver each passed (1/1 each).

No complete QOS check-all sweep or native RV64 plugin reload was run.
