"""Build an external FP-RISC Builtin program using the active ESP-IDF environment."""
import argparse
import os
import re
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--build-dir", type=Path, help="override the per-app build directory")
    parser.add_argument("--flash", action="store_true", help="build an OTA-slot application image")
    parser.add_argument("--files", metavar="PARTITION", help="enable SPIFFS on this partition label")
    args = parser.parse_args()
    source = args.source.resolve()
    if not source.is_file():
        parser.error(f"missing FP-RISC source {source}")
    if args.files is not None and not re.fullmatch(r"[A-Za-z0-9_.-]{1,16}", args.files):
        parser.error("use a SPIFFS partition label of 1 to 16 letters, digits, dots, underscores or hyphens")
    idf = os.environ.get("IDF_PATH")
    if not idf:
        parser.error("activate the ESP-IDF environment first")
    board = Path(__file__).resolve().parent
    mode = "flash" if args.flash else "ram"
    configuration = f"{mode}-{args.files}" if args.files else mode
    build = (args.build_dir or source.parent / "build" / source.stem / configuration).resolve()
    subprocess.run([
        sys.executable, str(Path(idf) / "tools" / "idf.py"), "-C", str(board), "-B", str(build),
        f"-DSDKCONFIG={build / 'sdkconfig'}", f"-DFPR_PROGRAM={source}",
        f"-DFPR_FLASH_BOOT={'ON' if args.flash else 'OFF'}",
        f"-DFPR_FLASH_FILES={'ON' if args.files else 'OFF'}",
        f"-DFPR_FLASH_LABEL={args.files or 'fprfiles'}", "build",
    ], check=True)
    print(build / "c3_builtin.bin")


if __name__ == "__main__":
    main()
