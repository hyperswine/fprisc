#!/usr/bin/env python3
"""Stage-1 hosted library calls, format contracts, and explicit compatibility gaps."""
import csv
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT / 'fpr')).resolve()

def main():
    count = 0
    env = {k:v for k,v in os.environ.items() if not k.startswith('SOL_') and k != 'GHCRTS'}
    with tempfile.TemporaryDirectory(prefix='sol-library-check-') as tmp:
        w = Path(tmp); env.update(SOL_JIT='0', SOL_GPU='0', SOL_TABLE='0', SOL_CACHE_DIR=str(w/'cache'))
        def run(source, expected=None, code=0, error=None, extra=None, script=None, args=()):
            nonlocal count
            p=w/'main.sol';p.write_text(source)
            r=subprocess.run([str(FPR),'sol',str(script or p),*args],env=env | (extra or {}),capture_output=True,timeout=30)
            assert r.returncode==code and (expected is None or r.stdout==expected), (source,r)
            if error: assert error in r.stderr,(source,r)
            elif code==0: assert not r.stderr,(source,r.stderr)
            count+=1;return r.stdout
        def lib(name, body): return f'L = use "{ROOT}/sol/lib/{name}.sol".\n{body}\n'
        calls={
          'base':('> print (L.removeAt 2 [1,2,3]).', b'[1, 3]\n'),
          'csv':('> print (L.records [["name"],["Ada"]]).', b'[[(name, Ada)]]\n'),
          'fix':('> print (L.toInt (L.fmul (L.fromInt 3) (L.fromInt 4))).', b'12\n'),
          'git':('> print (L.rawSpec ["status"] (L.repo "dir with spaces")).', b'ProcessSpec [git, -C, dir with spaces, status]  []  0\n'),
          'json':('> print (L.parse "true" |>? L.bool).', b'Ok True\n'),
          'logic':('> print (L.runQuery [] L.symsInit [] 0 [] 10).', b'([true], 10)\n'),
          'matrix':('> m = L.M.fromRows [[1,2],[3,4]]; (r,c,m2) = L.M.dims m; u = L.M.free m2; print (r,c).', b'(2, 2)\n'),
          'plot':('> print (Str.contains "<svg" (L.P.line "demo" [(0,0),(1,1)])).', b'True\n'),
          'plparse':('> (db,qs,syms) = L.loadProgram ["likes alice bob.", "> likes alice bob ?"]; print (List.len db, List.len qs).', b'(1, 1)\n'),
          'proc':('> print (L.output (Ok (ProcessResult 0 "done" ""))).', b'Ok done\n'),
          'rand':('> print (L.Rand.next 1).', b'1103527590\n'),
          'ui':('> print (L.text "ok" == L.Txt "ok").', b'True\n'),
          'web':('> v = L.text "ok"; print v.text.', b'ok\n'),
        }
        catalog = json.loads((ROOT/'tools/sol-library-capabilities.json').read_text())
        assert catalog['schema'] == 1
        declared = {Path(row['module']).stem for row in catalog['modules'] if row['module'].startswith('sol/lib/')}
        assert declared == set(calls) | {'auth'} == {p.stem for p in (ROOT/'sol/lib').glob('*.sol')}
        for name,(body,expected) in calls.items():
            run(lib(name,'> print "loaded".'), b'loaded\n')
            run(lib(name,body), expected)
        # auth is an app helper: generic record updates require the app's shape.
        run(lib('auth','model = {user = Persistent "demo", pendu = "", pendp = "", note = ""}.\n> print (L.unwrapU model).'), b'demo\n')
        run(lib('auth','> print "loaded".'), code=1, error=b'no record shape has fields')
        for name,body,expected in [
          ('map','L.entries (L.insert "b" 2 (L.insert "a" 1 L.strings))',b'[(a, 1), (b, 2)]\n'),
          ('set','L.member "a" (L.insert "a" L.strings)',b'True\n'),
          ('list','L.reverse [1,2,3]',b'[3, 2, 1]\n'),
          ('string','L.trim \" x \"',b'x\n'),
          ('path','L.normalize "/a/../b"',b'/b\n')]:
            run(f'L = use "{ROOT}/std/{name}.fpr".\n> print ({body}).',expected)
        # Explicitly catalogued hosted gaps: signatures alone are not support.
        for name,call,symbol in [('dir','L.list "."',b'Os.listDir'),('proc','L.run ["/usr/bin/true"]',b'Os.run')]:
            run(f'L = use "{ROOT}/std/{name}.fpr".\n> print ({call}).',code=1,error=symbol)
        run(f'L = use "{ROOT}/std/digest.fpr".\n> print "loaded".',code=1,error=b'unbound name: band')
        # Quarantined until a byte/code-point adapter exists; don't advertise a
        # successful import as hosted JSON support. Update the catalog when fixed.
        run(f'L = use "{ROOT}/std/json.fpr".\n> print (L.parse "\\\"\\\\u03bb\\\"").', 'Ok Text Î»\n'.encode())
        # Runtime input keeps format syntax separate from Sol source escaping.
        data=w/'input.txt'
        jp=lib('json',f'> r = L.parse (readPath @{data}); case r of Ok v -> print (L.render v) | Err e -> print "ERR".')
        valid=['null','true','false','0','-0','123456789012345678901234567890','1.25','-2.5e-3','1E+2',
               '[]','{}','[1,true,null,"a"]','{"x":"λ😀"}', '"\\u03bb"', '"\\uD83D\\uDE00"',
               json.dumps('"\\/\b\f\n\r\t'+''.join(map(chr,range(32)))+'λ😀')]
        for value in valid:
            data.write_text(value);out=run(jp)
            assert json.loads(out)==json.loads(value),(value,out)
        invalid=['','01','-01','+1','.1','1.','1e','1e+','--1','NaN','Infinity','1e999',
                 '[1,]','{"x":1,}','true false','"\\q"','"a\x00b"','"a\nb"','"\\uD800"',
                 '"\\uDC00"','"\\uD800\\u0041"','"\\uZZZZ"','"unterminated','[','{']
        for value in invalid: data.write_text(value);run(jp,b'ERR\n')
        data.write_text('{"x":1,"x":2}')
        run(lib('json',f'> print (L.parse (readPath @{data}) |>? L.get "x" |>? L.num).'),b'Ok 1\n')
        # Every control code and non-ASCII scalar must render to valid JSON.
        out=run(lib('json','> print (L.render (L.JStr (Str.join "" (List.map Str.fromCode (List.range 0 31))))).'))
        assert json.loads(out)==''.join(map(chr,range(32)))
        run(lib('json','> print (L.render (L.JStr (Str.fromCode 55296))).'),code=1,error=b'surrogate')
        cp=lib('csv',f'J = use "{ROOT}/sol/lib/json.sol".\n> r = L.parse (readPath @{data}); case r of Ok rows -> print (J.render (J.JArr (List.map J.strs rows))) | Err e -> print "ERR".')
        fixtures=[('',[]),('\n',[['']]),('""\n',[['']]),(',', [['','']]),('a,b\r\n1,2\r\n',[['a','b'],['1','2']]),
                  ('"a\rb","c\nd","e""f"\n',[['a\rb','c\nd','e"f']]),('λ,😀\n',[['λ','😀']]),('"a\x00b"\n',[['a\x00b']])]
        for value,expected in fixtures:
            data.write_text(value);out=run(cp);assert json.loads(out)==expected,(value,out)
        for value in ['a"b','"a"b','"a" ','"a','a\rb']:
            data.write_text(value);run(cp,b'ERR\n')
        # Round-trip through Sol render and an independent CSV reader.
        for rows in [[['']], [['a\rb','c\nd','"','λ😀']], [['a','b'],['','2']]]:
            stream=io.StringIO(newline='');csv.writer(stream).writerows(rows);data.write_text(stream.getvalue())
            out=run(lib('csv',f'> print (L.render (unwrap (L.parse (readPath @{data})))).'))
            assert list(csv.reader(io.StringIO(out.decode()[:-1],newline='')))==rows
        run(lib('csv','> print (isOk (L.recordsChecked [["a","a"],["1","2"]])).'),b'False\n')
        run(lib('csv','> print (isOk (L.recordsChecked [["a","b"],["1"]])).'),b'False\n')
        run(lib('csv','> print (L.records [["a"],["1","2"]]).'),code=1,error=b'expected 1')
        run(lib('csv','> print (L.render [[]]).'),code=1,error=b'zero-field row')
        # Long fields and escaped text exercise accumulation beyond tiny fixtures.
        data.write_text(json.dumps('λ\n' * 10000))
        assert json.loads(run(jp)) == 'λ\n' * 10000
        data.write_text('"' + 'λ,' * 10000 + '"')
        assert json.loads(run(cp)) == [['λ,' * 10000]]
        run(lib('json','> n = unwrap (Try.parseNum "1e999"); print (L.render (L.JNum n)).'), code=1,error=b'nonfinite')
        # The directory example receives literal argv, never a shell command.
        directory=w/'space;literal';directory.mkdir();(directory/'a b').write_text('abc')
        run('',b'3 a b\n1 entries\n',script=ROOT/'sol/scripts/text/shell.sol',args=[str(directory)])
        # Nested struct and diamond imports must share one canonical definition.
        (w/'leaf.sol').write_text('S = Struct { value = 7, get = fn u -> S.value }.\n')
        (w/'left.sol').write_text('leaf = use "leaf.sol".\nget u = leaf.S.get u.\n')
        (w/'right.sol').write_text('leaf = use "leaf.sol".\nget u = leaf.S.get u.\n')
        source='a = use "left.sol".\nb = use "right.sol".\n> print (a.get Unit + b.get Unit).\n'
        run(source,b'14\n');run(source,b'14\n')
        run(source,b'14\n',extra={'SOL_CACHE':'0'})
        run('b = use "right.sol".\na = use "left.sol".\n> print (a.get Unit + b.get Unit).',b'14\n')
        run(source,b'14\n',extra={'SOL_JIT':'1','SOL_TABLE':'1'})
    print(f'sol libraries: {count} contract checks passed (including explicitly catalogued compatibility gaps)')

if __name__=='__main__': main()
