#!/usr/bin/env python3
"""Measure compiler allocation, root text size and private variant worker counts."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile
import sys

from bench_hosted_worker_admission import ROOT, measure
sys.path.insert(0, str(ROOT/"tests"))


def source(count, explicit):
    definitions = ["unsafe base.", "Choice = Type (PlusCell Int | MinusCell Int)."]
    yes, no = ("(True,x)", "(False,x)") if explicit else ("PlusCell x", "MinusCell x")
    reader = "(t,v) -> if t then v else 0 - v" if explicit else "PlusCell v -> v | MinusCell v -> 0 - v"
    for i in range(count):
        definitions.append(f"choose{i} x = if x < 0 then choose{i} (0 - x) else if x % 2 == 0 then {yes} else {no}.")
        definitions.append(f"read{i} x = case choose{i} x of {reader}.")
    calls = "; ".join(f"_ = print (read{i} {i})" for i in range(count))
    return "\n".join([*definitions, "main = " + calls + "; Unit.", ""])


def storage_source(count, explicit):
    definitions = ["unsafe base.", "Meters = Type (Meters Int)."]
    element = "n" if explicit else "(Meters n)"
    read = "read{i} rest (a+h)" if explicit else "case h of Meters v -> read{i} rest (a+v)"
    for i in range(count):
        definitions.append(f"build{i} n = if n <= 0 then [] else {element} :: build{i} (n - 1).")
        definitions.append(f"read{i} xs a = case xs of [] -> a | h :: rest -> " + read.format(i=i) + ".")
        definitions.append(f"twice{i} n = xs = build{i} n; a = read{i} xs 0; read{i} xs a.")
    calls = "; ".join(f"_ = print (twice{i} 7)" for i in range(count))
    return "\n".join([*definitions, "main = " + calls + "; Unit.", ""])


def field_source(count, explicit):
    from check_base_stored_fields import DECL, TREE, FLAT
    functions = TREE
    definitions = [DECL]
    if explicit:
        declaration, functions = FLAT.split("\n", 1)
        definitions.append(declaration)
    for i in range(count):
        definitions.append(re.sub(r"\b(make|score)\b", lambda m: m[0]+str(i), functions))
        definitions.append(f"twice{i} n = t = make{i} 3 n; a = score{i} t; score{i} t + a.")
    calls = "; ".join(f"_ = print (twice{i} 1)" for i in range(count))
    return "\n".join([*definitions, "main = " + calls + "; Unit.", ""])


def carrier_source(count, explicit, imported=False):
    from check_base_carrier import HEADER, workload
    if imported:
        import check_imported_carriers as external
        header=external.bundled(external.HEADER)
        functions=external.bundled(external.workload("explicit" if explicit else "api")).removeprefix(header)
    else:
        header=HEADER
        functions=workload(explicit).removeprefix(header)
    definitions=[header]
    for i in range(count):
        definitions.append(re.sub(r"\b(fill|check|addValue)\b",lambda m:m[0]+str(i),functions))
    calls="; ".join(f"_ = print (check{i} 3)" for i in range(count))
    return "\n".join([*definitions,"main = "+calls+"; Unit.",""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", required=True, type=Path)
    parser.add_argument("--family", choices=["variants","storage","fields","carrier","imported-carrier"], default="variants")
    parser.add_argument("--sizes", nargs="+", type=int, default=[16, 64, 256])
    args = parser.parse_args()
    if min(args.sizes) <= 0:
        parser.error("sizes must be positive")
    rows = []
    compiler = ROOT / "fpr"
    for count in args.sizes:
        optimized, fixture = {"storage":("storage",storage_source), "fields":("fields",field_source),
                              "imported-carrier":("imported-carrier",lambda n,e:carrier_source(n,e,True)),
                              "carrier":("carrier",carrier_source),"variants":("variant",source)}[args.family]
        for form in (optimized, "explicit", "rollback"):
            flags = {"FPR_NO_INLINE": "1"}
            if form == "rollback":
                flags["FPR_NO_TYPE_SPEC"] = "1"
            with tempfile.TemporaryDirectory(prefix="fpr-variant-scale-") as directory:
                tmp = Path(directory)
                row = measure(compiler, count, tmp, fixture(count, form == "explicit"), flags)
                row.pop("workers")
                assembly = (tmp/"main.s").read_text()
                if args.family=="imported-carrier":
                    names=re.findall(r"^# fn (\$carrier\.\S+\.fill\d+) ",assembly,re.M)
                    readers=re.findall(r"^# fn (\$carrier\.\S+\.addValue\d+) ",assembly,re.M)
                    adapters=re.findall(r"^# fn (\$carrier\.\S+\.\$at\.root\.\S+) ",assembly,re.M)
                    assert len(names)==len(readers) and len(adapters)==(3 if form==optimized else 0)
                    row.update(carrier_producers=len(names),carrier_readers=len(readers),shared_adapters=len(adapters))
                elif args.family=="carrier":
                    names=re.findall(r"^# fn (\$carrier\.6\.Meters\.fill\d+) ",assembly,re.M)
                    readers=re.findall(r"^# fn (\$carrier\.6\.Meters\.addValue\d+) ",assembly,re.M)
                    assert len(names)==len(readers)
                    row.update(carrier_producers=len(names),carrier_readers=len(readers))
                elif args.family in ("storage","fields"):
                    producer, reader = (r"aggregate\.make","score") if args.family=="fields" else (r"list\.build","read")
                    names=re.findall(r"^# fn (\$worker\.storage\."+producer+r"\d+) ",assembly,re.M)
                    readers=re.findall(r"^# fn (\$worker\.storage\.read\."+reader+r"\d+) ",assembly,re.M)
                    assert len(readers)==len(names), (len(readers),len(names))
                    row.update(storage_producers=len(names),storage_readers=len(readers))
                else:
                    names=re.findall(r"^# fn (\$worker\.ret2\.\$variant\.choose\d+) ",assembly,re.M)
                    row["variant_workers"]=len(names)
                assert len(names)==(count if form==optimized else 0),(count,form,names)
                rows.append(dict(form=form,**row))
                print(count, form, row["allocated_bytes"], row["text_bytes"], len(names), flush=True)
    args.record.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(),
                                            rows=rows), indent=2) + "\n")


if __name__ == "__main__":
    main()
