#!/usr/bin/env python3
"""SHA schedules against hashlib at padding, block and stream boundaries."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
SIZES = [0, 1, 2, 55, 56, 63, 64, 65, 119, 120, 127, 128, 129, 255, 1024, 65535, 65536, 65537]
with tempfile.TemporaryDirectory(prefix='fpr-digest-') as directory:
    tmp = Path(directory)
    fixture = tmp / 'bytes.bin'
    raw = bytes((i * 37 + 11) % 256 for i in range(max(SIZES)))
    fixture.write_bytes(raw)
    source = tmp / 'check.fpr'
    source.write_text('''unsafe base.
D = use "std/digest".
bytes n = strJoin "" (byteGo (n - 1) Nil).
byteGo i acc = if i < 0 then acc else byteGo (i - 1) (chr (band (i * 37 + 11) 255) :: acc).
check ns = case ns of
  Nil -> Unit
| n :: rest ->
  s = bytes n;
  at = n / 2;
  st = D.init |> D.update (substr s 0 at) |> D.update "" |> D.update (substr s at (n - at));
  _ = print "{n} {D.sha256 s} {D.sha1 s} {D.finish st}";
  check rest.
main =
  _ = check (''' + ' :: '.join(map(str, SIZES)) + ''' :: Nil);
  path = case Sys.args Unit of p :: _ -> p | _ -> error "missing fixture";
  case D.sha256File path of Ok digest -> print digest | Err why -> error why.
''')
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT))
    exe = tmp / 'check'
    b = subprocess.run([ROOT/'fpr', 'build', source, '--harts', '4', '-o', exe], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=180)
    assert b.returncode == 0, b.stdout + b.stderr
    expected = ''.join(f'{n} {hashlib.sha256(raw[:n]).hexdigest()} {hashlib.sha1(raw[:n]).hexdigest()} {hashlib.sha256(raw[:n]).hexdigest()}\n' for n in SIZES)
    expected += hashlib.sha256(raw).hexdigest() + '\n'
    for harts in ('1', '4'):
        p = subprocess.run([exe, fixture], cwd=ROOT, env=dict(env, FPR_HARTS=harts), capture_output=True, text=True, timeout=90)
        assert p.returncode == 0 and p.stdout == expected and not p.stderr, (harts, p.stdout, p.stderr)
    print('digest: SHA-256/SHA-1 binary padding/block boundaries, incremental and 64KiB streaming against hashlib on 1/4 harts PASS')
