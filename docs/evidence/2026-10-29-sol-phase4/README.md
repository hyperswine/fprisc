# Phase 4 core library evidence

Phase 4 is locally verified on macOS arm64; Phase 5 remains open.

- `validation-core.json`: current executable/source identity, exact check commands,
  settings, host, raw outputs and outcomes. Base selection covers the registered
  Sol jobs, not full Base or hosted CI.
- `stream-memory.json`: SHA-256, CSV record validation/counting and byte line filter
  at 100 MiB and 1 GiB with fixed 64 KiB buffers. SHA outputs are independently
  checked against hashlib. No result-retaining callback is used. The 32 MiB growth
  gates pass (digest 0 MiB, CSV 5 MiB, filter 1 MiB).
- `digest-memory.json`: earlier digest-only implementation snapshot, before format
  additions. Its hashes identify that earlier state; it is not current-binary proof.

All measurements are local macOS arm64, development build, JIT/GPU off, warmed
compile cache and fresh processes. Samples separate idle, throughput and peak
RSS. A few focused checks overlapped the first small-input samples; no controlled
cross-version speedup is claimed. Linux/hosted CI/install workflows remain open.

See [the API/delivery record](../../2026-10-29-SOL-LIBRARIES-PHASE4.md).

- `validation-complete-macos.json`: 19 passing commands including eleven registered
  Sol Base jobs, HTTP/TLS, interpreter reruns and native observation fixtures.
- `validation-http-followup.json`: route replacement correction, 61 HTTP checks
  in default/interpreter modes and 125 library checks; records the updated helper
  identity separately from the earlier broad run.
- `http-memory.json`: streamed HTTP download at 100 MiB/1 GiB, independent byte
  digests, system RSS and sampled parent/worker family RSS. The 32 MiB growth gate
  passes. Timing is observational; Linux VM preparation overlapped this work.

The HTTP harness used existing public loopback TLS fixtures and an empty PATH.
No public service or live credentials were required.
