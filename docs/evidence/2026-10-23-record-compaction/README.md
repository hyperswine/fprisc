# Record compaction evidence

Base commit: `bcd523d`. `metadata.json` identifies the exact codegen-80 compiler,
pre-change compiler and final source hashes. No changes are pushed.

- `base.log` / `.exit`: final compiler and strengthened oracle, all 118 Base
  jobs, 445 seconds, four workers, exit 0. Existing RV32 SoftFloat libraries
  were explicitly provided from the sibling checkout's ignored build tree.
- `qos-native.log` / `.json` / `.exit`: actual QOS system gate, strict complete
  RV64 closure, unchanged independent ceilings 312 instructions / 67 runtime
  call sites per function. It is not a time or call-return composition bound.
- `paired-final.*`: 31 pairs each for all-field discard and broader records.
- `paired-last.*`: 31 pairs for a sparse last-field predicate; 90% discarded.
  All samples, compiler/binary identities, build coverage and paired bootstrap
  summaries are retained. These are native AArch64 timings on this host.
- `first-attempt/`: discarded codegen-79 hoist with individual column ticks,
  its measurement and exact source patch (gzip; hash matches the JSON).
  It regressed broader records, so it was revised before this milestone.
- `kernels.log` / `.exit`: initial independent kernel run, before stronger raw
  payloads; pass. The final, strengthened full kernel run is in `base.log`.
- `oracle-development.log` / `.exit`: an expected development failure after
  distinguishing all wide-field payloads exposed the old oracle's physical
  field-index assumption. Sorted record names put z299 at column 222, as
  documented in the vector layout contract. The corrected oracle is checked
  by the final Base run; this failed development log is not acceptance evidence.
- `frame-followup.txt`: remaining frame fallback source audit and proposed
  sized-reservation work, explicitly unimplemented by this change.

Reproduction:

```sh
python3 tests/check_typed_ir_kernels.py --require-execution
FPR_SOFTFLOAT_ROOT=/Users/jasonqin/Documents/GitHub/fprisc/build/tangnano20k-softfloat python3 tests/check_base.py -j 4 --times
python3 tools/bench-typed-ir-m3.py --against /path/to/compiler-from-bcd523d --variants baseline,typed-ir --workloads recordcompact,recordcompactlast,records --runs 31 --output /tmp/new-compaction-measurement
```

No physical board, hosted CI, native x64 or real dynamic QOS loader result is
claimed. X64 semantic oracles run under Rosetta and RISC-V under QEMU. The
hoist is bounded to a proven prefix of at most 16 columns; the dynamic tail
and the larger migration goal remain open.
