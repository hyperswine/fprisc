#!/usr/bin/env python3
"""Build an immutable Linux ARM64 runtime qualification bundle for a QOS Pi.

Run inside the ARM64 builder, after compiling fpr. This does not install or
execute anything on the device. Imported fixtures are the host-qualified ones.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys


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

    driver = a.cross_cc or "cc"
    # Linux AArch64 actors migrate between threads with the hart in x28.
    # A cross driver can accept -ffixed-x28 yet still allocate it. Force
    # live integers across an opaque call and inspect the emitted registers.
    asm = out / "hart-registers.s"
    case_specs = []
    builds = []

    def build(name, source, switches, hal=None, expectations=()):
        builds.append([name, source, switches.copy(), "plain", str(hal or ""), expectations])
        return name

    scheduler = [
        [shape, variant, sched.WORK["scalar" if shape == "copy" else shape], switches, str(sched.HAL)]
        for shape, variant, switches in sched.VARIANTS if not focused or shape == focused
    ]

    def language_cases(kind, label, source, switches, normal, enabled, checks, allocations=None, hal=None, allocated_bytes=None):
        expectations = ("language", kind, "enabled" if enabled else "disabled") if allocations is not None else ()
        build(label, source, switches, hal=hal, expectations=expectations)
        spec = [kind, label, normal, enabled, allocations, allocated_bytes, checks]
        case_specs.append(spec)

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
                case_specs.append(["lifetime", name, normal, isolated, enabled])
                nested_name = build(
                    f"nested-{int(normal)}-{int(isolated)}-{int(enabled)}",
                    nested.fixture(),
                    switches,
                )
                case_specs.append(["nested-return", nested_name, normal, isolated, enabled, nested.answers()])
    case_specs.append(["watchdog", focused or "scalar"])
    fixtures = [
        "tests/check_scheduler_latency.py", "tests/check_unary_return_lifetimes.py",
        "tests/check_nested_base_returns.py", "tests/check_base_transport.py",
        "tests/check_base_variant_returns.py", "tests/base/variant_region.c",
        "tests/check_base_stored_lists.py", "tests/check_base_stored_fields.py",
        "tests/check_base_carrier.py", "tests/check_imported_carriers.py",
        str(imported.MODULE.relative_to(root)), "tests/base/carrier_region.c",
        str(stored.SYSTEM.relative_to(root)), str(sched.HAL.relative_to(root)),
    ]
    plan = dict(
        files=dict(compiler_sha256=root / "fpr", hart_register_probe_sha256=asm,
                   runner_source_sha256=a.runner_source, builder_sha256=Path(__file__),
                   cross_wrapper_sha256=Path(a.cross_cc) if a.cross_cc else None),
        fixtures=fixtures,
        compiler=driver, scheduler=scheduler, cases=case_specs, builds=builds, root=root, out=out,
        mode="cross" if a.cross_cc else "native",
        metadata=dict(
            rounds=a.rounds,
            repetitions=a.repetitions,
            lifetime_expected=life.EXPECTED,
            lifetime_wrappers=(life.COUNT + 1) * (life.CHURN + 1),
            nested_allocation_removals={} if focused else {
                "pairs": 3 * nested.COUNT,
                "cells": 2 * nested.COUNT,
                "eight": 3,
                "nine": 1,
            },
        ),
    )
    with tempfile.TemporaryDirectory(dir=out) as scratch:
        plan_path = Path(scratch) / "bundle.json"
        plan_path.write_text(json.dumps(plan, default=lambda path: str(path.resolve()), ensure_ascii=False))
        subprocess.run([os.environ.get("SOL", "sol"), root / "tools/pi-qualification-build.sol",
                        plan_path, out / "manifest.json"], cwd=root, env=env, check=True)


if __name__ == "__main__":
    main()
