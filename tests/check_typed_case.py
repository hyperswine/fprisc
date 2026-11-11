#!/usr/bin/env python3
"""C1 Piece 1: type-directed case variant tests on statically-typed nominal ADTs.

The static type is not a promise for received values (receive is typed by its
use), so the nominal test still rejects an Int and checks the typeid; it only
compares typeid and variant as one header word (2026-11-04 fix).
"""
from pathlib import Path
import os, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]

PROGRAMS = {
    'list_fold': '''L = use "std/list".
step : Int -> Int -> Int .
step acc x = acc + x * 3 + 1.
main = print "{L.fold step 0 (L.range 1 200)}".
''',
    'result_pipe': '''parse : Int -> Result Int String .
parse n = if n > 0 then Ok (n * 2) else Err "non-positive".
step : Int -> Result Int String .
step x = if x < 100 then Ok (x + 7) else Err "too-large".
run : Int -> Int .
run n = case (parse n |>? step) of
    Ok v -> v
  | Err _ -> -1.
main = print "{run 10} {run -3} {run 60}".
''',
    'nominal_adt': '''Tree = Type (Leaf Int | Branch Tree Int Tree).
sumTree : unsafe Tree -> Int .
sumTree t = case t of
    Leaf x -> x
  | Branch l v r -> sumTree l + v + sumTree r.
mkTree : unsafe Int -> Tree .
mkTree d = if d == 0 then Leaf 1 else Branch (mkTree (d - 1)) d (mkTree (d - 1)).
main = print "{sumTree (mkTree 6)}".
''',
    'record_poly': '''getX r = r.x.
updX r v = {r | x = v}.
main =
  a = {x = 10, y = 20};
  b = {w = 1, x = 30, z = 40};
  a2 = updX a 15;
  b2 = updX b 35;
  print "{getX a2} {getX b2} {a2.y} {b2.z}".
''',
    # a received tuple and a received Int are not Q's constructors: they fall to `_`
    'receive_tuple': '''Q = Type (PA Int | PB Int).
main =
  me = myself 0;
  _ = send me ("x", "y");
  m = receive me;
  r = case m of
      PA x -> "PA"
    | PB x -> "PB"
    | _ -> "other";
  print r.
''',
    'receive_int': '''Q = Type (PA Int | PB Int).
main =
  me = myself 0;
  _ = send me 5;
  m = receive me;
  r = case m of
      PA x -> "PA"
    | PB x -> "PB"
    | _ -> "other";
  print r.
''',
    # std/mvu's port queues tuples beside its own PDrain/PBarrier messages
    'receive_list': '''L = use "std/list".
main =
  me = myself 0;
  _ = send me (1, 2);
  m = receive me;
  r = case m of
      Nil -> "Nil"
    | _ :: _ -> "Cons"
    | _ -> "other";
  print r.
''',
}

EXPECTED = {'receive_tuple': 'other', 'receive_int': 'other', 'receive_list': 'other'}


def run(args, env, timeout=180):
    return subprocess.run(list(map(str, args)), cwd=ROOT, env=env, text=True,
                          capture_output=True, timeout=timeout)


def fn_block(asm: str, prefix: str) -> str:
    m = re.search(rf'(?ms)^# fn {re.escape(prefix)}[^\n]*\n.*?(?=^# native-insns-v1:[^\n]*\n)', asm)
    assert m, f'missing function {prefix}'
    return m.group(0)


def main():
    with tempfile.TemporaryDirectory(prefix='fpr-typed-case-') as directory:
        tmp = Path(directory)
        base = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), FPR_HARTS='1',
                    XDG_CACHE_HOME=str(tmp / 'cache'))

        # 1. Differential execution across nominal ADTs, Result, List, and row-polymorphic records.
        for name, text in PROGRAMS.items():
            path = tmp / f'{name}.fpr'
            path.write_text(text)
            outputs = {}
            for disabled in (False, True):
                env = dict(base)
                if disabled:
                    env['FPR_NO_TYPED_CASE'] = '1'
                exe = tmp / f'{name}-{int(disabled)}'
                made = run([ROOT / 'fpr', 'build', path, '--harts', '1', '-o', exe], env)
                assert made.returncode == 0, (name, disabled, made.stdout[-2000:], made.stderr[-4000:])
                ran = run([exe], env, timeout=60)
                assert ran.returncode == 0, (name, disabled, ran.stdout, ran.stderr)
                outputs[disabled] = (ran.returncode, ran.stdout, ran.stderr)
            assert outputs[False] == outputs[True], (name, outputs)
            if name in EXPECTED:
                assert outputs[False][1].strip() == EXPECTED[name], (name, outputs[False])
            print(f'Type-directed case differential: {name} -> {outputs[False][1].strip()} PASS', flush=True)

        # 2. Target codegen verification across x64, a64mac, and rv64 on nominal_adt & record_poly.
        adt_src = tmp / 'nominal_adt.fpr'
        rec_src = tmp / 'record_poly.fpr'
        for target in ('x64', 'a64mac', 'rv64'):
            asm_on = tmp / f'adt-{target}-on.s'
            asm_off = tmp / f'adt-{target}-off.s'
            r_on = run([ROOT / 'fpr', 'compile', '--system=posix', f'--target={target}', adt_src, asm_on], base)
            r_off = run([ROOT / 'fpr', 'compile', '--system=posix', f'--target={target}', adt_src, asm_off],
                        dict(base, FPR_NO_TYPED_CASE='1'))
            assert r_on.returncode == 0 and r_off.returncode == 0, (target, r_on.stderr, r_off.stderr)
            body_on = fn_block(asm_on.read_text(), 'sumTree')
            body_off = fn_block(asm_off.read_text(), 'sumTree')
            assert 'tagno' not in body_on and 'tagdone' not in body_on, (target, body_on)
            # the Int check survives, then one 64-bit header load at +0
            if target == 'x64':
                assert 'varno' in body_on, (target, body_on)
            elif target == 'a64mac':
                # out of line ('varno'), or fused into its branch (2026-11-12):
                # the Int bit, then one header load at +0
                assert 'varno' in body_on or (re.search(r'and (x\d+), (x\d+), #1\n\s+cbnz \1', body_on)
                                              and re.search(r'ldu?r x\d+, \[x\d+(, #0)?\]', body_on)), (target, body_on)
            else:
                assert re.search(r'andi \w+, \w+, 1\n\s+bnez', body_on) and re.search(r'ld \w+, 0\(', body_on), (target, body_on)
            if target in ('x64', 'a64mac'):
                assert 'tagno' in body_off and 'tagdone' in body_off, (target, body_off)
            assert len(body_on.splitlines()) < len(body_off.splitlines()), (target, len(body_on.splitlines()), len(body_off.splitlines()))

            # Record shape dispatch must still emit full tag tests (including type_id at offset 0).
            rec_asm = tmp / f'rec-{target}-on.s'
            r_rec = run([ROOT / 'fpr', 'compile', '--system=posix', f'--target={target}', rec_src, rec_asm], base)
            assert r_rec.returncode == 0, (target, r_rec.stderr)
            getx_body = fn_block(rec_asm.read_text(), 'getX')
            if target in ('x64', 'a64mac'):
                assert 'tagno' in getx_body and 'tagdone' in getx_body, (target, getx_body)
            print(f'Type-directed case target selection ({target}): nominal ADT one header load, record shape guarded PASS', flush=True)


if __name__ == '__main__':
    main()
