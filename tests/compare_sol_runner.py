"""Compare the ten manifest cases in the Base and Sol runners at one and four workers."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sol", default="sol", help="Sol launcher from the FP-RISC 0.13.1 distribution")
    args = parser.parse_args()
    rows = [line.split("\t") for line in (ROOT / "tests/sol-checks.tsv").read_text().splitlines()]
    cases = [row[0] for row in rows]
    ports = {row[0] for row in rows if len(row) == 3}
    if len(cases) != 10 or len(set(cases)) != 10:
        raise SystemExit("expected ten distinct milestone cases")
    filters = [arg for case in cases for arg in ("--only", case)]
    base = ["python3", "tests/check_base.py", *filters]
    selected = subprocess.check_output([*base, "--list"], cwd=ROOT, text=True).splitlines()
    if selected != cases:
        raise SystemExit(f"Base selected different cases: {selected}")
    with tempfile.TemporaryDirectory(prefix="fpr-runner-parity-") as temp:
        timing = Path(temp) / "base.json"
        for jobs in (1, 4):
            for runner in ("Base", "Sol"):
                cmd = ([*base, "-j", str(jobs), "--timings-json", str(timing)]
                       if runner == "Base" else [args.sol, "tests/run.sol", "--jobs", str(jobs)])
                start = time.monotonic()
                p = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                   env=dict(os.environ, FPR_CHECK_SOL=args.sol))
                if p.returncode:
                    raise SystemExit(f"{runner} -j {jobs} failed ({p.returncode})\n{p.stdout}")
                if runner == "Base":
                    got = [row["name"] for row in json.loads(timing.read_text())["jobs"] if row["status"] == "ok"]
                else:
                    got = [line[5:] for line in p.stdout.splitlines() if line.startswith("PASS ")]
                    lines = p.stdout.splitlines()
                    for case in ports:
                        marker = lines.index(f"PASS {case}")
                        if marker == 0 or not lines[marker - 1] or lines[marker - 1] not in base_lines:
                            raise SystemExit(f"{case}: port summary differs from Python reference")
                if runner == "Base":
                    base_lines = set(p.stdout.splitlines())
                if got != cases:
                    raise SystemExit(f"{runner} -j {jobs}: unexpected successful cases {got}")
                print(f"{runner} -j {jobs}: {len(got)} matched ({time.monotonic()-start:.1f}s)", flush=True)


if __name__ == "__main__":
    main()
