# End-to-end runtime comparison, 14 November 2026

The six unchanged FP-RISC applications together took 8.285 s at v0.13.1, 2.248 s at the pre-change checkpoint and 2.162 s with the local changes. These sums of workload medians represent one invocation of each application. The latest changes saved 86 ms across that mix. No application frequency weights were supplied.

| Workload | Tagged release, ms | Pre-change, ms | Modified, ms | Time saved vs release | Time saved vs pre-change |
| --- | ---: | ---: | ---: | ---: | ---: |
| format | 490.80 | 229.76 | 136.33 | 72.2% | 40.7% |
| records | 875.42 | 312.66 | 310.50 | 64.5% | 0.7% |
| sim | 2464.14 | 167.09 | 168.39 | 93.2% | -0.8% |
| treemap | 706.14 | 386.10 | 384.64 | 45.5% | 0.4% |
| csv | 1363.45 | 528.05 | 523.30 | 61.6% | 0.9% |
| wordfreq | 2384.86 | 623.94 | 638.56 | 73.2% | -2.3% |
| pop | 206.46 | 151.41 | 11.25 | 94.6% | 92.6% |
| ping | 57.09 | 30.80 | 32.05 | 43.9% | -4.1% |
| append | 32.57 | 33.65 | 34.73 | -6.6% | -3.2% |
| loop | 232.76 | 224.91 | 186.30 | 20.0% | 17.2% |
| pair | 56.86 | 56.58 | 32.82 | 42.3% | 42.0% |

## Builds and timing

On the same Darwin arm64 host, each workload ran once for warm-up per build and six times per build for timing. Run order rotated and reversed. Each elapsed time covers process creation through successful exit, capturing output. Compilation, fixture generation and disk reset occurred outside timing. FP-RISC v0.13.1 used commit e8fddc57. QOS desktop-v0.3.1 used commit 81b8951e and its pinned FP-RISC compiler 1a09f014. The pre-change checkouts used FP-RISC 5aa73004 and QOS 2fd6b1a1. Modified builds used their local working trees. Private build caches kept the three variants separate. ABI stamps for the QOS apps were 22.141, 22.219 and 24.221 respectively.

The six application binaries used identical workload sources and deterministic inputs. Every invocation matched the saved stdout oracle byte for byte. The population workload ran the same 1,024-worker single-hart fixture with cost instrumentation disabled and checked completion of every worker. The two-hart QOS ping workload exchanged 100,000 request/reply pairs and checked the accumulated reply checksum.

Each QOS storage process started with an identical 64-page seeded disk. The append and loop cases performed one or sixteen sequential durable appends, then inspected the head and latest value. The harness verified the final payload page on disk. The pair case queued two same-key requests before releasing the storage actor, checked both acknowledgements, replay order and latest value, and checked the on-disk generation. The tagged and pre-change builds advanced from 11 to 13. The modified build advanced from 11 to 12. These runs measured application wall time with real host sync operations. Physical power-loss recovery and cold hardware-cache timing were outside the comparison.

The unmodified current QOS Apple Silicon packager rejected relocation 311 for the optional weak mailbox wait hook. For the benchmark only, the app linked directly to the implementation in its matching FP-RISC runtime. This removed the weak declaration and its availability check in a temporary source copy. The normal packaging issue remains open. Small timing differences, especially single append and ping versus the checkpoint, overlap the run-to-run spread. No universal runtime-overhead fraction can be inferred from these workloads.

[All timed samples and input hashes](2026-11-14-END-TO-END-RUNTIME.json)
