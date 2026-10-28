#!/usr/bin/env python3
"""Raw CLI options and typed JSON/env configuration, including atomic updates."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
FPR=Path(os.environ.get('FPR_TEST_BINARY',ROOT/'fpr')).resolve()


def lit(value):
    return json.dumps(str(value),ensure_ascii=False).replace('{','\\{').replace('}','\\}')


def main():
    count=0
    with tempfile.TemporaryDirectory(prefix='sol-cli-config-') as tmp:
        w=Path(tmp).resolve()
        env={k:v for k,v in os.environ.items() if not k.startswith('SOL_')}
        env|={'SOL_GPU':'0','SOL_JIT':os.environ.get('FPR_TEST_JIT','1'),'SOL_CACHE_DIR':str(w/'cache')}
        imports=f'CLI = use {lit(ROOT/"sol/lib/cli.sol")}.\nC = use {lit(ROOT/"sol/lib/config.sol")}.\nJ = use {lit(ROOT/"sol/lib/json.sol")}.\n'
        specs='[CLI.Option "verbose" "v" CLI.Switch, CLI.Option "output" "o" CLI.One, CLI.Option "include" "I" CLI.Many]'
        def run(source='',expected=None,code=0,error=None,args=(),extra=None,script=None):
            nonlocal count
            path=w/'main.sol';path.write_text(imports+source)
            p=subprocess.run([str(FPR),'sol',str(script or path),*map(str,args)],env=env|(extra or {}),capture_output=True,timeout=30,cwd=w)
            assert p.returncode==code and (expected is None or p.stdout==expected),(source,p)
            if error is not None: assert error in p.stderr,(source,p)
            count+=1;return p
        run(f'> p = unwrap (CLI.parse {specs} (args Unit)); print (CLI.flag "verbose" p,CLI.valueOr "none" "output" p,CLI.values "include" p,CLI.operands p).\n',
            b'(True, a b;*, [one, two], [input, --literal, ])\n',args=['input','-v','--output=a b;*','-I','one','--include','two','--','--literal',''])
        run(f'> p = unwrap (CLI.parse {specs} (args Unit)); print (CLI.valueOr "none" "output" p,CLI.operands p).\n',
            b'(-3, [-])\n',args=['-o','-3','-'])
        for args,message in [(['--unknown'],'unknown option'),(['-z'],'unknown option'),(['-vv'],'cannot be bundled'),
                             (['--output'],'missing value'),(['--verbose','-v'],'duplicate'),
                             (['--output=a','-o','b'],'duplicate'),(['--verbose=true'],'takes no value')]:
            run(f'> unwrap (CLI.parse {specs} (args Unit)).\n',code=1,error=message.encode(),args=args)
        for schema in ['[CLI.Option "" "" CLI.One]', '[CLI.Option "bad name" "" CLI.One]',
                       '[CLI.Option "x" "xx" CLI.One]', '[CLI.Option "x" "v" CLI.One,CLI.Option "y" "v" CLI.One]',
                       '[CLI.Option "x" "" CLI.One,CLI.Option "x" "" CLI.Many]']:
            run(f'> print (isOk (CLI.parse {schema} [])).\n',b'False\n')
        path=w/'config.json'
        document={'label':'λ😀','attempts':2}
        path.write_text(json.dumps(document,ensure_ascii=False));path.chmod(0o640)
        read=f'C.read {lit(path)} |>? C.schema ["label","attempts"]'
        run(f'> j = unwrap ({read}); print (C.string "label" "SOL_CONFIG_LABEL" j,C.integerBetween 0 10 "attempts" "SOL_CONFIG_ATTEMPTS" j).\n',
            '(Ok λ😀, Ok 2)\n'.encode())
        run(f'> j = unwrap ({read}); print (C.string "label" "SOL_CONFIG_LABEL" j,C.integerBetween 0 10 "attempts" "SOL_CONFIG_ATTEMPTS" j).\n',
            b'(Ok env, Ok 4)\n',extra={'SOL_CONFIG_LABEL':'env','SOL_CONFIG_ATTEMPTS':'4'})
        run(f'> j = unwrap ({read}); print (C.string "label" "SOL_CONFIG_LABEL" j).\n',b'Ok \n',extra={'SOL_CONFIG_LABEL':''})
        for text,message in [('{"label":"x","attempts":1,"extra":0}','unknown key'),
                             ('{"label":"x","label":"y","attempts":1}','duplicate key'),
                             ('{"label":"x","attempts":1.5}','expected an integer'),
                             ('{"label":"x","attempts":11}','expected 0..10'),
                             ('{"label":3,"attempts":1}','not a string'),
                             ('{"attempts":1}','no key'), ('{"label":','config'), ('[]','not an object')]:
            path.write_text(text)
            run(f'> j = unwrap ({read}); label = unwrap (C.string "label" "" j); unwrap (C.integerBetween 0 10 "attempts" "" j).\n',code=1,error=message.encode())
        path.write_text(json.dumps(document,ensure_ascii=False))
        large='9'*320
        path.write_text('{"label":"x","attempts":'+large+'}')
        run(f'> j = unwrap ({read}); print (C.integer "attempts" "" j).\n',('Ok '+large+'\n').encode())
        path.write_text(json.dumps(document,ensure_ascii=False))
        run(f'> j = unwrap ({read}); print (isOk (C.integer "attempts" "SOL_CONFIG_ATTEMPTS" j)).\n',b'False\n',extra={'SOL_CONFIG_ATTEMPTS':'bad'})
        # A real update takes CLI over environment over file values, commits
        # once under forced retries, and preserves the destination's mode.
        script=ROOT/'sol/scripts/config-update.sol'
        run(script=script,args=[path,'--label','cli','--attempts','3'],extra={'SOL_CONFIG_LABEL':'env','SOL_CONFIG_ATTEMPTS':'4','SOL_FORCE_RETRY':'2'})
        assert json.loads(path.read_text())=={'label':'cli','attempts':3}
        assert path.stat().st_mode & 0o777 == 0o640
        run(script=script,args=[path],extra={'SOL_CONFIG_LABEL':'env','SOL_CONFIG_ATTEMPTS':'4'})
        assert json.loads(path.read_text())=={'label':'env','attempts':4}
        old=path.read_bytes()
        run(script=script,args=[path,'--attempts','20'],code=1,error=b'expected 0..10')
        assert path.read_bytes()==old
        # A panic after the buffered update rolls back, including a valid schema.
        run(f'> j = unwrap ({read}); u = writePath {lit(path)} (J.render (J.set "attempts" (J.JNum 8) j)); error "discard config".\n',code=1,error=b'discard config')
        assert path.read_bytes()==old
        # Crash at the commit point leaves an ordered redo journal; another
        # script in the same directory recovers the exact post-image.
        run(f'> j = unwrap ({read}); writePath {lit(path)} (J.render (J.set "attempts" (J.JNum 9) j)).\n',code=137,error=b'SOL_CRASH_AT',extra={'SOL_CRASH_AT':'0'})
        assert path.read_bytes()==old
        path2=w/'recover.sol';path2.write_text(f'> readPath {lit(path)}.\n')
        run(script=path2)
        assert json.loads(path.read_text())['attempts']==9
        assert path.stat().st_mode & 0o777 == 0o640
        assert not list(w.glob('*.soljournal.*'))
    print(f'sol CLI/configuration: {count} checks passed')


if __name__=='__main__': main()
