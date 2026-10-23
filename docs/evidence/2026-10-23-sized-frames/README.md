# Sized frame evidence

Base checkout commit: `042a6d8`. The source changes are local and unpushed.
`metadata.json` identifies the final sources, compiler and measured binaries.

- `rv-oracles.log` / `.exit`: independent large-frame ABI probes, RV32/RV64,
  self loops on/off, hostile argument-cell and register clobbers; exit 0.
  The complete final rerun is also included in the Base sweep.
- `actor-runtime-linked.log` / `.exit`: production actor runtime, both widths,
  512 live values, 80 nested frames, 32 KiB first stack and forced yields.
- `fixed-stack-qemu.*`: fitting frames and pre-frame exhaustion with the real
  RV32 fixed 64 KiB Base runtime, exit 0 for the overall test.
- `fixed-stack-physical.*`: the same two programs on the configured 48 MHz
  Tang Nano after its UART diagnostic. RAM-only image hashes and successful
  exit/DONE markers are retained. The negative program's exit 1 and the
  upload tool's refusal traceback are expected and explicitly checked by
  the enclosing test; they are not a failed validation.
- `rv-startup.*`: corrected mixed-unit fixture and native RVV VLEN 128/256/512
  execution, RV32/RV64, exit 0.
- `paired-final.log` / `.json` / `.exit`: final compiler, all 31 paired
  deterministic guest instruction samples per width, compiler/ELF hashes.
  `paired-g84.*` supersedes it after the raw-byte linkage fix and includes
  the final compiler identity. Earlier samples are retained explicitly.
- `qos-native-g84.*`: actual QOS system program and its full unit closure,
  strict native coverage, existing 312/67 ceilings; exit 0. `qos-native.*`
  retains the preliminary codegen-82 result; `qos-native-final.*` is g83.
- `base.*`: final full Base sweep, 121 jobs in 567 seconds on four workers,
  exit 0. Existing RV32 SoftFloat libraries were explicitly supplied from
  the sibling checkout's ignored build tree.
- `qos-integrity.*`: relocated QOS native process, ABI/integrity rejection and
  vector execution, both virtio variants and one/two harts, exit 0.
  `qos-integrity-previous-memory.*` repeats the gate with its OldMemory fixture
  set to the immediately preceding ABI 2, also exit 0. QOS helper selection
  now preprocesses the header with the real RV64 compiler rather than reading
  hosted A64's first conditional definition.
- `arc-raw-final.*`: full ARC/raw acceptance, independent 879-case word/Int
  oracle and new raw byte library without ARC adapters, 2,048 memory cases.
- `x64-scalar.*`: Rosetta execution across all six settings, 32,114 C-reference
  cases each, including the newly enabled 9/64-argument self loops.
- `abi-selection.json`: actual C-preprocessed contracts: hosted A64 7/3/3,
  QOS A64 and RV64 6/3/3; QOS packaging selects 6/3/3.
- `next-audit.txt`: remaining production caller inventory, not additional
  implementation or completed platform evidence.
- `development/`: failed development attempts, retained as such. These include
  fixture syntax and toolchain multilib/link setup, and the two obsolete
  refusal/diagnostic/loop assertions exposed by the full sweep, and the QOS
  raw-byte linkage and conditional-ABI defects fixed during acceptance. They are not
  acceptance evidence.

Reproduction:

```sh
python3 tests/check_stack_reservation.py
python3 tests/check_typed_ir_rv_frames.py --require-execution
FPR_SOFTFLOAT_ROOT=/path/to/softfloat python3 tests/check_fixed_stack_reservation.py --require-execution
FPR_SOFTFLOAT_ROOT=/path/to/softfloat python3 tests/check_base.py -j 4 --times
python3 tools/bench-rv-frames.py --against /path/to/compiler-from-042a6d8 --output /tmp/new-rv-frame-measurement --runs 31
```

The optional physical test adds `--port /dev/cu.usbserial-20250303171` to the
fixed-stack command and requires the already configured 48 MHz RV32 board.
QOS checks run from its checkout with `FPRISC_ROOT` pointing here, using its
own module store and foreign contracts. No main branch or remote was updated.
