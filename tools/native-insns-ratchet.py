#!/usr/bin/env python3
"""Audit complete typed emission and ratchet native-insns-v1 per-function bounds.

This is a compiler regression gate, not an elapsed-time admission certificate.
Runtime call sites are ratcheted separately; their costs and interprocedural
call/return composition are not bounded by these per-function reports.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ARCH = {"rv32":"rv32", "rv64":"rv64", "qrv64":"rv64", "x64":"x64", "qx64":"x64",
        "a64":"a64", "a64mac":"a64", "qa64":"a64", "qa64single":"a64", "qa64mac":"a64"}
HEADER = re.compile(r"# fn (\S+) \(arity ([0-9]+)\) typed-ir (rv32|rv64|a64|x64) .+")
REPORT = re.compile(r"# native-insns-v1: (\S+) segmax=([0-9]+) exittail=([0-9]+) ccalls=([0-9]+)")
LABEL = re.compile(r"_?(fpr_(?:fn_|vspec_|tkfn_|ufn_)\S*):")

class Refused(ValueError):
    pass

def symbol(name):
    if name.startswith('$vkernel:'):
        return name[len('$vkernel:'):]
    return 'fpr_fn_' + ''.join(c if c.isascii() and c.isalnum() else '_x'+format(ord(c),'02x') for c in name)

def audit_file(path, arch, allow_empty=False):
    text = path.read_text()
    if not text.startswith('# typed IR: no translation\n'):
        raise Refused(f'{path}: emission is not entirely typed')
    functions, labels, current = {}, set(), None
    for number, line in enumerate(text.splitlines(),1):
        where = f'{path}:{number}'
        if line.startswith('# fn '):
            if current is not None:
                raise Refused(f'{where}: missing native report for {current}')
            h = HEADER.fullmatch(line)
            if not h or h[3]!=arch:
                raise Refused(f'{where}: malformed or wrong-target function header')
            current = h[1]
            if current in functions:
                raise Refused(f'{where}: duplicate function {current}')
            functions[current] = None
        elif line.startswith('# native-insns'):
            r = REPORT.fullmatch(line)
            if not r or current is None or r[1]!=current:
                raise Refused(f'{where}: absent, duplicate, malformed or UNBOUNDED native report')
            if symbol(current) not in labels:
                raise Refused(f'{where}: native report precedes its function symbol')
            seg,tail,calls = map(int,r.group(2,3,4))
            if tail>seg:
                raise Refused(f'{where}: exit tail exceeds segment bound')
            functions[current] = {'name':current,'segmax':seg,'exittail':tail,'ccalls':calls}
            current = None
        elif line.startswith('# wcet:') or line.startswith('# unboxed clone'):
            raise Refused(f'{where}: legacy code or bound in native admission input')
        label = LABEL.fullmatch(line)
        if label:
            if current is None or label[1]!=symbol(current):
                raise Refused(f'{where}: generated function without its native header')
            if label[1] in labels:
                raise Refused(f'{where}: duplicate generated function symbol {label[1]}')
            labels.add(label[1])
    if current is not None:
        raise Refused(f'{path}: missing native report for {current}')
    if not functions and not allow_empty:
        raise Refused(f'{path}: no native functions')
    expected = {symbol(n) for n in functions}
    if labels!=expected:
        raise Refused(f'{path}: function/header coverage mismatch; missing={sorted(expected-labels)[:3]}, unreported={sorted(labels-expected)[:3]}')
    return {'path':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'functions':len(functions)}, list(functions.values())

def audit(root, target):
    root = Path(root).resolve()
    # The compiler writes the full linked-unit closure here, one path per line.
    # Requiring the manifest avoids quietly accepting root-only coverage.
    manifest = Path(str(root)+'.units')
    units = manifest.read_text().splitlines()
    if any(not u.strip() or u!=u.strip() for u in units):
        raise Refused(f'{manifest}: blank or whitespace-padded unit path')
    files = [root]+[(Path(u) if Path(u).is_absolute() else root.parent/u).resolve() for u in units]
    if len(set(files))!=len(files):
        raise Refused(f'{manifest}: duplicate or self-referencing unit path')
    evidence,rows = [],[]
    for path in files:
        file_info,functions = audit_file(path,ARCH[target],allow_empty=(path!=root))
        evidence.append(file_info)
        rows.extend(dict(f,file=str(path)) for f in functions)
    return {'metric':'native-insns-v1','scope':'per-function selected segments over root plus every linked unit',
            'target':target,'files':evidence,'functions':len(rows),
            'segmax':max(r['segmax'] for r in rows),'exittail_max':max(r['exittail'] for r in rows),
            'runtime_call_sites_max_per_function':max(r['ccalls'] for r in rows),
            'runtime_call_sites_total':sum(r['ccalls'] for r in rows),
            'runtime_time_bound':'unprovided','call_return_composition':'unprovided',
            'elapsed_time_certificate':False,
            'worst_segments':sorted(rows,key=lambda r:(-r['segmax'],r['name']))[:8],
            'worst_runtime_call_sites':sorted(rows,key=lambda r:(-r['ccalls'],r['name']))[:8]}

def positive(value):
    if not re.fullmatch(r'[0-9]+',value):
        raise argparse.ArgumentTypeError('expected a nonnegative integer')
    return int(value)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('program',type=Path)
    ap.add_argument('ceiling',type=positive)
    ap.add_argument('target',choices=ARCH,nargs='?',default='rv64')
    ap.add_argument('--runtime-call-sites-ceiling',type=positive,required=True,
                    help='maximum static runtime call sites in any one function; not their time cost')
    ap.add_argument('--assembly',action='store_true',help='audit program as saved assembly plus its required .units manifest')
    ap.add_argument('--json-output',type=Path)
    args = ap.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix='fpr-native-insns-') as temp:
            if args.assembly:
                asm = args.program
                compiler_info = None
            else:
                asm = Path(temp)/'program.s'
                env = dict(os.environ,FPR_TYPED_IR_BACKEND='mixed',FPR_TYPED_IR_STRICT='all',LC_ALL='C.UTF-8')
                cmd = [str(ROOT/'fprc'),'--target='+args.target,'--prelude='+str(ROOT/'core/prelude.fpr'),str(args.program.resolve()),str(asm)]
                result = subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=600)
                if result.returncode:
                    raise Refused('compile failed\n'+'\n'.join((result.stdout+result.stderr).splitlines()[-12:]))
                compiler_info = {'path':str(ROOT/'fpr'),'sha256':hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest()}
            report = audit(asm,args.target)
            report.update(compiler=compiler_info,source=str(args.program.resolve()),
                          ceiling=args.ceiling,runtime_call_sites_ceiling=args.runtime_call_sites_ceiling)
            failures = []
            if report['segmax']>args.ceiling:
                failures.append(f"segment {report['segmax']} > ceiling {args.ceiling}")
            if report['runtime_call_sites_max_per_function']>args.runtime_call_sites_ceiling:
                failures.append(f"runtime call sites {report['runtime_call_sites_max_per_function']} > ceiling {args.runtime_call_sites_ceiling}")
            report['result'] = 'FAIL' if failures else 'PASS'
            if args.json_output:
                args.json_output.write_text(json.dumps(report,indent=2)+'\n')
            if failures:
                raise Refused('; '.join(failures))
            print(f"native-insns-v1 ratchet holds: {report['segmax']} <= {args.ceiling} target instructions per function segment ({args.target}, {report['functions']} functions, {len(report['files'])} files)")
            print(f"runtime call sites: max/function {report['runtime_call_sites_max_per_function']} <= {args.runtime_call_sites_ceiling}; total {report['runtime_call_sites_total']}; runtime time bound and call/return composition unprovided")
    except (OSError,ValueError,subprocess.SubprocessError) as e:
        if args.json_output:
            try:
                args.json_output.write_text(json.dumps({'metric':'native-insns-v1','result':'FAIL','error':str(e)},indent=2)+'\n')
            except OSError as output_error:
                print('native-insns-v1 ratchet: cannot record failure: '+str(output_error),file=sys.stderr)
        print('native-insns-v1 ratchet: REFUSED: '+str(e),file=sys.stderr)
        return 1
    return 0

if __name__=='__main__':
    sys.exit(main())
