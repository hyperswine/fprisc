# Phase 3 local validation

`validation.json` contains fresh final-binary checks, source/binary SHA-256 values,
exact commands, settings, host and raw outputs. All 16 commands passed.

The Base selector ran seven registered Sol jobs, not the entire Base suite.
The receipt test uses actual deferred producers and checks the aggregate result
budget/failure fence/cleanup. Pipeline tests include 16 MiB binary flow, both
channels beyond pipe capacity, stage failures, publication, overflow, Ctrl-C,
timeout/cancel descendants, linear ownership and repeated descriptor use.

This record is for the uncommitted Phases 2-3 tree based on `27a4cdc`. Historical
Phase 2 memory evidence stays in its own folder with its original source hashes.
Linux, hosted CI and hardware are unverified; APFS invalid-byte names and a
second local filesystem for native EXDEV were unavailable. See the
[Phase 3 API and decision](../../2026-10-29-SOL-PROCESS-PHASE3.md).
