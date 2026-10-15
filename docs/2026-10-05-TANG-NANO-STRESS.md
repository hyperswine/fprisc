# Larger FP-RISC workloads on the Tang Nano 20K

The original measurements below were executed on the connected Tang Nano 20K's
SimpleRisc RV32IM core at 96 MHz on 2026-10-05. These are compiled FP-RISC
builtin programs, not C substitutions or simulations. Sources live in
`tests/tangnano20k_stress/`; `tests/check_tangnano20k_stress.py` compiles them,
builds independent Python references, and requires exact UART output including
an explicit runtime exit status.

These measurements describe the October 5 compiler, heap and BRAM processor.
For the later compiler/heap changes and SDRAM pipeline measurements, see the
[October 16 checkpoint](2026-10-16-TANG-NANO-PERFORMANCE.md). Current fixture
calibration is documented separately below.

The five primary workloads each passed twice in one exclusive UART session.
The time starts when the host receives the program's `BEGIN` line and ends at
its verified exit. It excludes UART upload and runtime startup, and includes
final UART output. This is elapsed board execution time, not a cycle counter.

| Program | Work | Working data | Available heap | Time per run |
|---|---|---:|---:|---:|
| `sieve.fpr` | Sieve of Eratosthenes through 36,000; count and sum every prime | 36,001 B byte buffer | 41,952 B | 10.853 s |
| `sort.fpr` | Bottom-up merge sort of 8,192 deterministic 16-bit values; check ordering and digest | Two 16,384 B buffers | 40,256 B | 22.479 s |
| `matrix.fpr` | 64 x 64 integer matrix multiplication; 262,144 multiply-accumulate steps | Three 8,192 B buffers | 41,136 B | 38.269 s |
| `tree.fpr` | Build, sum and release 447-node balanced trees eight times | 35,760 B allocated node blocks | 43,760 B | 0.768 s |
| `compute.fpr` | 1,000,000 tail-recursive arithmetic iterations, including multiply, divide and remainder | No large buffers | 45,200 B | 23.547 s |

Raw-buffer figures exclude allocation headers, boxed addresses and output
formatting. Tree figures include allocator metadata and padding: each Node
requests 20 bytes in the generated RV32 assembly, rounds to a 32-byte payload,
and carries a 48-byte allocator prefix, totaling 80 bytes per live node.
The binary images range from 7,624 to 12,416 bytes; code/BSS and the reserved
8 KiB stack share the same 64 KiB RAM with the heap.

Host references matched:

- Sieve: 3,824 primes; sum 64,771,067.
- Sort: rolling digest 395,872, plus on-board ascending-order checks.
- Matrix: rolling digest 279,822 and sum 18,182,233. These are aggregate checks,
  not a UART dump and comparison of every output cell.
- Tree: sum 100,128; exactly 447 live allocations at peak; allocation count
  returns to its starting value after each release.
- Arithmetic loop: checksum 175,362.

## Near-full heap and explicit exhaustion

The then-current `tree_near.fpr` raised the live tree to 540 nodes: **43,200 / 43,760 bytes,
98.72% of its available heap**, leaving 560 bytes. Three hardware runs passed;
each run builds and releases the tree eight times and takes about 1.032 seconds.
The tree sum is 146,070, the peak live-allocation count is exactly 540, and every
round returns to the initial allocation count. This exercised 12,960 node
allocations and releases across the three runs at that occupancy.

The then-current `tree_limit.fpr` requested 550 nodes, needing 44,000 bytes of node blocks against
the same 43,760-byte heap. The board returned the expected result:

```text
BEGIN tree_limit
Builtin panic: Builtin: out of memory
FPR EXIT 1
DONE
```

The ordinary `builtin_tangnano20k.fpr` image was then loaded and passed again.
The exhaustion test is an expected refusal, not a successful completion of the
oversized tree. No new FPGA build or power cycle was needed for recovery.

### Current BRAM fixture calibration (2026-10-16)

The historical 540/550-node thresholds above no longer serve both current
IM and IMC builds. Compiler code size, the heap index's BSS and the live-pointer
bitmap change usable BRAM capacity. The current fixtures use **500 nodes**
for near-capacity success (sum 125,250) and **600 nodes** for explicit OOM.
Each RV32 Node still occupies 80 whole-block bytes: 20 requested payload
bytes round to 32, plus the preserved 48-byte allocator prefix.

| Current linked mode | Heap arena | Bitmap | Usable whole-block bytes | 500-node margin | 600-node excess |
| --- | ---: | ---: | ---: | ---: | ---: |
| RV32IM | 41,488 B | 336 B | 41,152 B | 1,152 B | 6,848 B |
| RV32IMC | 44,320 B | 352 B | 43,968 B | 3,968 B | 4,032 B |

The 500-node tree uses 40,000 bytes, about 97.2% of the IM build's usable
span. Its extra headroom makes the check less sensitive to small code changes;
compression naturally leaves more space. The 600-node request needs 48,000
bytes and exceeds either current span by several KiB. Source counts, printed
checksums and the independent Python references are updated together.

`python3 tests/check_tangnano20k_bram.py` links the real board IM/IMC images,
derives their actual heap bounds and bitmap reservation, then executes their
generated FP-RISC on a QEMU UART/finisher adapter with exactly those heap bounds
and the 8 KiB stack reservation. Test code/BSS resides outside the BRAM window
so adapter size cannot change admission. All eight 500-node build/sum/release
rounds recover the allocation count in both modes; both 600-node programs
return the expected allocator failure. The gate also requires at least 512
bytes of fit margin and 1,024 bytes of excess. These are current executable
resource checks, not new physical FPGA timings or an updated 98.72% claim.

## Ownership and performance boundaries

These programs explicitly release each temporary boxed `Addr.add` result.
`Mem.free` frees raw buffer storage; `Rc.release` separately frees its boxed
address handle. Every successful memory workload checks that its live allocation
count returns to the starting value before formatting the final output. ARC is
still unsupported for this RV32 port.

The builtin profile does not currently link the ordinary `%` / `Int.mod`
helper. The arithmetic workloads define a local `rem a b = a - (a / b) * b`
for nonnegative operands and positive divisors. All intermediates stay within
the RV32 signed Int payload range. These tests do not add general Int.mod, F64,
OS services or actor support.

In the original measurements, each indexed access allocated and explicitly
released a boxed address. The current compiler can eliminate the private
single-access patterns used by these workloads; see the
[address-fusion contract](2026-10-16-RV32-SCALAR.md#indexed-manual-memory-operations).
The original matrix timing therefore includes more than just its 262,144
multiply-accumulate operations.
These results establish correctness and bounded memory use for the tested
sizes; they do not establish a stack-overflow guard or desktop-class throughput.

## Reproduce

To run the current BRAM suite, load a matching RV32IM FPGA image and explicitly
select its clock, then run from `fprisc`. Current software will not reproduce
the historical timing or allocation thresholds exactly:

```sh
python3 tests/check_tangnano20k_stress.py \
  --port "$PORT" --freq-mhz "$FREQ_MHZ" --ram bram --repeat 2
```

The current suite includes the near-full tree and expected exhaustion probe
alongside the five primary programs. `--only matrix`, `--only tree_near` or
`--only tree_limit` select individual workloads. `--timeout` defaults to 180
seconds per program; the port is stopped with Ctrl-C before closing.

The measured reports are generated locally at:

- `build/tangnano20k-stress/results.json`: ten primary workload runs.
- `build/tangnano20k-stress/near-limit-results.json`: three near-full tree runs.
- `build/tangnano20k-stress/exhaustion-results.json`: expected out-of-memory result.

The historical FPGA image was
`../HaskPlayground/output/tangnano20k/simple_risc.fs`, SHA-256
`2563be842bfbabcaf77c6a0e784feff27fc3077d2a28d2b01a4f423ecf51211e`.
See [the builtin port](2026-10-05-TANG-NANO-BUILTIN.md) for startup, ABI and
unsupported services.

## Later clock sweep

The later BRAM clock sweep passed the expanded CPU and workload tests at 114 MHz after
registering the barrel shifter. 117 MHz produced incorrect sieve results and
120 MHz failed an ALU check. The earlier 96 MHz results above describe their
original coverage; the expanded ALU test subsequently exposed shift errors
in that older image. See [the clock retest](2026-10-05-TANG-NANO-CLOCK-SWEEP.md)
for current evidence and commands. Match `--freq-mhz` to the loaded bitstream.
