# Decision-tree classifier on Tang Nano 20K, 2026-10-17

The existing classifier in `tests/dtree.fpr` runs on the separate RV64IMC
Base board host. Training and inference execute on the FPGA processor; the
computer uploads the image, checks readback and captures console output.
The independent Python reference computes expected results separately.

## Physical setup and completed checks

- Tang Nano 20K, 27 MHz RV64IMC, serial core, 8 MiB SDRAM and 64 KiB stack.
- Software floating point from the pinned Berkeley SoftFloat library; no
  hardware A/F/D instructions. The linked ISA check passes.
- FPGA SRAM image: HaskPlayground `output/tangnano20k/rv64c-27/impl/pnr/rv64.fs`,
  SHA-256 `17f72a2ff8c33cfb8f69d23ce51232048e7961ecdbe6b9828638bde109a15a56`.
  Its existing internal timing report gives 36.275 MHz Fmax, +9.470 ns setup
  slack and zero setup/hold violations. These are functional board tests,
  not complete SDRAM I/O or PVT signoff.

| Training / test rows | Bins | Maximum depth / minimum leaf | Nodes | Training hits | Test hits | Guest elapsed |
| --- | ---: | --- | ---: | --- | --- | ---: |
| 32 / 16 | 4 | 3 / 2 | 11 | 27/32 (84.4%) | 15/16 (93.8%) | 2.568 s |
| 128 / 64 | 8 | 5 / 2 | 23 | 124/128 (96.9%) | 61/64 (95.3%) | 10.337 s |
| 512 / 128 | 16 | 6 / 5 | 55 | 481/512 (93.9%) | 116/128 (90.6%) | 40.614 s |

Every completed run matches independent tree size/depth, training and test
hit counts, prediction digests and root split, then returns `FPR EXIT 0` and
`DONE`. These are different workloads and histogram configurations, not a
frequency or compiler speed comparison. Elapsed time comes from the board's
local cycle-derived clock, after the initial BEGIN line: it includes dataset
generation, training, inference and intermediate console output, and excludes
upload/startup. Native execution also matches the Python reference. The final
512-row run includes both constant-stack changes below; the smaller runs
precede those changes. An earlier 512-row checkpoint took 40.227 s.

The dataset is the example's deterministic noisy XOR: training seed 42,
test seed 7, two floating-point features and 5% label noise. Python uses
`math.log2`; FP-RISC retains its original 48-step logarithm. Tree ties retain
the earlier bin and column. The reference independently reproduces the
original 4,000/1,000-row, 256-bin example: 133 nodes, depth 8, 3,787/4,000
training hits, 949/1,000 test hits and its documented root split. That
reference result alone is not physical execution of the 256-bin workload.

## Changes needed to run it

`FPR_NO_F64_INLINE=1` previously disabled scalar floating instructions but
still admitted floating vector specializations. The classifier's min/max
folds emitted `fmv.d.x` and `flt.d`, which the IMC assembler correctly refused.
Codegen revision 45 now declines floating column kernels when software float
is selected, including float inputs returning Bool and mixed record fields.
Integer vector kernels remain enabled; the compiler reports the fallback.

The original recursive index builder and `List.len` also exhausted the
board's fixed stack on 4,000 rows. The classifier now builds the same ascending
indices from the upper end and counts rows with an accumulator. Both operations
use constant stack space; tree semantics and its 48-step entropy calculation
are preserved. Its original main gains the explicit unsafe signature required
by the current compiler. The board wrapper reports structured checks and frees
its final vectors.

At 4,000 rows, 16 histogram bins fail to find a split clearing the existing
0.001 gain threshold: the independent result is a majority-class leaf with
50.85% training and 49.8% test accuracy. Increasing to 32 bins admits a real
169-node classifier. This distinction belongs to the model, not the CPU.

The initial 4,000-row board attempts were rejected on explicit stack exhaustion
and `FPR EXIT 1`; a halt marker was never counted as success. With both stack
fixes, the 4,000/1,000-row, 32-bin, depth-8 run instead stops during training
with `Base panic: Builtin: out of memory`, `FPR EXIT 1` and `DONE`. Its native
execution matches the reference's 169 nodes, 3,785 training hits and 958 test
hits, but this is **not a successful physical full-data run**. The current
Base host does not automatically reclaim temporary constructor values.
The original 256-bin physical workload remains unvalidated.

The final successful 512-row guest image is 152,460 bytes, SHA-256
`a6f27036fb3b694dd5615b6df2da6d3db2ebc38fc63d33ecd9447eff77c69ab3`. The board remains loaded with the RV64IMC image above,
after the successful default workload. [Durable evidence](evidence/2026-10-17-tangnano20k-dtree.json)
retains successful outputs, explicit failed attempts, linked heap/stack bounds
and per-run artifact hashes. Peak heap usage was not instrumented.

## Reproduction

Build FP-RISC and load the matching RV64 FPGA SRAM image first. From fprisc:

```sh
make fpr
python3 tests/check_tangnano20k_dtree.py --native --hardware \
  --train 512 --test 128 --bins 16 --depth 6 --min-leaf 5 \
  --freq-mhz 27 \
  --bitstream ../HaskPlayground/output/tangnano20k/rv64c-27/impl/pnr/rv64.fs
python3 tests/check_tangnano20k_softfloat_vectors.py
```

The first runner defaults to the small 32/16-row smoke test. The directly
buildable `tests/tangnano20k_dtree.fpr` defaults to the 512/128-row case.
Without `--native` or `--hardware`, the runner calculates only the independent
reference. `--hardware` builds IMC code, uses the existing checked Base upload
protocol and requires successful exit before comparing results. It does not
program the FPGA. Reports and logs are saved beneath `build/tangnano20k-dtree`.

This session built from committed runtime revision
`4c57c0f17e2566e2f7b65cf7c77b7edd6223dfbf` in an isolated source snapshot,
overlaid with the compiler/classifier fixes. Unrelated working-tree runtime
edits were excluded and preserved. `--source-root` selects such a checkout or
snapshot; ordinary runs otherwise use the current checkout. Per-run compiler,
classifier, guest binary and FPGA image hashes identify the tested artifacts.

The focused compiler regression uses the existing mixed-kind vector fixture:
F64 map/filter/fold, a mixed-record fold, F32 operations and integer kernels.
Cold/warm RV64IM and IMC builds pass without F/D instructions, preserve identical
images across the warm pass and retain integer specialization. Native floating
kernels and generic C callbacks return the same checked output.
