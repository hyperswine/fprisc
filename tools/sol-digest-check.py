#!/usr/bin/env python3
"""Independent SHA-256 and RFC 4648 vectors over exact bytes and chunk splits."""
import base64
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY',ROOT/'fpr')).resolve()


def lit(value):
    return json.dumps(str(value),ensure_ascii=False).replace('\\u0000','\\0').replace('{','\\{').replace('}','\\}')


def main():
    count=0
    with tempfile.TemporaryDirectory(prefix='sol-digest-') as tmp:
        w=Path(tmp).resolve()
        env={k:v for k,v in os.environ.items() if not k.startswith('SOL_')}
        env|={'SOL_GPU':'0','SOL_JIT':os.environ.get('FPR_TEST_JIT','1'),'SOL_CACHE_DIR':str(w/'cache')}
        def run(source,expected=b'',code=0,error=None):
            nonlocal count
            path=w/'check.sol';path.write_text(source)
            p=subprocess.run([str(FPR),'sol',str(path)],env=env,capture_output=True,timeout=20)
            assert (p.returncode,p.stdout)==(code,expected),(source,p)
            if error is not None: assert error in p.stderr,(source,p)
            count+=1
        # Published empty/abc and million-a SHA vectors, plus block/padding
        # boundaries and binary fixtures independently hashed by hashlib.
        rng=random.Random(4721)
        vectors=[b'',b'abc',b'a'*1000000,bytes(range(256))]
        vectors += [rng.randbytes(n) for n in [1,2,3,7,31,55,56,57,63,64,65,119,120,127,128,129,65535,65536,65537]]
        for i,data in enumerate(vectors):
            file=w/f'vector{i}';file.write_bytes(data)
            expected=hashlib.sha256(data).hexdigest().encode()+b'\n'
            # Avoid generating a megabyte list literal: read file as Bytes.
            source=f'> r = unwrap (Stream.openRead {lit(file)} 65536); (digest,r2) = Sha256.stream r; u = Stream.closeRead r2; print (mapOk Hex.encode digest).\n'
            run(source,b'Ok '+expected)
            if len(data)<1024:
                run(f'> b = unwrap (Hex.decode {lit(data.hex())}); print (Hex.encode (Sha256.bytes b)).\n',expected)
                run(f'> b = unwrap (Hex.decode {lit(data.hex())}); print (Base64.encode b).\n',base64.b64encode(data)+b'\n')
                run(f'> b = unwrap (Base64.decode {lit(base64.b64encode(data).decode())}); print (Hex.encode b).\n',data.hex().encode()+b'\n')
        assert hashlib.sha256(b'abc').hexdigest()=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        # Every split around both SHA padding transitions, including empty
        # updates and repeated finalization of independently initialized states.
        data=rng.randbytes(129)
        for split in [0,1,2,31,55,56,57,63,64,65,119,120,127,128,129]:
            source=(f'> a = unwrap (Hex.decode {lit(data[:split].hex())}); b = unwrap (Hex.decode {lit(data[split:].hex())});'
                    ' s = Sha256.init Unit; s2 = unwrap (Sha256.update a s); s3 = unwrap (Sha256.update b s2); print (Hex.encode (Sha256.finish s3)).\n')
            run(source,hashlib.sha256(data).hexdigest().encode()+b'\n')
        for text in ['', 'f','fo','foo','foob','fooba','foobar']:
            encoded=base64.b64encode(text.encode()).decode()
            run(f'> b = unwrap (Utf8.encode {lit(text)}); print (Base64.encode b,Utf8.decode (unwrap (Base64.decode {lit(encoded)}))).\n',
                f'({encoded}, Ok {text})\n'.encode())
        for text in ['0','gg','ab cd','０１','a\x00','\ud800']:
            if text=='\ud800':
                run('> print (isOk (Hex.decode (Str.fromCode 55296))).\n',b'False\n')
            else:
                run(f'> print (isOk (Hex.decode {lit(text)})).\n',b'False\n')
        run('> print (Bytes.toList (unwrap (Hex.decode "aB01FE"))).\n',b'[171, 1, 254]\n')
        for text in ['A','AAA','A===','=AAA','AA=A','AA==AAAA','AB==','AAB=','AAAA=','AA-_','AA\nA','AA A','λ===']:
            run(f'> print (isOk (Base64.decode {lit(text)})).\n',b'False\n')
        run('> s = Sha256.init Unit; a = Sha256.finish s; Sha256.finish s.\n',code=1,error=b'linear')
        run('> Sha256.finish (Sha256Token 0).\n',code=1,error=b'forged SHA-256 context')
        missing=w/'missing'
        lib=f'D = use {lit(ROOT/"sol/lib/digest.sol")}.\n'
        run(lib+f'> print (isOk (D.sha256File {lit(missing)})).\n',b'False\n')
        file=w/'vector3'
        for cap in [1,7,63,64,65,4096]:
            run(lib+f'> print (D.sha256FileWith {cap} {lit(file)}).\n',b'Ok '+hashlib.sha256(file.read_bytes()).hexdigest().encode()+b'\n')
        run(lib+f'> print (isOk (D.sha256FileWith 0 {lit(file)})).\n',b'False\n')
    print(f'sol byte encoding/SHA-256: {count} checks passed')


if __name__=='__main__': main()
