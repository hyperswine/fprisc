#!/usr/bin/env python3
"""Independently inspect the read-only sector dump from the approved card test.

No physical device access. Requires the original probe sectors saved before
the partition change and the final tangnano20k_sd_audit.fpr console log.
"""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/tangnano20k-sd/audit"
BEFORE = ROOT / "build/tangnano20k-sd/probe"
START = 120913920
PAYLOAD = b"FP-RISC Tang Nano 20K SD file\nI32 + SPI + FAT in FP-RISC\n\x00\xff\n"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    text = (OUT / "physical.log").read_text()
    assert "FP SD INDEPENDENT SECTOR AUDIT HOLDS\nFPR EXIT 0\nDONE\n" in text
    sectors = {}
    for line in text.splitlines():
        if not line.startswith("SD AUDIT "):
            continue
        _, _, lba, encoded = line.split()
        data = bytes.fromhex(encoded)
        assert len(data) == 512 and int(lba) not in sectors
        sectors[int(lba)] = data
    expected = {0, 8194, 8195, START, START + 1, START + 129, START + 257, START + 289}
    assert set(sectors) == expected
    original = (BEFORE / "sector-0.bin").read_bytes()
    mbr = sectors[0]
    assert mbr[:462] == original[:462] and mbr[478:] == original[478:]
    assert mbr[466] == 6 and struct.unpack_from("<II", mbr, 470) == (START, 32768)
    for block in (8194, 8195):
        assert sectors[block] == (BEFORE / f"sector-{block}.bin").read_bytes(), "Linux superblock changed"
    boot = sectors[START]
    u16 = lambda at: struct.unpack_from("<H", boot, at)[0]
    assert boot[510:] == b"\x55\xaa" and u16(11) == 512 and boot[13] == 1
    assert u16(14) == 1 and boot[16] == 2 and u16(17) == 512
    assert u16(19) == 32768 and u16(22) == 128
    assert struct.unpack_from("<I", boot, 28)[0] == START
    fat = sectors[START + 1]
    assert fat == sectors[START + 129], "FAT copies differ"
    assert struct.unpack_from("<HHH", fat) == (0xfff8, 0xffff, 0xffff)
    assert fat[6:] == bytes(506), "unexpected allocation in inspected FAT sector"
    root = sectors[START + 257]
    assert root[:11] == b"FPRTEST TXT" and root[11] == 0x20
    assert struct.unpack_from("<H", root, 20)[0] == 0
    assert struct.unpack_from("<HI", root, 26) == (2, len(PAYLOAD))
    assert root[32:] == bytes(480)
    data = sectors[START + 289]
    assert data == PAYLOAD + bytes(512 - len(PAYLOAD)), "binary file payload differs"
    result = {"passed": True, "file": "FPRTEST.TXT", "bytes": len(PAYLOAD),
              "payload_sha256": sha(PAYLOAD), "mbr_only_second_entry_changed": True,
              "linux_superblock_sectors_identical": [8194, 8195],
              "fat_copies_identical": True, "cluster": 2,
              "sector_sha256": {str(k): sha(v) for k, v in sectors.items()}}
    (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    for block, value in sectors.items():
        (OUT / f"sector-{block}.bin").write_bytes(value)
    print("PASS: physical binary file, mirrored FATs, directory, partition bounds and preserved Linux superblock")


if __name__ == "__main__":
    main()
