#!/usr/bin/env python3
"""Run production FP-RISC SD/FAT code against disposable SPI card images.

No FPGA, serial port or physical disk is accessed. Native execution links
the production 84-line HAL with register callbacks from the test model.
FAT image construction and post-run inspection are independent Python.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = b"FP-RISC on-card file roundtrip\n0123456789abcdefghijklmnopqrstuvwxyz\n"
KEEP = b"Existing user file: must remain byte-identical.\x00\xff\x80\n"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def put16(data, at, value):
    struct.pack_into("<H", data, at, value)


def put32(data, at, value):
    struct.pack_into("<I", data, at, value)


def entry(name, cluster, size):
    result = bytearray(32)
    result[:11] = name
    result[11] = 0x20
    put16(result, 20, cluster >> 16)
    put16(result, 26, cluster & 65535)
    put32(result, 28, size)
    return result


def image(path, bits=16, *, partitioned=True, variant="normal"):
    start = 2048 if partitioned else 0
    total = 16384 if bits == 16 else 131072
    reserved = 1 if bits == 16 else 32
    fat_size = 64 if bits == 16 else 1024
    root_sectors = 32 if bits == 16 else 0
    first_data = start + reserved + 2 * fat_size + root_sectors
    root_sector = start + reserved + 2 * fat_size if bits == 16 else first_data
    keep_cluster = 2 if bits == 16 else 3
    card_blocks = start + total
    data = bytearray(card_blocks * 512)
    # A nonzero reserved partition gap ensures an erroneous raw scratch write
    # cannot pass unnoticed. The first sector is replaced by the real MBR.
    if start:
        data[:start * 512] = b"\xa5" * (start * 512)
        mbr = bytearray(512)
        mbr[446 + 4] = 0x06 if bits == 16 else 0x0c
        put32(mbr, 446 + 8, start)
        put32(mbr, 446 + 12, total)
        mbr[510:512] = b"\x55\xaa"
        data[:512] = mbr
    boot = bytearray(512)
    boot[:3] = b"\xeb\x3c\x90"
    boot[3:11] = b"FPRMODEL"
    put16(boot, 11, 512)
    boot[13] = 1
    put16(boot, 14, reserved)
    boot[16] = 2
    put16(boot, 17, 512 if bits == 16 else 0)
    put16(boot, 19, total if total < 65536 else 0)
    boot[21] = 0xf8
    put16(boot, 22, fat_size if bits == 16 else 0)
    put16(boot, 24, 63)
    put16(boot, 26, 255)
    put32(boot, 28, start)
    put32(boot, 32, total if total >= 65536 else 0)
    if bits == 32:
        put32(boot, 36, fat_size)
        put32(boot, 44, 2)
        put16(boot, 48, 1)
        put16(boot, 50, 6)
        boot[64] = 0x80
        boot[66] = 0x29
        boot[71:82] = b"FP RISC SD "
        boot[82:90] = b"FAT32   "
    else:
        boot[36] = 0x80
        boot[38] = 0x29
        boot[43:54] = b"FP RISC SD "
        boot[54:62] = b"FAT16   "
    boot[510:512] = b"\x55\xaa"
    if variant == "capacity":
        put16(boot, 19, 0)
        put32(boot, 32, card_blocks + 4096)
    data[start * 512:(start + 1) * 512] = boot
    if bits == 32:
        data[(start + 6) * 512:(start + 7) * 512] = boot
        fsinfo = bytearray(512)
        put32(fsinfo, 0, 0x41615252)
        put32(fsinfo, 484, 0x61417272)
        # Valid cached values must be invalidated in both primary and backup
        # copies when the driver allocates a fresh cluster.
        put32(fsinfo, 488, total - (reserved + 2 * fat_size) - 2)
        put32(fsinfo, 492, 4)
        put32(fsinfo, 508, 0xaa550000)
        data[(start + 1) * 512:(start + 2) * 512] = fsinfo
        data[(start + 7) * 512:(start + 8) * 512] = fsinfo
    fat = bytearray(fat_size * 512)
    if variant == "full-fat":
        fat[:] = b"\xff" * len(fat)
    if bits == 16:
        put16(fat, 0, 0xfff8)
        put16(fat, 2, 0xffff)
        put16(fat, keep_cluster * 2, 0xffff)
    else:
        put32(fat, 0, 0x0ffffff8)
        put32(fat, 4, 0x0fffffff)
        put32(fat, 8, 0x0fffffff)
        put32(fat, keep_cluster * 4, 0x0fffffff)
    if variant == "dirty":
        if bits == 16:
            put16(fat, 2, 0x7fff)
        else:
            put32(fat, 4, 0x07ffffff)
    if variant == "root-free":
        assert bits == 32
        put32(fat, 8, 0)
    if variant == "root-later-free":
        assert bits == 32
        put32(fat, 8, 4)
        put32(fat, 16, 0)
    if variant == "root-cycle":
        assert bits == 32
        put32(fat, 8, 2)
    for copy in range(2):
        at = (start + reserved + copy * fat_size) * 512
        data[at:at + len(fat)] = fat
    data[root_sector * 512:root_sector * 512 + 32] = entry(b"KEEP    TXT", keep_cluster, len(KEEP))
    if variant == "full-root":
        count = root_sectors * 16 if bits == 16 else 16
        for index in range(1, count):
            name = f"E{index:07d}".encode() + b"TXT"
            at = root_sector * 512 + index * 32
            data[at:at + 32] = entry(name, 0, 0)
    keep_at = (first_data + keep_cluster - 2) * 512
    data[keep_at:keep_at + len(KEEP)] = KEEP
    if variant == "unsupported":
        # Keep the real partition map, replace its type and superblock with
        # Linux/ext-like signatures. There is deliberately no writable FAT.
        if start:
            data[446 + 4] = 0x83
        data[start * 512:(start + 1) * 512] = bytes(512)
        data[(start + 2) * 512 + 56:(start + 2) * 512 + 58] = b"\x53\xef"
    if variant in ("mixed", "overlap", "overlap-bpb", "bad-other-entry"):
        assert start
        at = 462
        data[at + 4] = 0x83
        if variant == "mixed":
            put32(data, at + 8, 64)
            put32(data, at + 12, 512)
        elif variant == "bad-other-entry":
            put32(data, at + 8, card_blocks - 16)
            put32(data, at + 12, 32)
        else:
            put32(data, at + 8, start + 16)
            put32(data, at + 12, 512)
        if variant == "overlap-bpb":
            # A plausible sector-zero BPB must not bypass a nonempty MBR's
            # overlap checks. The old BPB heuristic would mount it at LBA0.
            data[11:90] = boot[11:90]
    path.write_bytes(data)
    return {"bits": bits, "start": start, "total": total, "reserved": reserved,
            "fat_size": fat_size, "root": root_sector, "first_data": first_data,
            "keep_cluster": keep_cluster, "keep_at": keep_at}


def inspect_file(path, layout, original):
    data = path.read_bytes()
    root = data[layout["root"] * 512:(layout["root"] + 1) * 512]
    found = [root[i:i + 32] for i in range(0, 512, 32)
             if root[i:i + 11] == b"FPRTEST TXT"]
    assert len(found) == 1, "new 8.3 directory entry missing or duplicated"
    item = found[0]
    cluster = struct.unpack_from("<H", item, 26)[0] | (struct.unpack_from("<H", item, 20)[0] << 16)
    size = struct.unpack_from("<I", item, 28)[0]
    assert item[11] == 0x20 and size == len(PAYLOAD), (item, size)
    assert cluster >= 2 and cluster != layout["keep_cluster"]
    offset = (layout["first_data"] + cluster - 2) * 512
    assert data[offset:offset + 512] == PAYLOAD + bytes(512 - len(PAYLOAD))
    expected = bytearray(original)
    expected[offset:offset + 512] = data[offset:offset + 512]
    root_at = layout["root"] * 512 + 32
    assert data[root_at:root_at + 32] == item, "file did not use first free root slot"
    expected[root_at:root_at + 32] = item
    fats = []
    for copy in range(2):
        at = (layout["start"] + layout["reserved"] + copy * layout["fat_size"]) * 512
        fats.append(data[at:at + layout["fat_size"] * 512])
        width = 2 if layout["bits"] == 16 else 4
        entry_at = at + cluster * width
        expected[entry_at:entry_at + width] = data[entry_at:entry_at + width]
    assert fats[0] == fats[1], "mirrored FAT copies differ"
    if layout["bits"] == 16:
        value = struct.unpack_from("<H", fats[0], cluster * 2)[0]
        assert value >= 0xfff8, value
    else:
        value = struct.unpack_from("<I", fats[0], cluster * 4)[0] & 0xfffffff
        assert value >= 0xffffff8, value
        for sector in (layout["start"] + 1, layout["start"] + 7):
            at = sector * 512 + 488
            assert data[at:at + 8] == b"\xff" * 8, "stale FAT32 FSInfo allocation hints"
            assert original[at:at + 8] != data[at:at + 8], "fixture must exercise cached FSInfo invalidation"
            expected[at:at + 8] = b"\xff" * 8
    assert data[layout["keep_at"]:layout["keep_at"] + len(KEEP)] == KEEP
    assert expected == data, "create modified bytes beyond its new file, allocation entries and FSInfo hints"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/tangnano20k-sd-model")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    binary = out / "sd-model"
    build_env = {**os.environ, "XDG_CACHE_HOME": os.environ.get("XDG_CACHE_HOME", str(out / "cache"))}
    build = subprocess.run([str(ROOT / "fpr"), "build", "tests/tangnano20k_sd_model.fpr",
                            "--harts", "1", "--with", "machine/tangnano20k/sd_hal.c",
                            "--with", "tests/base/tangnano20k_sd_model.c",
                            "--cflag", "-DFPR_SD_HAL_TEST", "-o", str(binary)],
                           cwd=ROOT, env=build_env, text=True, capture_output=True, timeout=240)
    (out / "build.log").write_text(build.stdout + build.stderr)
    assert build.returncode == 0, build.stdout + build.stderr
    rv32 = subprocess.run([str(ROOT / "fprc"), "--system=bare-metal", "--profile=base",
                            "--target=rv32", "tests/tangnano20k_sd_model.fpr", str(out / "rv32.s")],
                           cwd=ROOT, env=build_env, text=True, capture_output=True, timeout=240)
    (out / "rv32-compile.log").write_text(rv32.stdout + rv32.stderr)
    assert rv32.returncode == 0, rv32.stdout + rv32.stderr
    results = []

    def run(name, path, mode, fault="none", *, unchanged=False):
        before = sha(path)
        log = out / (name + ".json")
        env = {**os.environ, "FPR_HARTS": "1", "FPR_HEAP_MB": "64",
               "FPR_SD_IMAGE": str(path), "FPR_SD_CASE": mode,
               "FPR_SD_FAULT": fault, "FPR_SD_MODEL_LOG": str(log)}
        proc = subprocess.run([str(binary)], cwd=ROOT, env=env, text=True,
                              capture_output=True, timeout=120)
        output = proc.stdout + proc.stderr
        (out / (name + ".log")).write_text(output)
        assert proc.returncode == 0 and "SD MODEL HOLDS " + mode in output, (name, proc.returncode, output)
        stats = json.loads(log.read_text())
        assert stats["crc_errors"] == 0 and stats["commands_before_clock_train"] == 0, (name, stats)
        after = sha(path)
        if unchanged:
            assert before == after and stats["writes"] == 0, (name, stats)
        results.append({"name": name, "mode": mode, "fault": fault,
                        "output": output, "image_before": before,
                        "image_after": after, "stats": stats, "passed": True})
        (out / "results.json").write_text(json.dumps({"complete": False, "cases": results}, indent=2) + "\n")
        print(name + ": PASS", flush=True)
        return stats

    for bits, partitioned, variant in [(16, True, "normal"), (16, False, "normal"),
                                      (32, True, "normal"), (16, True, "mixed")]:
        label = f"fat{bits}" + ("-mbr" if partitioned else "-superfloppy")
        if variant != "normal":
            label += "-" + variant
        path = out / (label + ".img")
        layout = image(path, bits, partitioned=partitioned, variant=variant)
        original = path.read_bytes()
        stats = run(label + "-create", path, "roundtrip")
        assert stats["writes"] >= 4 and stats["commands"].get("13", 0) >= 4, stats
        assert all(layout["start"] <= block < layout["start"] + layout["total"]
                   for block in stats["written_blocks"]), stats
        inspect_file(path, layout, original)
        updated = path.read_bytes()
        assert updated[:layout["start"] * 512] == original[:layout["start"] * 512]
        run(label + "-reopen", path, "verify", unchanged=True)
        run(label + "-collision", path, "collision", unchanged=True)
        run(label + "-names", path, "names", unchanged=True)
    path = out / "faults.img"
    image(path)
    run("bounds", path, "bounds", unchanged=True)
    for fault in ("missing", "spi-timeout", "cmd8", "init-timeout"):
        run(fault, path, "open-error", fault, unchanged=True)
    for fault in ("read-token", "read-crc", "read-timeout"):
        run(fault, path, "read-error", fault, unchanged=True)
    run("write-reject", path, "write-error", "write-reject", unchanged=True)
    # Failed busy/status responses have uncertain completion: the model may
    # have programmed the supplied original sector, and bytes must match.
    for fault in ("write-busy", "status"):
        before = sha(path)
        run(fault, path, "write-error", fault)
        assert sha(path) == before
    for variant in ("unsupported", "capacity", "full-root", "full-fat", "dirty"):
        image(path, variant=variant)
        run(variant, path, "mount-error" if variant in ("unsupported", "capacity") else "create-error", unchanged=True)
    for variant in ("overlap", "overlap-bpb", "bad-other-entry"):
        image(path, variant=variant)
        run(variant, path, "mount-error", unchanged=True)
    for variant in ("root-free", "root-later-free", "root-cycle"):
        image(path, bits=32, variant=variant)
        run(variant, path, "create-error", unchanged=True)
    sources = ["machine/tangnano20k/sd_hal.c", "std/tangnano20k/sd.fpr", "std/tangnano20k/fat.fpr",
               "tests/base/tangnano20k_sd_model.c", "tests/tangnano20k_sd_model.fpr", "tests/check_tangnano20k_sd.py"]
    (out / "results.json").write_text(json.dumps({"complete": True, "platform": "native SPI SDHC model",
      "binary_sha256": sha(binary), "rv32_compilation": True,
      "sources": {name: sha(ROOT / name) for name in sources},
      "cases": results}, indent=2) + "\n")


if __name__ == "__main__":
    main()
