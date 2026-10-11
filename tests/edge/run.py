#!/usr/bin/env python3
"""tests/edge/run.py -- the edge-case battery (docs/2026-10-11-EDGE-CASES.md).

Not a pass/fail suite: every probe is built and run under a timeout and
its outcome recorded, so a change in behaviour is visible as a diff of
the two result files.  `python3 tests/edge/run.py` runs the runtime probes
(probes.json: one program each, some with a shell suffix or environment),
`--src` feeds the malformed and extreme sources in src/ to the compiler.
Results land in /tmp/fpr-edge/.
"""
import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FPR = os.path.join(ROOT, "fpr")
OUT = "/tmp/fpr-edge"
os.makedirs(OUT, exist_ok=True)

def sh(cmd, timeout, env=None):
    t0 = time.time()
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout, env=env, executable="/bin/bash")
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), round(time.time() - t0, 2)
    except subprocess.TimeoutExpired as ex:
        return "TIMEOUT", (ex.stdout or b"").decode("utf-8", "replace"), (ex.stderr or b"").decode("utf-8", "replace"), round(time.time() - t0, 2)

def runtime():
    probes = json.load(open(os.path.join(HERE, "probes.json")))
    results = {}
    for name, p in probes.items():
        out = f"{OUT}/bin_{name}"
        rc, so, se, dt = sh(f"{FPR} build {HERE}/{name}.fpr -o {out}", 300)
        r = {"note": p["note"], "build_rc": rc, "build_s": dt}
        if rc != 0:
            r["build_err"] = (so + se).strip()[-600:]; results[name] = r; print(name, "BUILD", rc, flush=True); continue
        env = dict(os.environ); runs = []
        if name == "env_harts":
            for k, v in (("FPR_HARTS", "0"), ("FPR_HARTS", "abc"), ("FPR_HARTS", "999"), ("FPR_HEAP_MB", "0"), ("FPR_STACK_MAX_MB", "0")):
                e2 = dict(env); e2[k] = v; rc, so, se, dt = sh(out, 20, env=e2); runs.append((f"{k}={v}", rc, so[-400:], se[-400:], dt))
        elif name == "env_bigenv":
            e2 = dict(env); e2["BIG"] = "x" * 1000000; rc, so, se, dt = sh(out, 20, env=e2); runs.append(("BIG=1MB", rc, so[-400:], se[-400:], dt))
        else:
            run = p["run"]
            if run.startswith("timeout "): t = int(run.split()[1]); cmd = out
            elif run.startswith("&"): t = 60; cmd = f"{out} {run}; echo exit=$?"
            else: t = 25; cmd = f"{out} {run}"
            rc, so, se, dt = sh(cmd, t, env=env); runs.append((run or "-", rc, so[-600:], se[-600:], dt))
        r["runs"] = runs; results[name] = r
        print(name, "OK" if all(x[1] == 0 for x in runs) else [x[1] for x in runs], flush=True)
    json.dump(results, open(f"{OUT}/results_runtime.json", "w"), indent=1)

def sources():
    notes = json.load(open(os.path.join(HERE, "src", "notes.json"))); results = {}
    for name in notes:
        rc, so, se, dt = sh(f"{FPR} build {HERE}/src/{name}.fpr -o {OUT}/srcbin_{name}", 300)
        txt = so + se
        uncaught = any(k in txt for k in ("CallStack", "hGetContents", "Prelude.", "Non-exhaustive"))
        run = None
        if rc == 0:
            q = sh(f"{OUT}/srcbin_{name}", 20); run = (q[0], q[1][-300:], q[2][-300:])
        results[name] = {"note": notes[name], "rc": rc, "s": dt, "uncaught": uncaught, "msg": txt.strip()[-500:], "run": run}
        print(name, rc, dt, "UNCAUGHT" if uncaught else "", flush=True)
    json.dump(results, open(f"{OUT}/results_src.json", "w"), indent=1)

if __name__ == "__main__":
    (sources if "--src" in sys.argv else runtime)()
