# Tang Nano: the fprisc-48 preset and example runner

Kind: implementation and usage guide. Applies to the standalone `simple-risc`
checkout and this FP-RISC checkout on 2026-10-21. The shared preset name is
`fprisc-48`; this is a single-threaded Base development configuration.

## Build and run

From `simple-risc`, build the matching FPGA image:

```sh
SDRAM_PRESET=fprisc-48 boards/tangnano20k/sdram/build.sh
```

This selects the SDRAM pipeline, RV32IMC, CPU/SDRAM 48/48 MHz, 135-degree
memory phase, 64 KiB banked write-update cache and placement option 2.
Conflicting environment settings and experimental RTL overrides are rejected.
The output is `output/tangnano20k/fprisc-48/`. Its `build-manifest.json`
remains `ready: false` until generation, vendor placement and the internal
setup/hold gate complete. It records source hashes, GHC/Cabal versions,
generated RTL and artifact hashes. SDRAM I/O/PVT qualification remains open.

From `fprisc`, run the complete software suite without a board:

```sh
python3 tools/run_tangnano20k_examples.py --target qemu
```

Run the same suite physically, loading the manifest's image into FPGA SRAM:

```sh
python3 tools/run_tangnano20k_examples.py --target board \
  --fpga-manifest ../simple-risc/output/tangnano20k/fprisc-48/build-manifest.json
```

Use `--port` for a different UART and `--loader` for another openFPGALoader
installation. This command programs volatile FPGA SRAM and writes guest images
to SDRAM. It does not program FPGA flash or write the SD card. The runner
checks the preset configuration and artifact hashes before programming.

Both commands build the compiler with `make fpr` and build the pinned RV32
SoftFloat archive if missing. Existing SoftFloat archives are hashed in each
guest manifest. An initial build needs the documented Haskell, RISC-V GCC,
Python, and QEMU tools; a physical FPGA build also needs working Gowin licensing.
The repositories are expected beside each other for the commands above.

`FPR_PRESET=fprisc-48` selects RV32IMC, the soft-float ABI, a 48 MHz runtime
clock and `FPR_GC=1`. It rejects conflicting XLEN, C-extension, clock, GC and
GC-stress settings. QEMU uses `FPR_QEMU=1` solely for its UART adapter.
Without a preset, the existing build defaults and manual ownership remain.

To build an individual program:

```sh
FPR_PRESET=fprisc-48 machine/tangnano20k/build-softfloat.sh
FPR_PRESET=fprisc-48 machine/tangnano20k/build.sh examples/wc.fpr build/board-wc
python3 tools/run_tangnano20k_base.py build/board-wc/base.bin \
  --freq-mhz 48 --root /path/to/input-files --arg=notes.txt --arg='two words.txt'
```

## What passes the suite

| Case | Required result |
|---|---|
| hello | factorial(6) = 720, running the small Base example |
| numeric | existing RV32 scalar/soft-float fixture checks |
| collections | record/vector fixture's exact output |
| host | UART input, rooted file read/write/append, explicit unavailable operations, and host-side file verification |
| args | exact empty/space/dash/Unicode/quote arguments, in order, and repeatable access |
| wc | unmodified `examples/wc.fpr`, exact counts for two files including a filename with spaces |
| classifier | ten 512/128-row runs in one process; independent tree/prediction/root checks and bounded retained heap |

Every case requires a successful runtime exit. Board cases additionally require
loader readback and return to `DONE`. Successful exit alone cannot pass a case.
`--cases hello args wc` runs a subset; its report has `suite_complete: false`.

Outputs live in `build/tangnano20k-examples/{qemu,board}/`, or `--out DIR`.
`results.json` records the target, per-case pass/failure, repository identity,
guest manifests, and FPGA provenance for physical execution. Each build saves
its program, assembly/unit, ELF, binary, compiler and SoftFloat hashes plus
the GCC version. Logs stay beside the results. A new invocation invalidates
the preceding success report before running. A failed case exits unsuccessfully.

QEMU uses the production runtime/startup/root adapter with a 16550 UART
adapter; it does not test FPGA cache, SDRAM, UART electrical timing or CDC.

## Run your own program

Use `--program` instead of the built-in suite to compile and run any `.fpr`
program supported by the single-threaded RV32 Base target:

```sh
python3 tools/run_tangnano20k_examples.py --program examples/wc.fpr \
  --root /path/to/input-files --arg=notes.txt --arg='two words.txt'

python3 tools/run_tangnano20k_examples.py --target board --program myprogram.fpr \
  --fpga-manifest ../simple-risc/output/tangnano20k/fprisc-48/build-manifest.json \
  --root /path/to/files --arg=-n --arg= --input='first line' --input='second line' \
  --env=MODE=demo --timeout 120
```

Source, file root, manifest and output paths resolve relative to your current
directory, including paths containing spaces. `--root` must exist; when omitted,
the runner creates an isolated `files/` directory under its output directory.
The guest can read and write files within that root. Arguments and input lines
are repeatable, preserve their order and are passed without shell interpretation.
Use `--arg=` or `--input=` for an empty value and `--arg=-n` for a leading dash.
Input returns EOF after the last supplied line. Environment values are explicit
`--env NAME=VALUE` entries; they do not inherit the host environment.

The default target is QEMU. The board target validates the FPGA manifest,
compiles the program, programs FPGA SRAM, uploads the guest and requires a
successful runtime exit followed by `DONE`. The preset fixes the runtime at
48 MHz. Unsupported Base services still fail explicitly; selecting a custom
program does not enable actors or unavailable file APIs.

Custom runs print guest output and save `program/run.log`, build artifacts and
`results.json` in `build/tangnano20k-examples/program-{qemu,board}/` or `--out`.
The report records the invocation, source/build identity and successful exit.
It has `mode: program` and `suite_complete: false`: an arbitrary program's
successful exit is not a seven-case suite result or an application-specific
correctness check. Compile errors, runtime errors and timeouts produce failed
reports and retain diagnostics. `--timeout` limits ordinary/custom guest
execution; the suite's ten-run classifier retains its separate 600-second limit.

## Continuous integration

The existing Debian CI job now checks out SimpleRisc commit
`8479466ba159ebaf4faf035502dfc3b6354b2083` into `.ci/simple-risc`, runs both
repositories' preset/manifest tests and the UART protocol checks, builds
SoftFloat for RV32 and RV64, then runs all seven examples in QEMU, the custom
program regression, and the RV32/RV64 argument and GC-root regressions.
It retains JSON reports and logs even when a step fails. Update the pinned
SimpleRisc revision deliberately when the shared preset contract changes.
The unit tests accept `SIMPLE_RISC_ROOT` for CI's non-sibling checkout.

The custom-program regression exercises a source file outside the checkout's
source directories, caller-relative paths with spaces, arguments, input/EOF,
environment, rooted file read/write, compile/runtime failures and timeout log
retention. Run it locally with `python3 tests/check_tangnano20k_program.py`.
Add `--target board --fpga-manifest PATH` for its physical success case.
CI does not synthesize or program an FPGA; physical validation remains separate.

Local validation of this extension passed all seven QEMU suite cases, the
custom program on QEMU and the physical 48 MHz image, all three failure paths,
six runner unit tests, two pinned SimpleRisc manifest tests, UART protocol
checks and the RV32/RV64 argument regressions. The workflow passed actionlint
v1.7.7. The pinned SimpleRisc tests also passed from a non-sibling directory.
The [runner/CI evidence](evidence/2026-10-21-tangnano20k-runner-ci/manifest.json)
records source hashes and test results. This validates the added commands
locally; the edited GitHub workflow has not yet executed on a hosted runner.

## Argument protocol

`Sys.args` requests operation 9 of the existing `@FPR1` UART service with an
empty request payload. The reply is a little-endian u32 argument count,
followed by a little-endian u32 UTF-8 byte length and those bytes per argument.
It excludes the program name. Count is at most 256; total encoded size is at
most 65,536 bytes. Empty strings, whitespace, leading dashes, quotes and
Unicode are preserved. Embedded NUL is rejected. The device returns the same
arguments on every request. The guest validates bounds, truncation and trailing
bytes before allocating list nodes; older hosts fail explicitly as unavailable.

```sh
python3 tests/check_tangnano20k_args.py
python3 tests/check_tangnano20k_virtual.py
python3 -m unittest discover -s tests -p test_tangnano20k_examples.py
```

The argument regression uses RV32 and RV64 QEMU with collection before every
allocation, including the maximum argument count/encoded length and malformed
or unavailable replies. This exposed an existing deep-equality issue: equal
lists could compare unequal when the coalescing allocator supplied different
capacities. List comparison now visits exactly the two Cons fields; allocation
capacity and padding are not list contents. The boundary regression exercises
that fix after printing a large argument and requesting the list again.

## FPGA build boundary on 2026-10-21

Fresh Clash generation completed. The generated clocks, PLL, memory wrapper,
pins and top match the accepted 2026-10-20 48 MHz configuration after the
repository-path move. The CPU RTL matches after removing source-location
comments; hand-written SDRAM Verilog and ROM bytes match the recorded source
revision `32bdefff1932b6ab845a65a6b78424c59dfc0226`.

The first three vendor attempts failed with `License verification failed Server
not responding`. A subsequent full preset retry succeeded on 2026-10-21:
synthesis, placement, routing and the internal timing gate passed at 48 MHz,
with 55.269 MHz reported Fmax, +2.740 ns worst setup slack and zero setup/hold
violating endpoints. The fresh preset manifest is now `ready: true`; all six
artifact hashes and the generated RTL hash were verified. The new bitstream
SHA256 is `30a3f82d8249fe1db0e35c51e7b3b9abb269b729e6b16b60ded71fdf57d986c3`.
See the [fresh build evidence](evidence/2026-10-21-tangnano20k-preset/gowin-retry.json).
The subsequent full board suite also passed on this new image, as recorded
below. SDRAM I/O/PVT qualification remains open.

The initial physical tests used the prior accepted bitstream, whose SHA256 is
`032849eeb6fe291eb8b73038ed0ef88f9ffacfe24e1e834342672683ac539f40`.
Its hash and original RTL hash were checked against the tracked
[GC evidence](evidence/2026-10-20-tangnano20k-gc/manifest.json), and its 48 MHz
vendor timing report was rechecked: +2.740 ns worst setup, zero setup/hold
violating endpoints under the supplied internal constraints.

The local reuse manifest is
`../simple-risc/output/tangnano20k/fprisc-48-accepted-20261020/build-manifest.json`.
It explicitly records `origin.kind: previously_accepted_build`, the earlier
source revision, evidence hash and comparison limits. This is separate from
the fresh-build directory. To reproduce the initial board run while
that local artifact remains available, pass this reuse manifest to the same
`--target board --fpga-manifest` command above.

## Validation on 2026-10-21

After the successful Gowin retry, the new bitstream
`30a3f82d8249fe1db0e35c51e7b3b9abb269b729e6b16b60ded71fdf57d986c3`
was loaded into FPGA SRAM and the complete seven-case suite passed again.
Every guest exited with `FPR EXIT 0` and returned to ROM `DONE`. The ten
classifier runs each matched the independent reference, taking 12.877–13.472
seconds per iteration. The run completed 22 collections, reclaimed 172,795,360
bytes, and retained at most 243,712 live bytes in the reported post-collection
samples. Peak allocation was 8,060,224 bytes, within the usable heap bound.
The [fresh board evidence](evidence/2026-10-21-tangnano20k-preset/fresh-board/manifest.json)
records the exact image, programming log, all seven UART logs, and full suite
and classifier reports separately from the initial run.

Initial validation results:

All seven cases pass in QEMU and on the physical Tang Nano. The board's ten
512/128-row classifier iterations each match the independent reference,
including the full prediction digests and root split. Per-iteration time is
12.877–13.472 seconds. There are 22 collections reclaiming 172,795,360 bytes;
post-collection retained data stays below 1 MiB and peak allocation stays
within the available 8 MiB board memory after firmware/stack/bitmap reservations.

Additional checks pass:

- RV32 and RV64 argument limits, content/order, repeat calls, malformed and
  unavailable replies, with collection before every allocation.
- All ten existing RV32IM/IMC Base fixtures with collection every seven allocations.
- The existing native equality fixture (42 output checks).
- Four runner failure/preset tests and two FPGA manifest failure tests.
- Existing UART virtual-device tests, Python/shell syntax and diff checks.

The board now remains on the newly built 48/48 MHz SRAM image, idle after successful
guest exit and ROM `DONE`. Flash and SD contents were not changed. Compact
[evidence and source hashes](evidence/2026-10-21-tangnano20k-preset/manifest.json)
include the complete QEMU/board case reports, classifier report/log, argument
and `wc` UART output, FPGA programming log, and software regression results.
