# FP-RISC microSD driver on Tang Nano 20K

The SD command protocol and small FAT16/FAT32 file layer are FP-RISC:

- `std/tangnano20k/sd.fpr`: initialization, CSD/CID/OCR, capacity bounds,
  CMD17/CMD24 sector I/O, CRC7 commands, CRC16 data, bounded waits, CMD13
  write completion status, and chip-select cleanup on errors.
- `std/tangnano20k/fat.fpr`: mount an existing primary MBR FAT partition or
  FAT superfloppy, read a root file, and create a new root file without
  overwriting an existing name.
- `machine/tangnano20k/sd_hal.c`: 84 lines exposing the SPI registers and
  a shared 512-byte buffer. It contains no SD or filesystem protocol.

This is a single-caller, manual Base implementation. The filesystem accepts
uppercase 8.3 names and creates files of 1 through 512 bytes; reads accept
0 through 512 bytes. It does not format media, delete files, grow directories,
reuse deleted directory entries, implement long filenames, or support ext4,
exFAT or FAT12. Allocation and directory scans have explicit limits.
Unsupported geometry, unclean/error-marked volumes, disabled FAT32 mirroring,
an occupied name, or exhausted bounded scans return `Err` before allocation.
Primary MBR entries must have valid, disjoint ranges. A superfloppy is
accepted only when its partition-table bytes are all zero. FAT32 creation
validates the complete root cluster chain and its mirrored links before
writing any data; free/bad/reserved links, cycles and excessive length fail.

Create writes file data, mirrored allocation entries, FSInfo invalidations,
then publishes the directory entry. It preserves the FAT32 reserved high bits
and invalidates both known FSInfo copies. A failed metadata write reports an
uncertain outcome. Removal or power loss during create can leak a cluster or
leave FAT copies inconsistent; this small driver has no journal.

## Hardware

The sibling HaskPlayground change connects the existing SPI mode-0 byte
shifter to the SDRAM pipeline, retaining RV32IMC, 48 MHz, 8 MiB RAM, the
2 KiB cache and extended Base loader. DMA stays unmapped because the old
DMA engine addresses BRAM rather than SDRAM.

| Address | Meaning |
|---|---|
| `0x10001000` | SPI DATA |
| `0x10001004` | STATUS, bit 0 busy |
| `0x10001008` | CTRL, CS bit 0, divider bits 8 through 15 |
| `0x1000100c` | `SDP1` capability (`0x53445031`) |

The existing board pins are SCK 83, MOSI 82, MISO 84 and CS 81. DAT1/2 are
held high. MISO uses two synchronizer registers. Identification uses divider
255 (93.75 kHz at 48 MHz); the initial transfer divider is 7 (3 MHz).

## Build and use

```sh
FPR_XLEN=32 FPR_RVC=1 FPR_CPU_MHZ=48 \
  machine/tangnano20k/build.sh tests/tangnano20k_sd_probe.fpr \
  build/tangnano20k-sd/probe

python3 tools/run_tangnano20k_base.py \
  build/tangnano20k-sd/probe/base.bin --freq-mhz 48 --timeout 180

python3 tests/check_tangnano20k_sd.py
```

The probe only reads. It reports card identity/capacity, partition bounds,
boot sectors and Linux superblock signatures. It never calls `Sd.write`.
`tests/tangnano20k_sd.fpr` is also read-only. A file-writing fixture is kept
separate so running a card-identification command cannot allocate a file.

The historical HaskPlayground raw-sector test is not used: its fixed test
LBAs can fall inside an existing partition.

## Validation

All **38 native acceptance cases** passed. The acceptance links the production FP-RISC driver and C HAL to a
test-only SPI/SDHC model backed by disposable regular files. Independent
Python builds and inspects FAT images, verifies directory entries, mirrored
FATs, end-of-chain markers, payload persistence, and preservation of an
existing binary file and partition gap. Reopening runs in a fresh process.
It injects SPI, initialization, token, CRC, write-rejection, programming-busy
and CMD13 faults, and checks refusals without unexpected writes.

Native execution is separate from the physical FPGA and RV32 execution.
The same file fixture is also compiled for RV32, and the HAL is compiled
with warnings treated as errors natively and cross-compiled for RV32IMC.

HaskPlayground's focused Haskell and generated CPU/cache RTL checks cover
SPI byte exchange, MMIO capability/control, MISO synchronization, retained
responses while the cache holds the CPU, reset, and deliberate RAM corruption.

On the physical board, the 163,116-byte read-only probe passed at 48 MHz
CPU / 3 MHz SPI, ending with `FP SD READ ONLY PROBE HOLDS`, `FPR EXIT 0`
and `DONE`. The card is an SDABC SDXC, 122,152,960 sectors. Its initial MBR had
one Linux partition, starting at LBA 8,192 with 120,905,728 sectors. The
superblock has the ext magic and ext4 features, with volume label `opi_root`.
The file fixture first correctly refused that unsupported filesystem, ending
with `FPR EXIT 1` and `DONE` before any file creation.

After explicit approval, the prepared tool created the 16 MiB FAT16 test
partition described below. It verified all 289 metadata writes, published
the second MBR entry last, and ended with `FPR EXIT 0` and `DONE`.
The physical file fixture then created `FPRTEST.TXT`, read back its exact
60-byte binary payload, refused an overwrite, and reread the unchanged file.
It ended with `FP SD FILE ROUNDTRIP HOLDS 60 BYTES`, `FPR EXIT 0` and `DONE`.
A fresh guest upload then printed `SD EXISTING FILE VERIFIED` and passed
the same exact-payload and overwrite-refusal checks. This proves persistence
across program restarts; power interruption during a write is not tested.

The final read-only `tests/tangnano20k_sd_audit.fpr` dump passed an independent
Python decoder (`tests/check_tangnano20k_sd_audit.py`). It verified the
MBR changed only in the second partition entry, both original Linux
superblock sectors remained byte-identical, the FAT copies agreed, the new
directory entry referenced cluster 2 with length 60, and the complete data
sector contained the expected bytes and zero padding. Logs and decoded
sectors are retained under `build/tangnano20k-sd/audit/`.

The exact programmed image has SHA256
`7bf0accf071d4f032644ac00f3c91a9776289464bc337822571aec6808efe092`.
Gowin reports 48.194 MHz Fmax, +0.084 ns worst setup slack and no setup/hold
violations at 48 MHz. These internal checks have little margin and do not
establish SDRAM I/O/PVT qualification.

Detailed results and source hashes are recorded in
`docs/evidence/2026-10-18-tangnano20k-sd.json`.

## Approved card preparation

The original partition ends at LBA 120,913,920 (exclusive), leaving 605 MiB
outside the existing partition. A separate, card-specific preparation tool
is built at `tests/tangnano20k_sd_prepare.fpr`. It is not a normal test. The
user explicitly approved creating the test partition or overwriting the
unused card; this run used the prepared 16 MiB partition and preserved the
existing Linux partition.

The proposed second partition is 16 MiB FAT16: start LBA 120,913,920,
32,768 sectors, end LBA 120,946,688 (exclusive). Preparation verifies the
exact card identity and original 512-byte MBR, writes and reads back 289
metadata sectors in that tail range, then publishes only the second MBR
entry. It does not overwrite the Linux partition. An additional environment
gate prevents accidental execution. The original MBR and the affected tail
metadata sectors are backed up under `build/tangnano20k-sd/backup/` before
execution. Those complete local backups are accompanied by the durable
compact backup in `docs/evidence/2026-10-18-tangnano20k-sd-original-metadata.json`:
the exact original MBR and a verified repeated-byte encoding of the original
289 tail metadata sectors. This is not a complete-card backup.

`tests/check_tangnano20k_sd_prepare.py` passed six native test cases using
only sparse regular-file card models. Missing/wrong execution gates cause
zero SPI MMIO; wrong card identity, capacity or original MBR cause zero SD
writes. The successful model checks all 290 writes in order (289 metadata
sectors, then MBR last), the FAT16 BPB, both complete FAT copies, the empty
root, the exact changed MBR entry, and preservation of Linux/outside
sentinels. This validates the prepared tool, not a physical card format.

Protocol references: the [SD Association simplified specifications](https://www.sdcard.org/downloads/pls/)
and the [Microsoft FAT specification](https://www.scs.stanford.edu/~zyedidia/docs/_other/fat.pdf).
