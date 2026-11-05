#!/usr/bin/env python3
"""Run a prebuilt runtime bundle beside an installed QOS session, without deployment.

Uses the user's existing SSH configuration and strict host-key checking. All
remote writes are confined to a fresh /tmp directory. An interrupted transfer
or connection must be investigated using the recorded remote path, never blindly
rerun. The device runner owns timeout, process-group cleanup and child reaping.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import tarfile
import time


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bundle", type=Path, required=True)
    ap.add_argument("--host", required=True)
    ap.add_argument("--output", type=Path, required=True)
    a = ap.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    m = json.loads((a.bundle / "manifest.json").read_text())
    assert m["schema"] == "pi-runtime-qualification-bundle-v1"
    for name, sha in m["binaries"].items():
        assert "/" not in name and digest(a.bundle / name) == sha, name
    ssh = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "IPQoS=none",
        "-o",
        "ServerAliveInterval=10",
        "-o",
        "ServerAliveCountMax=2",
        "root@" + a.host,
    ]

    def remote(command, timeout=30, **kw):
        return subprocess.run([*ssh, command], check=True, timeout=timeout, **kw)

    stamp = str(time.time_ns())
    work = "/tmp/fpr-runtime-qualification-" + stamp
    q = shlex.quote
    start = dict(
        remote_dir=work,
        host=a.host,
        driver_sha256=digest(Path(__file__)),
        bundle_sha256=digest(a.bundle / "manifest.json"),
        scope="Physical Linux ARM64 runtime alongside installed QOS; no deployment or hard realtime admission",
    )
    (a.output / "started.json").write_text(json.dumps(start, indent=2) + "\n")
    metadata = """set -e
cat /proc/device-tree/model
uname -a
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
cat /sys/class/thermal/thermal_zone0/temp
"""
    production = """set -e
cat /var/run/qosp/state
p=$(cat /var/run/qosp/ready)
test -d /proc/$p
printf 'pid=%s\\n' "$p"
sha256sum /usr/bin/qosp /proc/$p/exe
"""
    before = remote(production, capture_output=True).stdout.decode()
    start["production_before"] = before
    start["device_before"] = remote(metadata, capture_output=True).stdout.decode(
        errors="replace"
    )
    (a.output / "started.json").write_text(json.dumps(start, indent=2) + "\n")
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as t:
        for name in [*m["binaries"], "manifest.json"]:
            t.add(a.bundle / name, arcname=name)
    remote(
        "umask 077; mkdir " + q(work) + " && tar xf - -C " + q(work),
        input=archive.getvalue(),
        timeout=180,
    )
    # Validate transferred bytes before executing any candidate code.
    sums = "".join(sha + "  " + name + "\n" for name, sha in m["binaries"].items())
    remote(
        "cd " + q(work) + " && sha256sum -c -", input=sums.encode(), capture_output=True
    )
    lines = [
        "set -eu",
        "cd " + q(work),
        "mkdir results",
        "echo running > status",
        """trap 's=$?; if [ "$s" -ne 0 ]; then echo failed > status; fi' 0""",
    ]
    for i, c in enumerate(m["cases"]):
        env = ["FPR_HARTS=" + str(c["harts"]), "FPR_BLOCK_SPIN_NS=0"]
        if c.get("isolated"):
            env += ["FPR_COST_REPORT=1"]
        cmd = [
            "env",
            *env,
            "./runner",
            str(c["timeout"]),
            "0",
            f"results/{i}.log",
            "./" + c["binary"],
            *c["args"],
        ]
        lines.append(" ".join(map(q, cmd)) + f" > results/{i}.json")
        if c["kind"] != "watchdog":
            expected_exit = c.get("expected_exit", 0)
            lines.append(
                f"""grep -q '"exit":{expected_exit},"signal":0' results/{i}.json"""
            )
            lines.append(f"""grep -q '"timeout":false' results/{i}.json""")
        if i % 50 == 0:
            lines.append(f"echo completed-case-{i}")
    lines += ["echo complete > status", "echo PHYSICAL_EXECUTIONS_COMPLETE"]
    script = "\n".join(lines) + "\n"
    (a.output / "run.sh").write_text(script)
    start["run_script_sha256"] = digest(a.output / "run.sh")
    remote(
        "cat > " + q(work + "/run.sh") + " && echo queued > " + q(work + "/status"),
        input=script.encode(),
    )
    # The watchdog supervisor must survive a dropped SSH connection. Launch
    # once, then poll its status; never repeat the launch on connection failure.
    pid = (
        remote(
            "cd " + q(work) + "; nohup sh run.sh > run.log 2>&1 < /dev/null & echo $!",
            capture_output=True,
        )
        .stdout.decode()
        .strip()
    )
    assert pid.isdigit()
    start["supervisor_pid"] = int(pid)
    (a.output / "started.json").write_text(json.dumps(start, indent=2) + "\n")
    deadline = time.monotonic() + max(7200, len(m["cases"]) * 65)
    while True:
        status = (
            remote("cat " + q(work + "/status"), capture_output=True)
            .stdout.decode()
            .strip()
        )
        if status in ("complete", "failed"):
            break
        assert status in ("queued", "running"), status
        if time.monotonic() > deadline:
            raise TimeoutError(
                "Inspect recorded remote supervisor; launch was not repeated"
            )
        time.sleep(5)
    data = remote(
        "cd " + q(work) + " && tar cf - results status run.log",
        capture_output=True,
        timeout=180,
    ).stdout
    (a.output / "results.tar").write_bytes(data)
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        t.extractall(a.output, filter="data")
    if (a.output / "status").read_text().strip() != "complete":
        (a.output / "failed.json").write_text(
            json.dumps(
                dict(
                    **start,
                    status="FAIL",
                    reason="Remote runner failed; inspect collected telemetry and run.log",
                ),
                indent=2,
            )
            + "\n"
        )
        raise SystemExit("Remote runner failed; results collected")
    after = remote(production, capture_output=True).stdout.decode()
    assert before == after, (before, after)
    start["production_after"] = after
    start["device_after"] = remote(metadata, capture_output=True).stdout.decode(
        errors="replace"
    )
    rows = []
    failures = []
    for i, c in enumerate(m["cases"]):
        telemetry = json.loads((a.output / f"results/{i}.json").read_text())
        log = (a.output / f"results/{i}.log").read_text()
        row = dict(
            index=i,
            **c,
            telemetry=telemetry,
            log_sha256=digest(a.output / f"results/{i}.log"),
        )
        try:
            if c["kind"] == "watchdog":
                assert (
                    telemetry["timeout"]
                    and telemetry["signal"] in (9, 15)
                    and "scheduler stall entered\n" in log
                )
            else:
                assert (
                    telemetry["exit"] == c.get("expected_exit", 0)
                    and telemetry["signal"] == 0
                    and not telemetry["timeout"]
                )
                if c["kind"] == "scheduler":
                    records = []
                    numbers = []
                    for line in log.splitlines():
                        if line.startswith("[fpr sched] "):
                            records.append(json.loads(line[12:]))
                        else:
                            numbers.append(int(line))
                    answer, *times = numbers
                    assert (
                        answer == m["rounds"] * (m["rounds"] + 3) // 2
                        and len(times) == m["rounds"]
                        and min(times) >= 0
                    )
                    if c["probe"]:
                        assert len(records) == c["competitors"] + 2 and len(
                            {r["actor"] for r in records}
                        ) == len(records)
                        hogs = [r for r in records if r["role"] == 1]
                        assert len(hogs) == c["competitors"] and all(
                            r["fuel"] > 0 and r["slots"] > 0 for r in hogs
                        )
                        for role, mask in (
                            (2, 2 if c["route"] == "remote" else 1),
                            (3, 1),
                        ):
                            actors = [r for r in records if r["role"] == role]
                            assert len(actors) == 1 and actors[0]["hart_mask"] == mask
                        assert all(r["hart_mask"] in (1, 2) for r in hogs)
                        if c["route"] == "local":
                            assert all(r["hart_mask"] == 1 for r in hogs)
                        row["probe_actors"] = records
                    else:
                        assert not records
                        row["samples_us"] = times
                        row["over_1ms"] = sum(v > 1000 for v in times)
                        row["max_us"] = max(times)
                else:
                    costs, plain, diagnostics = [], [], []
                    for line in log.splitlines(keepends=True):
                        if line.startswith("[fpr cost] "):
                            costs.append(json.loads(line[11:]))
                        elif c.get("trap") and (
                            line.startswith("[ERR] ")
                            or line.startswith("*** FPRISC PANIC ")
                            or not line.strip()
                        ):
                            diagnostics.append(line)
                        else:
                            plain.append(line)
                    expected = (
                        m["lifetime_expected"] if c["kind"] == "lifetime" else c["expected_stdout"]
                    )
                    assert "".join(plain) == expected
                    if c.get("trap"):
                        assert any(
                            line.startswith("[ERR] ") and c["trap"] in line
                            for line in diagnostics
                        )
                        assert any(
                            line.startswith("*** FPRISC PANIC ") and c["trap"] in line
                            for line in diagnostics
                        )
                        row["diagnostics"] = "".join(diagnostics)
                    else:
                        assert len(costs) == int(c["isolated"])
                    if costs:
                        row["allocations"] = costs[0]["alloc_requests"]
                        row["allocated_bytes"] = costs[0]["alloc_bytes"]
                    if "expected_allocations" in c:
                        assert row.get("allocations") == c["expected_allocations"]
                    if "expected_allocated_bytes" in c:
                        assert row.get("allocated_bytes") == c["expected_allocated_bytes"]
        except (AssertionError, ValueError, KeyError) as e:
            failures.append(dict(index=i, error=repr(e), log=log[-4000:]))
        rows.append(row)
    for harts in {c["harts"] for c in m["cases"] if c["kind"] == "lifetime"}:
        counts = {
            r["enabled"]: r.get("allocations")
            for r in rows
            if r["kind"] == "lifetime"
            and r["isolated"]
            and not r["normal_inline"]
            and r["harts"] == harts
        }
        if (
            None in counts.values()
            or counts.get(False, 0) - counts.get(True, 0) != m["lifetime_wrappers"]
        ):
            failures.append(dict(harts=harts, lifetime_counts=counts))
    nested_rows = [r for r in rows if r["kind"] == "nested-return"]
    for normal in (False, True):
        for harts in (1, 4):
            for case, expected in m.get("nested_allocation_removals", {}).items():
                counts = {
                    r["enabled"]: r.get("allocations")
                    for r in nested_rows
                    if r["case"] == case
                    and r["normal_inline"] == normal
                    and r["isolated"]
                    and r["harts"] == harts
                }
                if (
                    set(counts) != {False, True}
                    or None in counts.values()
                    or counts[False] - counts[True] != expected
                ):
                    failures.append(
                        dict(
                            case=case,
                            harts=harts,
                            normal_inline=normal,
                            allocation_counts=counts,
                        )
                    )
    traps = {}
    for r in rows:
        if r.get("trap"):
            key = r["kind"], r["harts"], r["case"]
            diagnostic = r.get("diagnostics")
            if key in traps and traps[key] != diagnostic:
                failures.append(
                    dict(case=r["case"], harts=r["harts"], reason="trap differential")
                )
            traps[key] = diagnostic
    record = dict(
        **start,
        manifest=m,
        rows=rows,
        failures=failures,
        status="FAIL" if failures else "PASS",
        limitations=[
            "Samples include the installed QOS session and Linux scheduling.",
            "Elapsed maxima and 1 ms threshold are observations, not WCET or static-arena admission.",
            "Instrumented fuel samples and plain latency samples are separate processes.",
        ],
    )
    (a.output / "complete.json").write_text(json.dumps(record, indent=2) + "\n")
    print(
        record["status"],
        len(rows),
        "cases;",
        sum(r.get("over_1ms", 0) for r in rows),
        "replies over 1 ms",
    )
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
