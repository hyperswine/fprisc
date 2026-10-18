#!/usr/bin/env python3
"""Validate the gated FP-RISC SD formatter against sparse regular files.

This never accesses an FPGA, serial port, physical disk or SD card. The
production HAL is compiled with FPR_SD_HAL_TEST and every register access
goes to the test-only SPI model. The 62.5 GB images are created by truncate;
only explicit 512-byte windows are seeded, read and hashed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BLOCKS = 122152960
LINUX_START = 8192
START = 120913920
COUNT = 32768
APPROVAL = "APPROVED_NEW_16MIB_PARTITION"
CID = "6f0303534441424310aa0001a1018101"
CSD = "400e00325b590001d1f97f800a404001"
ORIGINAL_MBR = (bytes(440) + bytes.fromhex("333dd4a3000000861300837319c00020000000e03407")
                + bytes(48) + bytes.fromhex("55aa"))
METADATA = tuple(range(START, START + 289))
WRITE_ORDER = list(range(START + 1, START + 289)) + [START, 0]
SENTINELS = (1, LINUX_START - 1, LINUX_START, LINUX_START + 2,
             LINUX_START + 3, (LINUX_START + START) // 2, START - 1,
             START + 289, START + COUNT - 1, BLOCKS - 1)
WINDOWS = (0, *METADATA, *SENTINELS)
# APFS may allocate multi-megabyte extents around widely spaced sentinel
# writes. This bound is still below 0.11% of the logical card size.
SPARSE_ALLOCATION_LIMIT = 64 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def small_file_digest(path):
    # Never accidentally expand or hash a sparse whole-card image.
    assert path.stat().st_size <= 128 * 1024 * 1024, ("not a small artifact", path)
    return digest(path.read_bytes())


def read_sector(path, block):
    with path.open("rb") as media:
        media.seek(block * 512)
        value = media.read(512)
    assert len(value) == 512, (path, block, len(value))
    return value


def snapshot(path):
    return {str(block): digest(read_sector(path, block)) for block in WINDOWS}


def seed(path, *, corrupt_mbr=False, blocks=BLOCKS):
    # The caller creates a fresh directory; refuse links/devices regardless.
    with path.open("xb") as media:
        media.truncate(blocks * 512)
        mbr = bytearray(ORIGINAL_MBR)
        if corrupt_mbr:
            mbr[100] ^= 1
        media.seek(0)
        media.write(mbr)
        for block in METADATA:
            media.seek(block * 512)
            media.write(b"\xa5" * 512)
        for block in SENTINELS:
            sentinel = bytearray(hashlib.sha256(f"Linux-preservation-{block}".encode()).digest() * 16)
            if block == LINUX_START + 2:
                sentinel[56:58] = b"\x53\xef"  # ext superblock magic
            media.seek(block * 512)
            media.write(sentinel)
    info = path.lstat()
    assert stat.S_ISREG(info.st_mode) and not path.is_symlink()
    assert info.st_size == blocks * 512
    assert info.st_blocks * 512 < SPARSE_ALLOCATION_LIMIT, "fixture must remain sparse"
    return snapshot(path)


def inspect_prepared(path, before):
    original = ORIGINAL_MBR
    actual = read_sector(path, 0)
    assert actual[:462] == original[:462] and actual[478:] == original[478:]
    expected_entry = bytes.fromhex("00feffff06feffff") + struct.pack("<II", START, COUNT)
    assert actual[462:478] == expected_entry
    assert actual[446:462] == original[446:462], "original Linux partition entry changed"
    assert struct.unpack_from("<II", actual, 454) == (LINUX_START, START - LINUX_START)
    assert actual[450] == 0x83 and actual[510:] == b"\x55\xaa"

    boot = read_sector(path, START)
    u16 = lambda at: struct.unpack_from("<H", boot, at)[0]
    u32 = lambda at: struct.unpack_from("<I", boot, at)[0]
    assert boot[:11] == b"\xeb\x3c\x90FPRISC  "
    assert u16(11) == 512 and boot[13] == 1 and u16(14) == 1
    assert boot[16] == 2 and u16(17) == 512
    assert u16(19) == COUNT and boot[21] == 0xf8 and u16(22) == 128
    assert u16(24) == 63 and u16(26) == 255 and u32(28) == START and u32(32) == 0
    assert boot[36:39] == b"\x80\x00\x29" and u32(39) == 0x46505232
    assert boot[43:54] == b"FPRISC SD  " and boot[54:62] == b"FAT16   "
    assert boot[62:510] == bytes(448) and boot[510:] == b"\x55\xaa"
    root_sectors = (u16(17) * 32 + u16(11) - 1) // u16(11)
    first_data = u16(14) + boot[16] * u16(22) + root_sectors
    clusters = (u16(19) - first_data) // boot[13]
    assert root_sectors == 32 and first_data == 289 and clusters == 32479
    assert 4085 <= clusters < 65525 and u16(22) * 512 // 2 >= clusters + 2

    fat0 = b"".join(read_sector(path, block) for block in range(START + 1, START + 129))
    fat1 = b"".join(read_sector(path, block) for block in range(START + 129, START + 257))
    assert fat0 == fat1 == b"\xf8\xff\xff\xff" + bytes(128 * 512 - 4)
    assert struct.unpack_from("<HH", fat0) == (0xfff8, 0xffff)
    assert all(read_sector(path, block) == bytes(512)
               for block in range(START + 257, START + 289)), "root directory is not empty"
    after = snapshot(path)
    assert all(after[str(block)] == before[str(block)] for block in SENTINELS)
    changed = {int(block) for block in before if before[block] != after[block]}
    assert changed == {0, *METADATA}, ("unexpected modified fixture windows", changed)
    return {"mbr_sha256": digest(actual), "boot_sha256": digest(boot),
            "fat0_sha256": digest(fat0), "fat1_sha256": digest(fat1),
            "fat16_clusters": clusters, "root_entries": 512,
            "only_mbr_entry_1_changed": True, "linux_sentinels_preserved": True,
            "changed_seeded_windows": sorted(changed), "window_hashes_after": after}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/tangnano20k-sd-prepare-model")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    images = Path(tempfile.mkdtemp(prefix="sparse-media-", dir=out))
    binary = out / "sd-prepare-model"
    env = {**os.environ, "XDG_CACHE_HOME": str(out / "cache")}
    command = [str(ROOT / "fpr"), "build", "tests/tangnano20k_sd_prepare.fpr",
               "--harts", "1", "--with", "machine/tangnano20k/sd_hal.c",
               "--with", "tests/base/tangnano20k_sd_model.c",
               "--cflag", "-DFPR_SD_HAL_TEST", "-o", str(binary)]
    build = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True, timeout=240)
    (out / "build.log").write_text(build.stdout + build.stderr)
    assert build.returncode == 0, build.stdout + build.stderr
    assert len(ORIGINAL_MBR) == 512 and len(WRITE_ORDER) == 290
    results = []

    def run(name, *, approval=None, matched=True, corrupt_mbr=False, blocks=BLOCKS, expected=None):
        path = images / (name + ".img")
        before = seed(path, corrupt_mbr=corrupt_mbr, blocks=blocks)
        log = out / (name + ".model.json")
        log.unlink(missing_ok=True)
        run_env = {**os.environ, "FPR_HARTS": "1", "FPR_HEAP_MB": "64",
                   "FPR_SD_IMAGE": str(path), "FPR_SD_MODEL_LOG": str(log),
                   "FPR_SD_FAULT": "none"}
        run_env.pop("FPR_SD_PREPARE", None)
        run_env.pop("FPR_SD_MATCH_INSPECTED", None)
        if approval is not None:
            run_env["FPR_SD_PREPARE"] = approval
        if matched:
            run_env["FPR_SD_MATCH_INSPECTED"] = "1"
        proc = subprocess.run([str(binary)], cwd=ROOT, env=run_env, text=True,
                              capture_output=True, timeout=180)
        output = proc.stdout + proc.stderr
        text_log = out / (name + ".log")
        text_log.write_text(output)
        stats = json.loads(log.read_text()) if log.exists() else None
        result = {"name": name, "image": str(path), "logical_bytes": path.stat().st_size,
                  "allocated_bytes": path.stat().st_blocks * 512,
                  "output": output, "log_sha256": small_file_digest(text_log),
                  "returncode": proc.returncode, "window_hashes_before": before,
                  "stats": stats}
        if expected is not None:
            assert proc.returncode != 0 and expected in output, (name, proc.returncode, output)
            assert snapshot(path) == before, (name, "refusal modified seeded media windows")
            if approval != APPROVAL:
                assert stats is None, (name, "unset/wrong gate touched SPI registers", stats)
                result["zero_mmio_accesses"] = True
            else:
                assert stats is not None and stats["writes"] == 0 and stats["written_blocks"] == []
                assert stats["commands"].get("24", 0) == 0, (name, stats)
            result["zero_sd_writes"] = True
        else:
            assert proc.returncode == 0 and "FP SD PREPARE HOLDS: NEW FAT16 PARTITION" in output, output
            assert stats is not None and stats["blocks"] == BLOCKS
            assert stats["writes"] == 290 and stats["written_blocks"] == WRITE_ORDER, stats
            assert stats["commands"].get("24") == 290 and stats["commands"].get("13") == 290
            assert stats["crc_errors"] == 0 and stats["commands_before_clock_train"] == 0, stats
            result["inspection"] = inspect_prepared(path, before)
            result["model_log_sha256"] = small_file_digest(log)
        assert path.stat().st_blocks * 512 < SPARSE_ALLOCATION_LIMIT, "fixture unexpectedly lost sparsity"
        result["passed"] = True
        results.append(result)
        (out / "results.json").write_text(json.dumps({"complete": False, "cases": results}, indent=2) + "\n")
        print(name + ": PASS", flush=True)

    run("gate-unset", expected="SD PREPARE REFUSED: explicit preparation gate is unset")
    run("gate-wrong", approval="NOT_APPROVED", expected="SD PREPARE REFUSED: explicit preparation gate is unset")
    run("wrong-card-identity", approval=APPROVAL, matched=False,
        expected="SD PREPARE REFUSED: card CID/CSD differs from inspected card")
    run("wrong-capacity", approval=APPROVAL, blocks=BLOCKS + 1024,
        expected="SD PREPARE REFUSED: card capacity/addressing differs from inspected card")
    run("wrong-original-mbr", approval=APPROVAL, corrupt_mbr=True,
        expected="SD PREPARE REFUSED: all 512 MBR bytes must match the preserved original")
    run("approved-sparse-image", approval=APPROVAL)
    sources = ["machine/tangnano20k/sd_hal.c", "std/tangnano20k/sd.fpr",
               "tests/base/tangnano20k_sd_model.c", "tests/tangnano20k_sd_prepare.fpr",
               "tests/check_tangnano20k_sd_prepare.py"]
    evidence = {"complete": True, "platform": "native production HAL with test-only SPI SDHC model",
                "physical_hardware_access": False, "physical_sd_writes": False,
                "whole_image_read_or_hash": False, "build_command": command,
                "build_log_sha256": small_file_digest(out / "build.log"),
                "binary_sha256": small_file_digest(binary),
                "sources": {name: small_file_digest(ROOT / name) for name in sources},
                "inspected_card": {"blocks": BLOCKS, "cid": CID, "csd": CSD,
                                   "original_mbr_sha256": digest(ORIGINAL_MBR)},
                "expected_written_blocks_in_order": WRITE_ORDER, "cases": results}
    (out / "results.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print("FP SD PREPARE MODEL HOLDS: 6 cases; only sparse regular-file writes", flush=True)


if __name__ == "__main__":
    main()
