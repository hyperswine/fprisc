# Native instruction regression contract

Kind: implementation and consumer migration record. This increment follows
`50dbc3d`; emitted code and its runtime ABI are unchanged.

`tools/native-insns-ratchet.py` replaces the shared-RISC `wcet-ratchet.sh`
consumer. QOS's system gate now uses the versioned `native-insns-v1` metric
and a separate runtime-call-site ceiling. The old script is removed.
The generator's legacy annotations remain only for the rollback and its
existing tests until the remaining generator is retired.

## What the gate establishes

For the root emission and every file in its mandatory `.units` manifest:

- The compiler selected typed code throughout, with the requested target.
- Every generated function symbol has exactly one typed header and a matching,
  finite native report. Missing, duplicate, malformed, wrong-target,
  `UNBOUNDED`, legacy or unreported-function input fails.
- Data-only linked units have no instruction obligation; the root must
  contain functions. Unit paths are read as whole lines, including spaces.
- The largest **per-function** segment count is at most the reviewed ceiling.
- The number of static runtime call sites in any one function is at most a
  separately reviewed ceiling. The total across all reports is also shown.

Compilation forces `mixed` and strict `all`; an inherited rollback request
cannot turn this gate into a legacy measurement. Saved-assembly auditing is
also supported. JSON results identify the compiler and hash every audited
file. A failed audit replaces an existing success result with failure.

The input reports and manifest are trusted compiler output. This validates
their coverage and values; it is not a machine-code verifier or a signed
attestation of source/assembly correspondence.

## What these counts do not establish

`Codegen.Bounds` analyzes each selected function's CFG after allocation and
frame expansion. RISC-V pseudos use a conservative unrelaxed instruction
maximum. This is distinct from the old pre-translation shared-RISC count,
and the old ceiling cannot be relabelled as native instructions.

The rows do not bound time inside C/HAL calls. `ccalls` counts static call
sites, including guarded slow paths; it is neither their dynamic execution
count nor their duration. JSON explicitly records `runtime_time_bound` as
`unprovided` and `elapsed_time_certificate` as false.

The gate also does not compose calls and returns across functions. A
callee's exit tail can join the caller's continuation after the last
entry tick; repeated returns can chain. Taking the maximum of individual
rows is not a proven global maximum between scheduler events. JSON marks
`call_return_composition` as `unprovided`. Hardware timing, runtime bounds
and interprocedural composition remain necessary before deriving a hard
latency certificate from fuel.

## QOS system baseline

Fresh strict RV64 compilation, using QOS's home and foreign declarations:

| Measure | Recorded value |
|---|---:|
| Assembly files, root plus linked closure | 27 |
| Native functions | 1,669 |
| Maximum per-function segment | 312 target instructions |
| Maximum per-function exit tail | 256 target instructions |
| Maximum runtime call sites per function | 67 |
| Total static runtime call sites | 7,763 |

QOS's check-all leg uses the exact independent ceilings **312** and **67**.
The worst segment is `dispatch@cdee34460c2ad81a`; its count is not the
program's worst-case elapsed time. The gate covers every emitted function,
including functions the eventual linker might discard, so it is conservative
with respect to linked reachability.

[Compilation gate output](evidence/2026-10-23-native-metric/system-compile.log)
and [complete audit data](evidence/2026-10-23-native-metric/system-compile.json)
record the source/compiler context and per-file hashes. The corresponding
current QOS reference is `docs/2026-10-23-NATIVE-INSTRUCTION-ADMISSION.md`.
The generated help module retains its historical text and identity.

## Validation

`tests/check_native_insns_ratchet.py` tests valid closure and data-only
coverage, paths with spaces, target aliases, generated symbols, 24 refusal
controls, both independent numeric ceilings, stale-success replacement and
real strict root/prelude emission even with an inherited legacy request.
It is part of Base. The full local sweep passes **116 jobs in 365 seconds**
on four workers ([log](evidence/2026-10-23-native-metric/base-final.log)).
The focused consumer log is retained
[here](evidence/2026-10-23-native-metric/consumer-final.log).

QOS's sweep-verdict tests inject numeric regression, missing tool, timeout
and crash statuses into the actual native gate leg. A printed success line
cannot mask a failed command. QOS's graphics-independent compile checks
also pass against this toolchain. These focused results are not a complete
QOS check-all run or a physical/hosted CI result.

```sh
python3 tools/native-insns-ratchet.py program.fpr 312 rv64 \
  --runtime-call-sites-ceiling 67 --json-output /tmp/native-bounds.json
python3 tools/native-insns-ratchet.py program.s 312 rv64 --assembly \
  --runtime-call-sites-ceiling 67
python3 tests/check_native_insns_ratchet.py
```
