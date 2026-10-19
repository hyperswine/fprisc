#!/usr/bin/env python3
"""Independently decode the clock experiment's read-only SD sector evidence.

This tool never opens a serial port or physical disk. It compares a console
log against the retained, previously verified 48 MHz audit sectors. Only the
new file's one FAT entry, one root entry, and one data sector may differ in
the inspected sectors. Linux preservation is a two-superblock-sector sample,
not a claim that the entire Linux partition was reread.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]
BEFORE = ROOT / "build/tangnano20k-sd/audit"
START = 120913920
OLD = b"FP-RISC Tang Nano 20K SD file\nI32 + SPI + FAT in FP-RISC\n\x00\xff\n"
NEW = bytes((i * 73 + 19) % 256 for i in range(512))
BLOCKS = (0, 8194, 8195, START, START + 1, START + 129,
          START + 257, START + 289, START + 290)
MARKER = "FP SD CLOCK INDEPENDENT SECTOR AUDIT HOLDS"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def baseline(before):
    evidence = json.loads((before / "results.json").read_text())
    require(evidence.get("passed") is True, "baseline audit did not pass")
    sectors = {}
    for block in BLOCKS[:-1]:
        value = (before / f"sector-{block}.bin").read_bytes()
        require(len(value) == 512, f"baseline sector {block} length")
        require(sha(value) == evidence["sector_sha256"][str(block)],
                f"baseline sector {block} hash does not match its retained evidence")
        sectors[block] = value
    return sectors


def parse(text, *, require_board_exit):
    require(MARKER + "\n" in text, "audit completion marker missing")
    if require_board_exit:
        require(MARKER + "\nFPR EXIT 0\nDONE\n" in text,
                "physical audit lacks successful runtime exit and ROM DONE")
    card = re.findall(r"^SD CLOCK AUDIT CARD SDABC BLOCKS 122152960 DIVIDER (\d+)$", text, re.M)
    require(len(card) == 1, "card identity or divider evidence missing/duplicated")
    sectors = {}
    for line in text.splitlines():
        if not line.startswith("SD CLOCK AUDIT ") or line.startswith("SD CLOCK AUDIT CARD "):
            continue
        found = re.fullmatch(r"SD CLOCK AUDIT (\d+) ([0-9a-f]{1024})", line)
        require(found is not None, "malformed sector evidence")
        block = int(found[1])
        require(block not in sectors, f"duplicate sector {block}")
        sectors[block] = bytes.fromhex(found[2])
    require(set(sectors) == set(BLOCKS), "audit sector set incomplete or unexpected")
    return sectors, int(card[0])


def inspect(sectors, original):
    for block in (0, 8194, 8195, START, START + 289):
        require(sectors[block] == original[block], f"preserved sector {block} changed")
    mbr = sectors[0]
    require(mbr[510:] == b"\x55\xaa", "MBR signature")
    require(mbr[450] == 0x83 and struct.unpack_from("<II", mbr, 454) == (8192, 120905728),
            "original Linux partition bounds changed")
    require(mbr[466] == 6 and struct.unpack_from("<II", mbr, 470) == (START, 32768),
            "FAT16 test partition bounds changed")
    boot = sectors[START]
    require(boot[510:] == b"\x55\xaa" and struct.unpack_from("<H", boot, 11)[0] == 512,
            "FAT16 boot signature or bytes per sector")
    require(boot[13] == 1 and struct.unpack_from("<H", boot, 14)[0] == 1 and boot[16] == 2,
            "FAT16 cluster/reserved/FAT geometry")
    require(struct.unpack_from("<H", boot, 17)[0] == 512 and
            struct.unpack_from("<H", boot, 19)[0] == 32768 and
            struct.unpack_from("<H", boot, 22)[0] == 128 and
            struct.unpack_from("<I", boot, 28)[0] == START, "FAT16 root/partition geometry")
    expected_fat = bytearray(original[START + 1])
    require(expected_fat == original[START + 129] and
            struct.unpack_from("<HHH", expected_fat) == (0xfff8, 0xffff, 0xffff) and
            expected_fat[6:] == bytes(506), "baseline allocation differs")
    struct.pack_into("<H", expected_fat, 6, 0xffff)
    require(sectors[START + 1] == expected_fat and sectors[START + 129] == expected_fat,
            "mirrored FAT sectors differ or changed beyond new cluster 3")
    root = sectors[START + 257]
    require(root[:32] == original[START + 257][:32], "old directory entry changed")
    require(root[:11] == b"FPRTEST TXT" and root[11] == 0x20 and
            struct.unpack_from("<H", root, 20)[0] == 0 and
            struct.unpack_from("<HI", root, 26) == (2, len(OLD)), "old directory metadata")
    expected_entry = bytearray(32)
    expected_entry[:11] = b"CLKTEST BIN"
    expected_entry[11] = 0x20
    struct.pack_into("<HI", expected_entry, 26, 3, 512)
    require(root[32:64] == expected_entry and root[64:] == original[START + 257][64:],
            "new root entry differs or unrelated directory bytes changed")
    require(sectors[START + 289] == OLD + bytes(512 - len(OLD)), "original binary payload/padding")
    require(sectors[START + 290] == NEW, "new 512-byte binary payload differs")
    return {"passed": True, "files": {
                "FPRTEST.TXT": {"bytes": len(OLD), "cluster": 2, "payload_sha256": sha(OLD)},
                "CLKTEST.BIN": {"bytes": 512, "cluster": 3, "payload_sha256": sha(NEW)}},
            "mbr_identical": True, "fat16_boot_identical": True,
            "linux_superblock_sample_identical": [8194, 8195],
            "inspected_fat_copy_sectors_identical": [START + 1, START + 129],
            "root_changes_confined_to_new_entry": True,
            "sector_sha256": {str(k): sha(v) for k, v in sectors.items()}}


def synthetic(original):
    sectors = dict(original)
    for block in (START + 1, START + 129):
        value = bytearray(sectors[block])
        struct.pack_into("<H", value, 6, 0xffff)
        sectors[block] = bytes(value)
    root = bytearray(sectors[START + 257])
    root[32:43] = b"CLKTEST BIN"
    root[43] = 0x20
    struct.pack_into("<HI", root, 58, 3, 512)
    sectors[START + 257] = bytes(root)
    sectors[START + 290] = NEW
    return sectors


def self_test(original):
    sectors = synthetic(original)
    inspect(sectors, original)
    text = "SD CLOCK AUDIT CARD SDABC BLOCKS 122152960 DIVIDER 17\n"
    text += "".join(f"SD CLOCK AUDIT {block} {value.hex()}\n" for block, value in sectors.items())
    text += MARKER + "\nFPR EXIT 0\nDONE\n"
    parsed, divider = parse(text, require_board_exit=True)
    require(parsed == sectors and divider == 17, "console roundtrip")
    cases = []
    for block, offset in ((0, 450), (8194, 56), (8195, 100), (START, 19),
                          (START + 1, 8), (START + 129, 6), (START + 257, 0),
                          (START + 257, 58), (START + 257, 64),
                          (START + 289, 0), (START + 289, 100), (START + 290, 511)):
        broken = dict(sectors)
        value = bytearray(broken[block]);value[offset] ^= 1;broken[block] = bytes(value)
        try:
            inspect(broken, original)
        except ValueError:
            cases.append(f"sector-{block}-byte-{offset}")
        else:
            raise ValueError(f"failed to reject mutation at {block}:{offset}")
    for name, broken in (("missing-DONE", text.replace("DONE\n", "")),
                         ("guest-failure", text.replace("FPR EXIT 0", "FPR EXIT 1")),
                         ("duplicate-sector", text + f"SD CLOCK AUDIT 0 {sectors[0].hex()}\n"),
                         ("missing-sector", text.replace(f"SD CLOCK AUDIT 8195 {sectors[8195].hex()}\n", ""))):
        try:
            parse(broken, require_board_exit=True)
        except ValueError:
            cases.append(name)
        else:
            raise ValueError(f"failed to reject {name}")
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, default=BEFORE)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--native", action="store_true", help="native model log: omit FPGA EXIT/DONE requirement")
    parser.add_argument("--self-test", action="store_true", help="offline parser and byte-mutation checks only")
    args = parser.parse_args()
    original = baseline(args.before.resolve())
    if args.self_test:
        cases = self_test(original)
        print(f"PASS: offline clock audit and {len(cases)} independent corruption/refusal checks")
        if not args.log:
            return
    if not args.log:
        parser.error("--log is required unless --self-test")
    sectors, divider = parse(args.log.read_text(), require_board_exit=not args.native)
    result = inspect(sectors, original)
    result.update({"platform": "native SPI model" if args.native else "physical FPGA console",
                   "divider": divider, "log_sha256": sha(args.log.read_bytes()),
                   "baseline": str(args.before.resolve())})
    if args.out:
        out = args.out.resolve()
        require(out != args.before.resolve(), "output must not overwrite the retained baseline audit")
        out.mkdir(parents=True, exist_ok=True)
        (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        for block, value in sectors.items():
            (out / f"sector-{block}.bin").write_bytes(value)
    print("PASS: both binary files, independent FAT/root decoding, unchanged MBR/boot and Linux superblock samples")


if __name__ == "__main__":
    main()
