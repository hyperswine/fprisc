"""Hosted macOS probe. Pass paths to fixed_state, parse_digits scan-off and scan-on."""
import re
import statistics
import subprocess
import sys
import time


def measure(exe, args, expected):
    times, peaks = [], []
    for _ in range(3):
        start = time.monotonic()
        p = subprocess.run(["/usr/bin/time", "-l", exe, *args], text=True,
                           capture_output=True, check=True, timeout=60)
        times.append(time.monotonic() - start)
        assert p.stdout.strip() == str(expected), (args, p.stdout, expected)
        peaks.append(int(re.search(r"(\d+)\s+maximum resident set size", p.stderr)[1]))
    print(*args, f"{statistics.median(times):.3f}s",
          f"{statistics.median(peaks) / 2**20:.1f} MiB")


if __name__ == "__main__":
    state, off, on = sys.argv[1:]
    for steps in (0, 64, 512, 2048):
        for mode in ("plain", "region", "owned"):
            measure(state, [mode, str(steps)], 2048 * (2047 + 2 * steps) // 2)
    for flag, exe in enumerate((off, on)):
        print("string scan flag", flag)
        for mode in ("option", "raw"):
            for digits, count, value in (("", 1, 0), ("0x", 3, -1), ("12345678", 2000000, 36)):
                measure(exe, [mode, digits, str(count)], value * count)
