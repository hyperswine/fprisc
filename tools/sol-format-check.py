#!/usr/bin/env python3
"""Bounded JSON admission and CSV records against independent expected values."""
import csv
import io
import json
import os
import random
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
FPR=Path(os.environ.get('FPR_TEST_BINARY',ROOT/'fpr')).resolve()


def lit(value):
    return json.dumps(str(value),ensure_ascii=False).replace('\\u0000','\\0').replace('{','\\{').replace('}','\\}')


def main():
    count=0
    with tempfile.TemporaryDirectory(prefix='sol-formats-') as tmp:
        w=Path(tmp).resolve(); data=w/'input'
        env={k:v for k,v in os.environ.items() if not k.startswith('SOL_')}
        env|={'SOL_GPU':'0','SOL_JIT':os.environ.get('FPR_TEST_JIT','1'),'SOL_CACHE_DIR':str(w/'cache')}
        imports=f'J = use {lit(ROOT/"sol/lib/json.sol")}.\nC = use {lit(ROOT/"sol/lib/csv.sol")}.\n'
        def run(source,expected=None,code=0,error=None,extra=None,script=None,args=()):
            nonlocal count
            path=w/'main.sol';path.write_text(imports+source)
            p=subprocess.run([str(FPR),'sol',str(script or path),*map(str,args)],env=env|(extra or {}),capture_output=True,timeout=30,cwd=w)
            assert p.returncode==code and (expected is None or p.stdout==expected),(source,p)
            if error is not None: assert error in p.stderr,(source,p)
            count+=1;return p
        jsource=f'(readPath {lit(data)})'
        # Exact byte/depth/item/string boundaries, keys as well as values.
        cases=[('"λ"',(4,1,1,2),True),('"λ"',(3,1,1,2),False),
               ('"λ"',(4,1,1,1),False),('"\\u03bb"',(8,1,1,2),True),
               ('"\\uD83D\\uDE00"',(14,1,1,4),True),('"\\uD83D\\uDE00"',(14,1,1,3),False),
               ('[[0]]',(5,2,1,0),True),('[[0]]',(5,1,1,0),False),
               ('[1,2]',(5,1,2,0),True),('[1,2]',(5,1,1,0),False),
               ('{"λ":0}',(8,1,1,2),True),('{"λ":0}',(8,1,1,1),False),
               ('{}',(2,1,0,0),True),('[]',(2,1,0,0),True),('1',(1,1,0,0),True),
               ('["[,{}]",0]',(20,1,2,6),True),
               ('{"a":1,"b":2}',(20,1,1,1),False)]
        for value,limits,ok in cases:
            data.write_text(value)
            run(f'> print (isOk (J.parseWith (J.Limits {" ".join(map(str,limits))}) {jsource})).\n',f'{ok}\n'.encode())
        # Default nesting admission must reject before recursive tree building.
        data.write_text('['*5000+'0'+']'*5000)
        run(f'> print (J.parse {jsource}).\n',b'Err json: nesting depth limit exceeded\n')
        data.write_text('{"x":1,"x":2,"u":"λ😀"}')
        p=run(f'> value = unwrap (J.parse {jsource}); print (J.render value).\n')
        assert json.loads(p.stdout,object_pairs_hook=list)==[('x',1),('x',2),('u','λ😀')]
        for value in ['-123456789012345678901234567890', '1.25e-30', '"\\u0000"', '"\\ud800"', '[1,]', '{"a":0,}']:
            data.write_text(value)
            p=run(f'> r = J.parse {jsource}; case r of Ok v -> print (J.render v) | Err e -> print "ERR".\n')
            if value in ['"\\ud800"','[1,]','{"a":0,}']: assert p.stdout==b'ERR\n',p
            else: assert json.loads(p.stdout)==json.loads(value),(value,p)
        for limits in ['-1 1 1 1','1 0 1 1','1 257 1 1','1 1 -1 1','1 1 1 -1']:
            run(f'> print (isOk (J.parseWith (J.Limits {limits}) "0")).\n',b'False\n')
        # RFC-compatible CSV fixtures, with CR/LF preserved inside quoted fields.
        fixtures=[[],[['']], [['','']], [['a','b'],['λ','😀']], [['a\rb','c\nd','e"f','\x00']],
                  [['x\r\ny',''],['last','row']], [['a'*1000,'b']]]
        for i,rows in enumerate(fixtures):
            stream=io.StringIO(newline='');csv.writer(stream,lineterminator='\r\n').writerows(rows)
            raw=stream.getvalue().encode();data.write_bytes(raw)
            p=run(f'> rows = unwrap (C.parse {jsource}); print (J.render (J.JArr (List.map J.strs rows))).\n')
            assert json.loads(p.stdout)==rows,(rows,p)
            for chunk in [1,2,7,64]:
                p=run('stashRows rows row = List.append rows [row].\n'+f'> r = unwrap (Stream.openRead {lit(data)} {chunk});'
                      ' (result,r2) = Stream.foldCsv stashRows [] 1024 4096 8192 r; u = Stream.closeRead r2;'
                      ' rows = unwrap result; print (J.render (J.JArr (List.map J.strs rows))).\n')
                assert json.loads(p.stdout)==rows,(rows,chunk,p)
        rng=random.Random(58491)
        rows=[[''.join(rng.choice('ab,\"\r\nλ😀\x00') for _ in range(rng.randrange(20)))
               for _ in range(1+rng.randrange(5))] for _ in range(300)]
        stream=io.StringIO(newline='');csv.writer(stream,lineterminator='\r\n').writerows(rows);data.write_bytes(stream.getvalue().encode())
        p=run(f'> rows = unwrap (C.parse {jsource}); print (J.render (J.JArr (List.map J.strs rows))).\n')
        assert json.loads(p.stdout)==rows,p
        csvcases=[('λ,😀\r\n',(9,1,2,4,9),True),('λ,😀\r\n',(8,1,2,4,9),False),
                  ('λ,😀\r\n',(9,1,1,4,9),False),('λ,😀\r\n',(9,1,2,3,9),False),
                  ('λ,😀\r\n',(9,1,2,4,8),False),('a\nb',(3,1,1,1,2),False),
                  ('"λ"',(4,1,1,2,4),True),('\n',(1,1,1,0,1),True),('',(0,0,0,0,1),True)]
        for value,limits,ok in csvcases:
            data.write_bytes(value.encode())
            run(f'> print (isOk (C.parseWith (C.Limits {" ".join(map(str,limits))}) {jsource})).\n',f'{ok}\n'.encode())
        for raw in [b'a"b\n',b'"a"b\n',b'"a" \n',b'"a',b'a\rb',b'\xff\n']:
            data.write_bytes(raw)
            run(f'> r = unwrap (Stream.openRead {lit(data)} 1); (result,r2) = Stream.readCsv 10 20 100 r; u = Stream.closeRead r2; print (isOk result).\n',b'False\n')
        data.write_bytes(b'\nlast')
        run(f'> r = unwrap (Stream.openRead {lit(data)} 1); (a,r2) = Stream.readCsv 1 4 4 r;'
            ' (b,r3) = Stream.readCsv 1 4 4 r2; (c,r4) = Stream.readCsv 1 4 4 r3;'
            ' u = Stream.closeRead r4; print (a,b,c).\n',b'(Ok CsvRow [], Ok CsvRow [last], Ok EndCsv)\n')
        for fields,field,record in [(1,0,3),(0,3,3),(1,3,2),(-1,3,3),(1,-1,3),(1,3,0)]:
            data.write_bytes(b'abc')
            run(f'> r = unwrap (Stream.openRead {lit(data)} 1); (result,r2) = Stream.readCsv {fields} {field} {record} r; u = Stream.closeRead r2; print (isOk result).\n',b'False\n')
        # Real transform scripts preserve Unicode and publish only a fully
        # validated file. An existing destination stays byte-for-byte on error.
        source=w/'data.csv';target=w/'result.jsonl'
        rows=[['name','note'],['λ','line1\nline2'],['😀','"quoted"']]
        stream=io.StringIO(newline='');csv.writer(stream).writerows(rows);source.write_bytes(stream.getvalue().encode())
        run('',script=ROOT/'sol/scripts/text/csv-to-jsonlines.sol',args=[source,target])
        assert [json.loads(line) for line in target.read_text().splitlines()]==rows
        target.write_bytes(b'old');source.write_bytes(b'good,row\n"unterminated')
        run('',code=1,script=ROOT/'sol/scripts/text/csv-to-jsonlines.sol',args=[source,target,'--replace'],error=b'unterminated quote')
        assert target.read_bytes()==b'old'
        source.write_bytes(b'x'*65537)
        run('',code=1,script=ROOT/'sol/scripts/text/csv-to-jsonlines.sol',args=[source,target,'--replace'],error=b'byte limit')
        assert target.read_bytes()==b'old'
        source=w/'data.jsonl';source.write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in [{'kind':'λ','n':1},{'kind':'x','n':2},{'kind':'λ','n':3}]))
        target.unlink()
        run('',script=ROOT/'sol/scripts/text/jsonlines-select.sol',args=['kind','λ',source,target])
        assert [json.loads(line) for line in target.read_text().splitlines()]==[{'kind':'λ','n':1},{'kind':'λ','n':3}]
        target.write_bytes(b'old');source.write_text('{"kind":"λ"}\n{"kind":0}\n')
        run('',code=1,script=ROOT/'sol/scripts/text/jsonlines-select.sol',args=['kind','λ',source,target,'--replace'],error=b'not a string')
        assert target.read_bytes()==b'old'
        source.write_text('{"kind":"λ"}\n\n')
        run('',code=1,script=ROOT/'sol/scripts/text/jsonlines-select.sol',args=['kind','λ',source,target,'--replace'],error=b'unexpected end')
        assert target.read_bytes()==b'old'
    print(f'sol bounded JSON/CSV formats: {count} checks passed')


if __name__=='__main__': main()
