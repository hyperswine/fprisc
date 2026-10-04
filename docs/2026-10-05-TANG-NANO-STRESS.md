# Larger FP-RISC workloads on the Tang Nano 20K

All measurements below were executed on the connected Tang Nano 20K's
SimpleRisc RV32IM core at 96 MHz on 2026-10-05. These are compiled FP-RISC
builtin programs, not C substitutions or simulations. Sources live in
`tests/tangnano20k_stress/`; `tests/check_tangnano20k_stress.py` compiles them,
builds independent Python references, and requires exact UART output including
an explicit runtime exit status.

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

`tree_near.fpr` raises the live tree to 540 nodes: **43,200 / 43,760 bytes,
98.72% of its available heap**, leaving 560 bytes. Three hardware runs passed;
each run builds and releases the tree eight times and takes about 1.032 seconds.
The tree sum is 146,070, the peak live-allocation count is exactly 540, and every
round returns to the initial allocation count. This exercised 12,960 node
allocations and releases across the three runs at that occupancy.

`tree_limit.fpr` requests 550 nodes, needing 44,000 bytes of node blocks against
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

Memory workloads perform substantial runtime work: each indexed access goes
through a boxed address allocation and explicit release. The matrix timing
therefore includes more than just its 262,144 multiply-accumulate operations.
These results establish correctness and bounded memory use for the tested
sizes; they do not establish a stack-overflow guard or desktop-class throughput.

## Reproduce

Load the verified 96 MHz FPGA SRAM image, then run from `fprisc`:

```sh
python3 tests/check_tangnano20k_stress.py \
  --port /dev/cu.usbserial-20250303171 --repeat 2
```

The current suite includes the near-full tree and expected exhaustion probe
alongside the five primary programs. `--only matrix`, `--only tree_near` or
`--only tree_limit` select individual workloads. `--timeout` defaults to 180
seconds per program; the port is stopped with Ctrl-C before closing.

The measured reports are generated locally at:

- `build/tangnano20k-stress/results.json`: ten primary workload runs.
- `build/tangnano20k-stress/near-limit-results.json`: three near-full tree runs.
- `build/tangnano20k-stress/exhaustion-results.json`: expected out-of-memory result.

The verified FPGA image is
`../HaskPlayground/output/tangnano20k/simple_risc.fs`, SHA-256
`2563be842bfbabcaf77c6a0e784feff27fc3077d2a28d2b01a4f423ecf51211e`.
See [the builtin port](2026-10-05-TANG-NANO-BUILTIN.md) for startup, ABI and
unsupported services.
