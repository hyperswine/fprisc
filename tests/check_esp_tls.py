#!/usr/bin/env python3
"""ESP-IDF uses actual TLS; bare-metal rv32 retains tp-as-hart.
Compile both in one cache directory, then compile ESP again (warm cache).
Hardware runtime coverage is machine/esp-idf/examples/posix-io.fpr.
"""
from pathlib import Path
import re
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="fpr-esp-tls-") as tmp:
    def compile_(system, name):
        out = Path(tmp) / (name + ".s")
        subprocess.run([str(ROOT / "fpr"), "compile", "--system=" + system,
                        "--target=rv32", "--prelude=" + str(ROOT / "core/prelude.fpr"),
                        str(ROOT / "tests/actors.fpr"), str(out)], cwd=ROOT,
                       check=True, capture_output=True, text=True, timeout=120)
        units = Path(str(out) + ".units").read_text().split()
        text = out.read_text() + "".join(Path(p).read_text() for p in units)
        if system == "esp-idf":
            assert "%tprel_hi(fpr_esp_hart)" in text
            assert "%tprel_add(fpr_esp_hart)" in text
            assert "%tprel_lo(fpr_esp_hart)" in text
            assert not re.search(r"\bmv\s+t0,\s*tp\b", text)
            assert not re.search(r"^\s*(?:mv|lw|addi|lui)\s+tp,", text, re.M)
        else:
            assert re.search(r"\bmv\s+t0,\s*tp\b", text)
            assert "fpr_esp_hart" not in text
        return set(units)
    esp = compile_("esp-idf", "esp")
    bare = compile_("bare-metal", "bare")
    warm = compile_("esp-idf", "warm")
    assert esp == warm and not (esp & bare), "host ABIs share cached units"
print("ESP TLS lowering, unchanged bare-metal ABI and cache isolation: PASS")
