#!/usr/bin/env python3
"""Benchmark-only cc wrapper: retain aligned/paired A64 assembly copies.

Set FPR_CC to this file and FPR_BENCH_ASM_DIR to a fresh output directory.
FPR_BENCH_ALIGN=64 aligns function entries; FPR_BENCH_PAIRS=1 pairs the
exact frame-link saves/restores. Never edits compiler output or unit caches.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def transform(source, alignment, pairs):
    saves = restores = 0
    if pairs:
        def pair_save(m):
            nonlocal saves
            high, low = map(int, m.groups())
            if high != low + 8 or low % 8 or not -512 <= low <= 504:
                return m[0]
            saves += 1
            return f"    stp x29, x30, [sp, #{low}]\n"
        source = re.sub(r"^    stur x30, \[sp, #(-?\d+)\]\n"
                        r"    stur x29, \[sp, #(-?\d+)\]\n",
                        pair_save, source, flags=re.M)
        # Copy the old frame address before loading its saved caller FP.
        # Exact match excludes epilogues with intervening register restores.
        source, restores = re.subn(
            r"^    ldur x30, \[x29, #-8\]\n    mov x9, x29\n"
            r"    ldur x29, \[x29, #-16\]\n    mov sp, x9\n",
            "    mov x9, x29\n    ldp x29, x30, [x9, #-16]\n    mov sp, x9\n",
            source, flags=re.M)
    aligned = 0
    if alignment:
        source, aligned = re.subn(r"^(_?fpr_(?:u?fn)_\S+:)$",
                                  f"    .balign {alignment}\n\\1", source, flags=re.M)
    return source, {"paired_saves": saves, "paired_restores": restores, "aligned_entries": aligned}


def main():
    args = sys.argv[1:]
    directory = Path(os.environ["FPR_BENCH_ASM_DIR"])
    directory.mkdir(parents=True, exist_ok=True)
    alignment = int(os.environ.get("FPR_BENCH_ALIGN", "0"))
    assert alignment in (0, 16, 32, 64, 128)
    pairs = os.environ.get("FPR_BENCH_PAIRS") == "1"
    records = []
    for i, arg in enumerate(args):
        path = Path(arg)
        if path.suffix != ".s" or not path.is_file():
            continue
        original = path.read_text()
        transformed, counts = transform(original, alignment, pairs)
        name = hashlib.sha256(str(path.resolve()).encode()).hexdigest()[:12] + "-" + path.name
        target = directory / name
        target.write_text(transformed)
        args[i] = str(target)
        records.append({"source": str(path), "copy": str(target), **counts,
                        "before_sha256": hashlib.sha256(original.encode()).hexdigest(),
                        "after_sha256": hashlib.sha256(transformed.encode()).hexdigest()})
    if records:
        (directory / f"link-{os.getpid()}.json").write_text(json.dumps(records, indent=2) + "\n")
    sys.exit(subprocess.run(["cc", *args]).returncode)


if __name__ == "__main__":
    main()
