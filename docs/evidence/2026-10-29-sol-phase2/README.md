# Sol Phase 2 streaming memory evidence

Local macOS arm64 evidence for the
[Phase 2 delivery](../../2026-10-29-SOL-IO-PHASE2.md).
`stream-memory.json` contains raw measurements, exact scripts/settings, source
hashes and the executable identity. Inputs and copied outputs are generated in
temporary directories and removed; the report is the retained artifact.

```sh
make fpr
python3 tools/sol-io-benchmark.py --runs 2 \
  --output docs/evidence/2026-10-29-sol-phase2/stream-memory.json
```

The measurement tool needs OS resource-counter access. Both 100 MiB-to-1 GiB
growth gates pass under the unchanged 32 MiB allowance. These are per-process
peak RSS measurements with a warm compile cache and 64 KiB buffers; they include
the compiler/VM and its normal nursery, not just payload buffers. Linux/CI
execution is not represented by this artifact.
