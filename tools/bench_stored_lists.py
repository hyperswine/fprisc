#!/usr/bin/env python3
"""Compare private persistent storage with equivalent explicit layouts and tagged fallbacks."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from bench_hosted_worker_admission import ROOT, measure, time_families

sys.path.insert(0,str(ROOT/"tests"))
from check_base_stored_lists import forms
import check_base_stored_fields as fields
import check_base_carrier as carrier
import check_imported_carriers as imported


def repeated(source, repeat, copy=False):
    prefix=source[:source.index("main = ")]
    first="keep xs" if copy else "xs"
    return prefix + f"""once k = xs = build k; a = total ({first}) 0; total xs a.
loop r acc = if r <= 0 then acc else loop (r - 1) (acc+once (999 + r % 2)).
main = print (loop {repeat} 0).
"""


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before",type=Path,required=True)
    parser.add_argument("--before-home",type=Path,required=True,help="matching saved runtime, machine, core and std")
    parser.add_argument("--before-stored", action="store_true", help="the saved compiler already has private list storage")
    parser.add_argument("--family", choices=["scalar","variant","ordinary-copy","tree","map","imported-map"], help="measure a single workload")
    parser.add_argument("--repeats",type=int,default=1600)
    parser.add_argument("--record",type=Path,required=True)
    args=parser.parse_args()
    if args.repeats<2: parser.error("at least two repetitions required")
    sources=forms()
    families=[]
    costs=[]
    for name, high, explicit in [
        ("scalar","scalar-wrapper","scalar-explicit"),
        ("variant","variant-list","variant-explicit"),
        ("ordinary-copy","scalar-explicit","scalar-explicit")]:
        if args.family and args.family!=name: continue
        total = (lambda k: k*(k+1)) if name!="variant" else (lambda k: k if k%2==0 else -(k+1))
        expected=sum(total(999+r%2) for r in range(1,args.repeats+1))
        program=repeated(sources[high],args.repeats,name=="ordinary-copy")
        manual=repeated(sources[explicit],args.repeats,name=="ordinary-copy")
        families.append((name,program,manual,expected,"FPR_NO_TYPE_SPEC"))
    if args.family=="tree":
        repeats=args.repeats
        tail = f"""once d n = t = make d n; a = score t; score t + a.
loop r acc = if r <= 0 then acc else loop (r - 1) (acc + once 10 (1+r % 2)).
main = print (loop {repeats} 0).
"""
        high=fields.DECL+fields.TREE+tail
        explicit=fields.DECL+fields.FLAT+tail
        pair = [2*fields.oracle(10,seed) for seed in (1,2)]
        expected=sum(pair[r%2] for r in range(1,repeats+1))
        families.append(("tree",high,explicit,expected,"FPR_NO_TYPE_SPEC"))
    if args.family in ("map","imported-map"):
        tail = f"""loop r acc = if r <= 0 then acc else loop (r - 1) (acc + check (127+r % 2)).
main = print (loop {args.repeats} 0).
"""
        expected=sum(k*(k+1) for r in range(1,args.repeats+1) for k in [127+r%2])
        if args.family=="imported-map":
            for form in ("api","constructor"):
                families.append(("imported-"+form,imported.bundled(imported.workload(form))+tail,
                                 imported.bundled(imported.workload("explicit"))+tail,expected,"FPR_NO_TYPE_SPEC"))
        else:
            families.append(("map",carrier.workload()+tail,carrier.workload(True)+tail,expected,"FPR_NO_TYPE_SPEC"))
    for family,program,manual,_,rollback in families:
        for form,compiler,src,flags in [("before",args.before,program,{}),("after",ROOT/"fpr",program,{}),
                                         ("explicit",ROOT/"fpr",manual,{}),("rollback",ROOT/"fpr",program,{rollback:"1"})]:
            with tempfile.TemporaryDirectory(prefix="fpr-storage-cost-") as directory:
                row=measure(compiler.resolve(),args.repeats,Path(directory),src,flags)
                row.pop("workers")
                costs.append(dict(family=family,form=form,**row))
    with tempfile.TemporaryDirectory(prefix="fpr-stored-timing-") as d:
        timings=time_families(args.before.resolve(),ROOT/"fpr",Path(d),families,before_home=args.before_home.resolve())
    old_runtime={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((args.before_home/"runtime").iterdir()) if p.is_file()}
    current_runtime={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/"runtime").iterdir()) if p.is_file()}
    args.record.write_text(json.dumps(dict(repeats=args.repeats,before_runtime=old_runtime,
                    current_runtime=current_runtime,compile_cost=costs,throughput=timings),indent=2)+"\n")
    for row in timings:
        if row["family"].startswith("imported-"):
            assert any(".$at.root." in n for n in row["root_workers"])==(row["form"]=="after")
            continue
        if row["family"]=="map":
            assert ("$carrier.6.Meters.fill" in row["root_workers"])==(row["form"]=="after")
            continue
        if row["family"]=="tree":
            assert ("$worker.storage.aggregate.make" in row["root_workers"])==(row["form"]=="after")
            continue
        selected=row["family"]!="ordinary-copy" and (row["form"]=="after" or args.before_stored and row["form"]=="before")
        assert ("$worker.storage.list.build" in row["root_workers"])==selected, row["root_workers"]
    for family in ("scalar","variant","tree","map","imported-api","imported-constructor"):
        alloc={r["form"]:r["cost"]["alloc_requests"] for r in timings if r["family"]==family}
        if not alloc: continue
        assert alloc["after"]<=alloc["explicit"],alloc
        if args.before_stored: assert alloc["after"]==alloc["before"],alloc
        else: assert alloc["after"]<alloc["before"],alloc


if __name__=="__main__":
    main()
