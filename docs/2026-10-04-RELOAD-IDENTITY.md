# Reload event identity checks

Date: 2026-10-04. Follows the committed
[runtime interface gate](2026-10-04-RUNTIME-INTERFACES.md).

## Contract

`Mod.hashAt table : String` returns the attached image's root source identity,
with the empty string for an invalid index. It uses the schema-1 root identity
already emitted by the compiler; no module-table or native ABI change is needed.

`Reload.preflightVersionAt baseline from to` rejects missing/invalid baselines,
empty identities and a `from` different from the baseline's actual identity.
`Reload.attachVersionAt baseline from to attach bytes` runs that preflight,
requires exactly one new table on successful attachment, then checks the new
root identity against `to` before the checked type/contract/ABI gate. A wrong
candidate identity detaches the new registry entry. Saved old functions and the
baseline table stay usable. The sole registry-writer requirement remains.

QOS `MVUReload.loadVersion me fs archive baseline from to` preflights before
retrieving the archive and checks again at adoption. Archive addressing remains
platform policy: an archive ID is not a source hash, and the API keeps the two
arguments separate. Existing `load`/`attachAt` remain available for legacy
callers; supported event adapters should use the version-aware functions.

The real MVU test now puts compiler root hashes into `EReload.from`/`to`, and
keeps the human version label separate. Its test-only producer catalog obtains
identities by temporary attachment/detachment; that is a fixture mechanism,
not the production publication design. It retains image memory just like all
current attachment paths.

## Trust and remaining boundaries

These are FP-RISC's existing FNV-1a-64 identities of positionless, dependency-
pinned source ASTs. They identify trusted compiler output; they are not SHA-256
archive digests, signatures, or collision-resistant authentication. QOS still
verifies IMAGE and RELOC/IMPORT SHA-256 claims before placement. Neither set of
checks authenticates an arbitrary hostile image or publisher.

The identity check does not enforce semantic version strings, logical module
names, provenance, publication authorization or major-version restart policy.
Those belong to the future publisher/live-module binding policy. It also does
not reclaim refused images or make registry publication concurrent/transactional.

Next: POSIX image attachment and a production host clock, then store watching,
publication/restart, typed live-module declarations, and QOS journal/replay.
The old QOS loader's global-newest baseline limitation remains unchanged.

## Verification

- Base module-table test: stale/empty identities refuse without invoking the
  attachment callback; a wrong candidate detaches; registry count stays stable;
  a matching identity proceeds to the interface gate; invalid lookup returns
  the documented empty string.
- Shared MVU runner test: all six runner/observer/legacy/LiveApp/baseline variants
  passed on one and repeated four-hart runs.
- QOS real plugin tests passed on one/four harts: stale source refuses before
  retrieval (the deliberately missing archive is never reached), a misaddressed
  image refuses by candidate identity and rolls back, matching v1-to-v2 hashes
  adopt between events, all interface refusal legs remain green, model/render
  retain current behavior and old functions stay callable. Stable checked
  contracts and private specialization patches also passed.

`python3 tests/check_base.py` passed the complete Base suite, including the
identity-aware module-table test and checked commit/vector/specialization
regressions. No full QOS check-all sweep, POSIX attachment or native RV64 plugin
reload is claimed.
