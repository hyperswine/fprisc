# Tang Nano: the fprisc-72 preset

Kind: preset and board run, 2026-11-01. Pairs with simple-risc's
`SDRAM_PRESET=fprisc-72` ([simple-risc record](../../simple-risc/docs/2026-11-01-FPRISC-72-PRESET.md)).

## Result

`FPR_PRESET=fprisc-72` builds Base programs for a 72 MHz CPU (RV32IMC, the
same as `fprisc-48` except the runtime clock). The example runner takes
`--preset fprisc-72`, checks the FPGA manifest against simple-risc's
fprisc-72 configuration (CPU 72 / SDRAM 48 MHz, two-way 64 KiB cache), and
passes the whole suite on the board: hello, numeric, collections, host,
args, wc and the ten-run 512/128-row classifier.

```sh
python3 tools/run_tangnano20k_examples.py --target board --preset fprisc-72 \
  --fpga-manifest ../simple-risc/output/tangnano20k/fprisc-72/build-manifest.json
```

`fprisc-48` stays the default and is unchanged.

## Fixed on the way

`Sys.name` (added for `Program.name` in 8d8dcf6) had no Tang Nano
implementation, so every board program using `std/program` failed to link,
which included the host, args and wc cases at both clocks. It now returns an
empty name, as on POSIX without an `argv[0]` (f3802f5).

## Classifier against earlier weeks

512/128 rows, ten runs, heap reporting on, median per run:

| Board image | 20 October binary | Today's binary |
|---|---:|---:|
| 48/48, accepted (20-21 Oct) | 12.92 s | - |
| 72/54, rejected for wrong trees (20 Oct) | 8.80 s | - |
| fprisc-72 (today) | 7.16 s | 8.49 s |

The hardware is 1.23x faster on the same binary, and correct. Today's
FP-RISC build is 1.19x slower than the 20 October one on the same image
(8.34 s without heap reporting), although its image is half the size
(74 KB against 152 KB). The change from the conservative collector to
compiler-placed regions and code generation changes since 20 October are
the candidates; bisecting it is open.

## Evidence

Results under `build/tangnano20k-examples/board-fprisc-72/` and
`build/tangnano20k-72/`; copies in simple-risc's
`docs/evidence/2026-11-01-fprisc-72/`.
