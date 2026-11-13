# Replaced-script cleanup (2026-11-13)

This earlier cleanup record is superseded by the [Sol-only main cutover](2026-11-13-SOL-ONLY.md). Its retained-script list describes the earlier checkpoint.

The final pre-cleanup source is preserved in the GitHub release
[`legacy-scripts-final-2026-11-13`](https://github.com/hyperswine/fprisc/releases/tag/legacy-scripts-final-2026-11-13), including a source archive and checksums.
This is a source checkpoint, not a new binary toolchain version.

Cleanup applies across build, packaging, hardware, tests and tools, but only
where the replacement covers the old behavior. Run the commands below from
the repository root unless indicated. Use `SOL` to select a compatible runtime
in scripts that launch child tools; direct examples use `sol`.

| Removed entry | Replacement |
| --- | --- |
| `deploy/aws-pos1/build.sh` | `sol deploy/aws-pos1/build.sol` |
| `machine/tangnano20k/build-softfloat.sh` | `sol machine/tangnano20k/build-softfloat.sol` |
| `machine/tangnano20k/build.sh` | `sol machine/tangnano20k/build.sol` |

Historical reports and evidence keep the command names used when they were
recorded. Their old paths are available in the checkpoint release.

## Retained functionality

- `machine/esp-idf/build.sh` still resolves caller-relative paths and sources the ESP-IDF toolchain environment. Its Sol worker does not replace that setup. ESP-IDF run, console and environment tools also remain.
- Python linked-image, compressed-instruction and static-arena reference implementations remain independent differential test oracles and fault-injection helpers. The Sol production build does not depend on them; their test role has not been replaced.
- Hardware transport, board qualification, test harnesses, benchmarks and deployment utilities without equivalent behavior remain.

Validation: the changed Tang Nano callers built and ran the RV32 and RV64
argument suites, including limits, malformed replies and unsupported operations.
The Sol build and artifact modules no longer declare obsolete unsafe markers
that prevented direct invocation with the released bootstrap runtime.
