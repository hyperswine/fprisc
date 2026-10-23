# Combined native frame sweep

`base.log` / `.exit`: codegen 86, 123 Base jobs, 629 seconds, four workers,
exit 0. This includes both new A64/x64 frame regressions, the RISC-V direct
and production-runtime frame probes, fixed-stack controls, ARC/raw byte
linkage, numeric/ownership/kernel/runtime and existing behavioral checks.
The existing RV32 SoftFloat archive was explicitly supplied from the sibling
checkout's ignored build tree. No sibling tracked files were changed.

`metadata.json` identifies the three selectors and shared runtime/oracle
sources. The earlier [RISC-V increment](../2026-10-23-sized-frames/README.md)
retains its 121-job sweep, physical Tang Nano stack gates, QOS loader/ABI
acceptance, and paired guest-instruction measurements.

Native A64 and Rosetta cases ran here. The real Linux x64 actor-runtime
branch is registered for matching CI hosts and is explicitly skipped locally.
No hosted CI or P4 acceptance is claimed by this sweep.

Codegen 87 is a separate subsequent increment requiring complete native
coverage whenever a native mode is selected. Its acceptance evidence lives
in `../2026-10-23-native-required/`; this codegen-86 sweep does not claim to
have validated that later default change. Main and remotes are unchanged.
