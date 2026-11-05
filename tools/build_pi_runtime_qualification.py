#!/usr/bin/env python3
"""Build an immutable Linux ARM64 runtime qualification bundle for a QOS Pi.

Run inside the ARM64 builder, after compiling fpr. This does not install or
execute anything on the device. Imported fixtures are the host-qualified ones.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--runner-source", type=Path, required=True)
    ap.add_argument("--rounds", type=int, default=256)
    ap.add_argument("--repetitions", type=int, default=3)
    selection = ap.add_mutually_exclusive_group()
    selection.add_argument("--imported-carrier-only",action="store_true",help="qualify constructors and adapters from separately emitted wrappers")
    selection.add_argument("--carrier-only", action="store_true", help="qualify private scalar values across imported container APIs")
    selection.add_argument("--fields-only", action="store_true", help="qualify embedded scalar fields in shared aggregates")
    selection.add_argument("--storage-only", action="store_true", help="run persistent list storage qualification")
    selection.add_argument("--variant-only", action="store_true", help="run the scalar variant qualification slice")
    selection.add_argument("--transport-only", action="store_true", help="run the Base forwarding qualification slice")
    ap.add_argument("--cross-cc", help="Linux ARM64 cross compiler on another build host")
    a = ap.parse_args()
    assert a.rounds >= 64 and a.repetitions >= 1
    root = a.root.resolve()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(root / "tests"))
    import check_scheduler_latency as sched
    import check_unary_return_lifetimes as life
    import check_nested_base_returns as nested
    import check_base_transport as transport
    import check_base_variant_returns as sums

    import check_base_stored_lists as stored
    import check_base_stored_fields as fields
    import check_base_carrier as carrier
    import check_imported_carriers as imported

    focused = "imported-carrier" if a.imported_carrier_only else "base-carrier" if a.carrier_only else "base-fields" if a.fields_only else "base-storage" if a.storage_only else "base-variant" if a.variant_only else "base-transport" if a.transport_only else None

    assert sched.ROOT == root
    env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
    env.update(
        FPR_HOME=str(root), FPR_PATH=str(root), XDG_CACHE_HOME=str(out / "cache")
    )

    def checked(cmd, extra=None):
        return subprocess.run(
            list(map(str, cmd)),
            cwd=root,
            env=dict(env, **(extra or {})),
            check=True,
            text=True,
            capture_output=True,
        )

    driver = a.cross_cc or "cc"
    # Linux AArch64 actors migrate between threads with the hart in x28.
    # A cross driver can accept -ffixed-x28 yet still allocate it. Force
    # live integers across an opaque call and inspect the emitted registers.
    pressure = out / "hart-registers.c"
    values = ["v" + str(i) for i in range(20)]
    pressure.write_text("extern void opaque(void);\nunsigned long pressure(volatile unsigned long *p) {\n"
                        + "".join(f"  unsigned long {v} = *p++;\n" for v in values)
                        + "  opaque();\n"
                        + "".join(f'  asm volatile ("" : "+r" ({v}));\n' for v in values)
                        + "  return " + " ^ ".join(values) + ";\n}\n")
    asm = pressure.with_suffix(".s")
    checked([driver, "-O2", "-ffixed-x27", "-ffixed-x28", "-S", pressure, "-o", asm])
    instructions = [line.split("//")[0] for line in asm.read_text().splitlines()
                    if line.startswith("\t") and not line.lstrip().startswith(".")]
    if re.search(r"\b[wx]2[78]\b", "\n".join(instructions)):
        raise SystemExit("Linux ARM64 C compiler used reserved x27/x28; check the cross compiler target features")
    checked([driver, "-O2", "-Wall", "-Wextra", a.runner_source, "-o", out / "runner"])
    cc = out / "probe-cc"
    cc.write_text(
        '#!/bin/sh\nexec ' + shlex.quote(driver) + ' -DFPR_SCHED_PROBE "$@"\n'
    )
    cc.chmod(0o755)
    cases = []
    binaries = {}
    storage_symbols = {}
    sources = {}

    def build(name, source, switches, probe=False, hal=None):
        src = out / (name + ".fpr")
        src.write_text(source)
        exe = out / name
        cmd = [root / "fpr", "build", src, "--harts", "4", "-o", exe]
        if a.cross_cc:
            cmd += ["--target=linux-aarch64"]
        if probe or a.cross_cc:
            cmd += ["--cc", cc if probe else driver]
        if hal:
            cmd += ["--with", hal]
        checked(cmd, switches)
        symbols = checked(["nm" if not a.cross_cc else "llvm-nm", exe]).stdout
        assert bool(re.search(r"\b_?fpr_sched_probe$", symbols, re.M)) == probe
        storage_symbols[name] = re.findall(r"\b(fpr_fn__x24(?:worker_x2estorage|carrier)_x2e\w+)$", symbols, re.M)
        header = exe.read_bytes()[:20]
        assert (
            header[:6] == b"\x7fELF\x02\x01"
            and int.from_bytes(header[18:20], "little") == 183
        ), name
        binaries[name] = digest(exe)
        sources[src.name] = digest(src)
        print(name, "built", flush=True)
        return name

    for shape, variant, switches in sched.VARIANTS:
        if focused and shape != focused:
            continue
        for probe in (False, True):
            name = build(
                shape + "-" + variant + ("-probe" if probe else "-plain"),
                sched.source(shape, a.rounds),
                switches,
                probe,
                sched.HAL,
            )
            if shape == "imported-carrier":
                adapters=[n for n in storage_symbols[name] if "_x2epack_x40" in n and "_x24at_x2eroot" in n]
                assert len(adapters)==int(variant=="default"),(name,adapters)
            if shape == "base-carrier":
                assert ("fpr_fn__x24carrier_x2e6_x2eMeters_x2efill" in storage_symbols[name]) == (variant == "default")
            if shape == "base-fields":
                assert ("fpr_fn__x24worker_x2estorage_x2eaggregate_x2emake" in storage_symbols[name]) == (variant == "default")
            if shape == "base-storage":
                assert ("fpr_fn__x24worker_x2estorage_x2elist_x2ebuildCells" in storage_symbols[name]) == (variant == "default")
            for harts, route in ((1, "local"), (4, "local"), (4, "remote")):
                for count, load in ((0, "zero"), (1, "one"), (8, "eight")):
                    for rep in range(1 if probe else a.repetitions):
                        cases.append(
                            dict(
                                kind="scheduler",
                                binary=name,
                                args=[route, load],
                                harts=harts,
                                shape=shape,
                                variant=variant,
                                probe=probe,
                                competitors=count,
                                route=route,
                                repetition=rep,
                                timeout=60,
                            )
                        )
    def language_cases(kind, label, source, switches, normal, enabled, checks, allocations=None, hal=None, allocated_bytes=None):
        build(label, source, switches, hal=hal)
        if kind=="imported-carrier" and allocations is not None:
            assert any("_x24at_x2eroot" in n for n in storage_symbols[label])==enabled,label
        if kind == "base-carrier" and allocations is not None:
            assert ("fpr_fn__x24carrier_x2e6_x2eMeters_x2efill" in storage_symbols[label]) == enabled
        if kind == "base-fields" and allocations is not None:
            for worker in ("aggregate_x2emake", "read_x2escore"):
                assert ("fpr_fn__x24worker_x2estorage_x2e"+worker in storage_symbols[label]) == enabled
        if kind == "base-storage" and allocations is not None:
            for worker in ("list_x2ebuild", "read_x2etotal"):
                assert ("fpr_fn__x24worker_x2estorage_x2e"+worker in storage_symbols[label]) == enabled
        for harts in (1, 4):
            for case, args, output, trap in checks:
                row = dict(kind=kind, binary=label, args=args, case=case, harts=harts,
                           normal_inline=normal, isolated=allocations is not None, enabled=enabled,
                           timeout=60, expected_stdout=output, expected_exit=int(bool(trap)), trap=trap)
                if allocations is not None:
                    row["expected_allocations"] = allocations
                    if allocated_bytes is not None:
                        row["expected_allocated_bytes"] = allocated_bytes
                    if kind == "base-fields":
                        row["expected_allocated_bytes"] = 49104 if enabled else 81840
                    if kind == "base-storage":
                        row["expected_allocated_bytes"] = 32 * allocations
                cases.append(row)

    map_counts = {(True, True): (5625, 343584), (True, False): (6137, 359968), (False, True): (5624, 351728), (False, False): (6136, 368112)}
    for normal in (False, True):
        for isolated in (False, True):
            for enabled in (False, True):
                switches = {}
                if not normal:
                    switches["FPR_NO_INLINE"] = "1"
                if not enabled:
                    switches["FPR_NO_PAIR_RETURNS"] = "1"
                if isolated:
                    switches.update(
                        FPR_NO_LOOP_REGIONS="1",
                        FPR_NO_CALL_REGIONS="1",
                        FPR_COST_PROBE="1",
                        FPR_COST_REPORT="1",
                    )
                transport_switches = dict(switches)
                transport_switches.pop("FPR_NO_PAIR_RETURNS", None)
                if not enabled:
                    transport_switches["FPR_NO_TYPE_SPEC"] = "1"
                suffix = f"{int(normal)}-{int(isolated)}-{int(enabled)}"
                if focused in (None, "base-transport"):
                    if isolated:
                        program = transport.HEADER + transport.FOLDS + "main = print (foldCell 1000 0 + foldPair 1000 0 + walk 3 11).\n"
                        checks = [("allocation", [], "1502511\n", None)]
                    else:
                        program = transport.HEADER + transport.CONTROL
                        checks = [(case, [case], output, {"division": "division by zero", "overflow": "Int overflow"}.get(failure))
                                  for case, (output, failure) in transport.CASES.items()]
                    language_cases("base-transport", "transport-"+suffix, program, transport_switches,
                                   normal, enabled, checks, (0 if enabled else 2000) if isolated else None)
                if focused in (None, "base-variant"):
                    if isolated:
                        program = sums.workload(1000)
                        checks = [("allocation", [], "0\n", None)]
                    else:
                        program = sums.DECLARATIONS + sums.MAIN
                        checks = [(case, [case], output, trap) for case, (output, trap) in sums.CASES.items()]
                        language_cases("base-variant", "active-region-"+suffix, sums.REGION, transport_switches,
                                       normal, enabled, [("active-region", [], "1\n", None)], hal=root/"tests/base/variant_region.c")
                    language_cases("base-variant", "variant-"+suffix, program, transport_switches, normal, enabled,
                                   checks, (0 if enabled else 1000) if isolated else None)
                if focused in (None,"imported-carrier"):
                    if isolated:
                        for form in ("constructor","api",*(["explicit"] if enabled else [])):
                            tag="imported-carrier-explicit" if form=="explicit" else "imported-carrier"
                            count,extent=map_counts[normal,enabled]
                            language_cases(tag,"import-"+form+"-"+suffix,
                                           imported.bundled(imported.workload(form)+imported.MAIN),transport_switches,
                                           normal,enabled,[(form,[],"262656\n",None)],count,allocated_bytes=extent)
                    else:
                        checks=[(k,[k],out,trap) for k,(out,trap) in imported.CASES.items()]
                        language_cases("imported-carrier","import-effects-"+suffix,imported.bundled(imported.CONTROL),
                                       transport_switches,normal,enabled,checks)
                        language_cases("imported-carrier","import-arena-"+suffix,imported.bundled(imported.REGIONAL),
                                       dict(transport_switches,FPR_LAYOUT_CHECK="1"),normal,enabled,
                                       [("arena",[],"1\n",None)],hal=imported.HAL)
                if focused in (None, "base-carrier"):
                    if isolated:
                        # Isolate map storage from command-line argument parsing.
                        program = carrier.workload() + "main = print (check 512).\n"
                        language_cases("base-carrier","map-"+suffix,program,transport_switches,normal,enabled,
                                       [("allocation",[],"262656\n",None)],map_counts[normal,enabled][0],
                                       allocated_bytes=map_counts[normal,enabled][1])
                        if enabled:
                            language_cases("base-carrier-explicit","map-explicit-"+suffix,
                                           carrier.workload(True)+"main = print (check 512).\n",transport_switches,
                                           normal,enabled,[("explicit",[],"262656\n",None)],map_counts[normal,True][0],
                                           allocated_bytes=map_counts[normal,True][1])
                    else:
                        language_cases("base-carrier","map-region-"+suffix,carrier.REGIONAL,
                                       dict(transport_switches,FPR_NO_LOOP_REGIONS="1",FPR_LAYOUT_CHECK="1"),normal,enabled,
                                       [("arena-copy",[],"1\n",None)],hal=root/"tests/base/carrier_region.c")
                        checks=[(k,[k],out,trap) for k,(out,trap) in carrier.CASES.items()]
                        language_cases("base-carrier","map-controls-"+suffix,carrier.CONTROL,transport_switches,
                                       normal,enabled,checks)
                if focused in (None, "base-fields"):
                    if isolated:
                        result = fields.oracle(10, 1)
                        language_cases("base-fields","tree-"+suffix,fields.DECL+fields.TREE+fields.MAIN,
                                       transport_switches,normal,enabled,[("tree",[],f"{result}\n{result+7}\n",None)],
                                       1023 if enabled else 2046)
                    else:
                        language_cases("base-fields","tree-region-"+suffix,fields.REGIONAL,
                                       dict(transport_switches,FPR_NO_LOOP_REGIONS="1",FPR_LAYOUT_CHECK="1"),normal,enabled,
                                       [("active-region",[],"16382\n",None)],hal=stored.SYSTEM)
                        checks = [(case,[case],output,trap) for case,(output,trap) in fields.CASES.items()]
                        language_cases("base-fields","fields-"+suffix,fields.DECL+fields.TREE+fields.CASES_SOURCE,
                                       transport_switches,normal,enabled,checks)
                if focused in (None, "base-storage"):
                    if isolated:
                        for form, result in [("scalar-wrapper","500511\n500517\n"),("variant-list","511\n517\n")]:
                            language_cases("base-storage", form+"-"+suffix, stored.forms()[form], transport_switches,
                                           normal, enabled, [(form, [], result, None)], 1000 if enabled else 2000)
                    else:
                        tests = [(case,[case],output,trap) for case,(output,trap) in stored.CASES.items()]
                        language_cases("base-storage","storage-"+suffix,stored.SOURCE+stored.MAIN,transport_switches,
                                       normal,enabled,tests)
                        regional = dict(transport_switches, FPR_NO_LOOP_REGIONS="1")
                        language_cases("base-storage","shared-region-"+suffix,stored.REGIONAL,regional,normal,enabled,
                                       [("shared-region",[],"12000\n",None)],hal=stored.SYSTEM)
                        if normal:
                            checked_mode = dict(transport_switches,FPR_LAYOUT_CHECK="1",FPR_COMPACT_CELLS=str(int(enabled)))
                            language_cases("base-storage","spines-"+suffix,stored.WALKERS,checked_mode,normal,enabled,
                                           [("deep",["deep"],"1\n",None),("widths",["widths"],"4\n",None)],hal=stored.SYSTEM)
                if focused:
                    continue
                name = build(
                    f"lifetime-{int(normal)}-{int(isolated)}-{int(enabled)}",
                    life.SOURCE,
                    switches,
                )
                for harts in (1, 4):
                    cases.append(
                        dict(
                            kind="lifetime",
                            binary=name,
                            args=[],
                            harts=harts,
                            normal_inline=normal,
                            isolated=isolated,
                            enabled=enabled,
                            timeout=60,
                        )
                    )
                nested_name = build(
                    f"nested-{int(normal)}-{int(isolated)}-{int(enabled)}",
                    nested.fixture(),
                    switches,
                )
                for harts in (1, 4):
                    for case, expected in nested.answers().items():
                        trap = {
                            "division": "division by zero",
                            "overflow": "Int overflow",
                            "underflow": "Int overflow",
                        }.get(case)
                        cases.append(
                            dict(
                                kind="nested-return",
                                binary=nested_name,
                                args=[case],
                                case=case,
                                harts=harts,
                                normal_inline=normal,
                                isolated=isolated,
                                enabled=enabled,
                                timeout=60,
                                expected_stdout=expected,
                                expected_exit=1 if trap else 0,
                                trap=trap,
                            )
                        )
    for harts in (1, 4):
        cases.append(
            dict(
                kind="watchdog",
                binary=(focused or "scalar")+"-default-plain",
                args=["stall"],
                harts=harts,
                timeout=3,
            )
        )
    binaries["runner"] = digest(out / "runner")
    record = dict(
        schema="pi-runtime-qualification-bundle-v1",
        compiler_sha256=digest(root / "fpr"),
        hart_register_probe_sha256=digest(asm),
        c_compiler=checked([driver, "--version"]).stdout.splitlines()[0],
        cross_wrapper_sha256=digest(Path(a.cross_cc)) if a.cross_cc else None,
        rounds=a.rounds,
        repetitions=a.repetitions,
        lifetime_expected=life.EXPECTED,
        lifetime_wrappers=(life.COUNT + 1) * (life.CHURN + 1),
        binaries=binaries,
        storage_symbols={name: values for name, values in storage_symbols.items() if values},
        sources=sources,
        fixtures={
            str(p.relative_to(root)): digest(p)
            for p in [
                root / "tests/check_scheduler_latency.py",
                root / "tests/check_unary_return_lifetimes.py",
                root / "tests/check_nested_base_returns.py",
                root / "tests/check_base_transport.py",
                root / "tests/check_base_variant_returns.py",
                root / "tests/base/variant_region.c",
                root / "tests/check_base_stored_lists.py",
                root / "tests/check_base_stored_fields.py",
                root / "tests/check_base_carrier.py",
                root / "tests/check_imported_carriers.py", imported.MODULE,
                root / "tests/base/carrier_region.c",
                stored.SYSTEM,
                sched.HAL,
            ]
        },
        runtime_sha256={
            str(p.relative_to(root)): digest(p)
            for p in sorted((root / "runtime").glob("*"))
            if p.is_file()
        },
        runner_source_sha256=digest(a.runner_source),
        builder_sha256=digest(Path(__file__)),
        nested_allocation_removals={} if focused else {
            "pairs": 3 * nested.COUNT,
            "cells": 2 * nested.COUNT,
            "eight": 3,
            "nine": 1,
        },
        cases=cases,
    )
    (out / "manifest.json").write_text(json.dumps(record, indent=2) + "\n")
    print(
        "Built", len(binaries), "binaries and", len(cases), "physical cases", flush=True
    )


if __name__ == "__main__":
    main()
