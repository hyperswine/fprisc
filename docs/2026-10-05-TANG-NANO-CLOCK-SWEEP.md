# Tang Nano clock retest, 2026-10-05

The highest tested clock that passed all workload checks is **114 MHz** with
HaskPlayground's registered two-stage shifter. The connected board is left on
that SRAM image. 117 MHz passed the small CPU and builtin tests but returned
incorrect sieve results twice; 120 MHz failed subtraction in the expanded
ALU regression. Higher clocks are not usable for this design yet.

The processor's shift instructions now take nine clocks instead of eight;
other ordinary instructions still take eight. This changes execution timing,
not the RV32IM ABI or memory map. The default host-tool frequency remains
96 MHz: explicitly supply `--freq-mhz 114` while this image is loaded.

## Verified coverage

- 38,400 RV32I ALU comparisons across ten loads, including every shift distance.
- 30,720 RV32M comparisons across 20 loads.
- C arithmetic, byte/halfword/word stress, UART echo, reset and clear/reload.
- Three builtin smoke runs, seven expected refusals and recovery.
- Four complete larger-workload passes, 28 checked runs, including near-full
  heap allocation, expected exhaustion and successful compute after exhaustion.
- 104 interactive factorial answers checked against Python, three expected
  input refusals and successful exit on an empty line.

At 108 MHz the same final processor passed two full workload suites (14 runs).
At 114 MHz the first pass is recorded in
`build/tangnano20k-stress/clock-114-shift.json`; the three confirmation passes
are in `clock-114-confirm.json`. Reports are generated artifacts ignored by Git.

## Workload timings

| Workload | Previous 96 MHz run | 114 MHz median, four runs | Speedup |
|---|---:|---:|---:|
| sieve | 10.853 s | 9.152 s | 1.186x |
| sort | 22.479 s | 18.958 s | 1.186x |
| matrix | 38.269 s | 32.306 s | 1.185x |
| tree | 0.768 s | 0.648 s | 1.186x |
| compute | 23.547 s | 20.103 s | 1.171x |

These are exact-output-verified executions of the existing FP-RISC programs.
Time runs from the UART BEGIN line to the verified exit, excluding upload and
startup. The old 96 MHz values are the measured runs in
[the original stress report](2026-10-05-TANG-NANO-STRESS.md), not a fresh
baseline using the updated processor. The expanded ALU test found shift
corruption in that older image, so its earlier workload passes must not be
interpreted as general processor correctness.

## Failed higher clocks

At 117 MHz, the sieve returned 2,545 primes with sum 52,192,662, then 2,902
primes with sum 43,319,387 on a separate reproduction. Both ended with
`FPR EXIT 0`, but the reference is 3,824 primes and sum 64,771,067.
At 120 MHz, the ALU regression reported 2 - 2 as 2,147,483,648 instead of zero.
Runtime exit and simple smoke tests therefore cannot establish clock stability;
independent output references are required.

The next hardware work is to isolate the large-memory failure at 117 MHz and
shorten/register remaining arithmetic and carry paths before retrying 120 MHz.
114 MHz is the highest passing tested point, not a temperature/voltage-qualified
maximum or an absolute limit of the FPGA.

## Load and repeat

The tested 114 MHz image is generated locally in the sibling HaskPlayground
checkout. Its SHA-256 is
`5852804440d1cf3eb57936f830b66eb53e61450d02675f6acbd9179dc45d0bc2`.
See `../HaskPlayground/boards/tangnano20k/CLOCK-SWEEP-2026-10-05.md` from the
fprisc root for processor changes, timing evidence and PLL-only replay commands.
The routed-base nextpnr estimate is 150.58 MHz; actual board checks fail well
below that estimate. No flash was programmed.

```sh
~/Documents/Libs/oss-cad-suite/bin/openFPGALoader -b tangnano20k \
  ../HaskPlayground/output/tangnano20k/clock-sweep/114-shift/simple_risc.fs
python3 tests/check_tangnano20k.py --port /dev/cu.usbserial-20250303171 --freq-mhz 114
python3 tests/check_tangnano20k_stress.py --port /dev/cu.usbserial-20250303171 \
  --freq-mhz 114 --repeat 3 --report build/tangnano20k-stress/clock-114-confirm.json
python3 tools/run_simple_risc.py build/tangnano20k-fact/fact.bin \
  --port /dev/cu.usbserial-20250303171 --freq-mhz 114 \
  --prompt 'n?' --input 5 --input 0 --input 12 --input 13 --input ''
```
