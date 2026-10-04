#!/usr/bin/env python3
"""Real host modules: typed swaps, refusals, old calls and production pacing."""
import os, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT/'fpr'
def run(args, **kw):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, capture_output=True, text=True, timeout=180, **kw)
    assert p.returncode == 0, p.stdout + p.stderr
    return p.stdout
with tempfile.TemporaryDirectory(prefix='fpr-host-modules-') as directory:
    d = Path(directory)
    ext = '.dylib' if os.uname().sysname == 'Darwin' else '.so'
    mods = {}
    sources = {'v1':'mathOp v = v * 2.\n', 'v2':'mathOp v = v * 3.\n',
               'other':'otherOp v = v + 1.\n', 'bad':'mathOp v = strlen v.\n',
               'contract':'mathOp : (v : Int | v > 0) -> Int .\nmathOp v = v * 3.\n'}
    for name in ('v1','v2'):
        sources[name] += 'sum9 a b c d e f g h i = a+b+c+d+e+f+g+h+i.\n'
    for name, text in sources.items():
        src = d/(name+'.fpr'); src.write_text(text)
        mods[name] = d/(name+ext)
        run([FPR,'build',src,'--module','-o',mods[name]])
    # Real loader failures before publication, with controlled shared objects.
    rev = re.search(r'codegenRev = (\d+)', (ROOT/'compiler/Codegen.hs').read_text()).group(1)
    badlibs = {}
    for name, body in {
        'metadata':'int unrelated = 1;',
        'abi':f'const unsigned long fpr_posix_module_nativeabi=0, fpr_posix_module_codegen={rev}, fpr_modtab[]={{0}};',
        'schema':f'const unsigned long fpr_posix_module_nativeabi=3, fpr_posix_module_codegen={rev}, fpr_modtab[]={{123,1,0}};'
    }.items():
        src=d/(name+'.c');src.write_text(body);badlibs[name]=d/(name+ext)
        run(['cc', '-dynamiclib' if ext=='.dylib' else '-shared', '-fPIC',src,'-o',badlibs[name]])
    host = d/'host.fpr'
    host.write_text('''unsafe base.
N = use "std/native".
R = use "std/reload".
ok r = case r of Ok u -> u | Err why -> error why.
refused label r = case r of Err why -> print "{label}: refused" | Ok u -> error "{label}: accepted".
refusedReason label expected r = case r of Err why -> checkReason label expected why | Ok u -> error "{label}: accepted".
checkReason label expected why = case expected == why of True -> print "{label}: refused" | False -> error "{label}: wrong refusal: {why}".
main =
  _ = refused "missing" (N.attach "MISSING");
  _ = refusedReason "metadata" "not an FP-RISC host module" (N.attach "META");
  _ = refusedReason "abi" "host module ABI mismatch (rebuild module)" (N.attach "ABI");
  _ = refusedReason "schema" "unsupported module interface schema" (N.attach "SCHEMA");
  _ = case Mod.plugs 0 == 0 of True -> Unit | False -> error "loader failure published";
  _ = ok (N.attach "V1");
  old = R.bindAt 0 "mathOp";
  wide = R.bindAt 0 "sum9";
  _ = case wide 1 2 3 4 5 6 7 8 9 == 45 of True -> Unit | False -> error "shared argument spill failed";
  _ = refusedReason "duplicate" "module already attached" (N.attach "V1");
  _ = ok (N.attach "OTHER");
  _ = refusedReason "stale" "reload: stale module identity" (N.loadVersionAt 0 "stale" "new" "MISSING");
  _ = refusedReason "wrong identity" "reload: candidate module identity mismatch" (N.loadVersionAt 0 (Mod.hashAt 0) (Mod.hashAt 0) "V2");
  _ = ok (N.loadAt 0 "V2");
  op = R.bindAt 2 "mathOp";
  _ = refused "type" (N.loadAt 2 "BAD");
  _ = refused "contract" (N.loadAt 2 "CONTRACT");
  _ = case Mod.plugs 0 == 3 and old 10 == 20 and op 10 == 30 of True -> Unit | False -> error "swap or rollback failed";
  t0 = Sys.mtime Unit;
  _ = Sys.sleepUs 2000;
  t1 = Sys.mtime Unit;
  _ = case t1 > t0 and t1 - t0 >= 20000 of True -> Unit | False -> error "production clock did not advance";
  print "host modules: old=20 new=30 tables=3 clock=advancing PASS".
'''.replace('MISSING',str(d/'missing')).replace('META',str(badlibs['metadata'])).replace('SCHEMA',str(badlibs['schema'])).replace('"ABI"','"'+str(badlibs['abi'])+'"').replace('OTHER',str(mods['other'])).replace('CONTRACT',str(mods['contract'])).replace('BAD',str(mods['bad'])).replace('V1',str(mods['v1'])).replace('V2',str(mods['v2'])))
    exe = d/'host';run([FPR,'build',host,'-o',exe])
    for harts in ('1','4','4'):
        out=run([exe],env={**os.environ,'FPR_HARTS':harts})
        assert out.endswith('host modules: old=20 new=30 tables=3 clock=advancing PASS\n'),out
        for label in ('missing','metadata','abi','schema','duplicate','stale','wrong identity','type','contract'):
            assert f'{label}: refused' in out,out
    print('POSIX real modules: one/four harts, scoped swap/refusals/old functions/clock PASS')

    # The real attachment callback runs between MVU events, with current-env
    # rendering and frame pacing on the production clock (no test C shim).
    live=(ROOT/'tests/base/mvureload.fpr').read_text()
    live=live.replace('unsafe base.', 'unsafe base.\nN = use "std/native".\nR = use "std/reload".\nok r = case r of Ok u -> u | Err why -> error why.')
    live=live.replace('env.factor', '(env.op 1)')
    a=live.index('candidate info env =');b=live.index('info from to =',a)
    live=live[:a]+f'''candidate info env =
  path = case info.to == "bad" of True -> "{mods['bad']}" | False -> "{mods['v2']}";
  adopted info env (N.loadAt env.table path).
adopted info env r = case r of
    Err why -> Err why
  | Ok table -> Ok {{env | op = R.bindAt table "mathOp", table = table, hash = info.to}}.
'''+live[b:]
    live=live.replace('main =\n',f'main =\n  _ = ok (N.attach "{mods["v1"]}");\n')
    live=live.replace('{factor = 2, hash = "v1", port = p}', '{op = R.bindAt 0 "mathOp", table = 0, hash = "v1", port = p}')
    live=live.replace('tick = 0', 'tick = 10000')
    src=d/'live.fpr';src.write_text(live);exe=d/'live';run([FPR,'build',src,'-o',exe])
    for harts in ('1','4','4'):
        out=run([exe],env={**os.environ,'FPR_HARTS':harts})
        for expected in ('frame 0: [factor=2 acc=2] builds=1',
                         'frame 1: [factor=3 acc=5] builds=2',
                         'frame 2: [factor=3 acc=11] builds=2',
                         'reload: acc=11 refused=2 [mvu: 3 frames, 2 statics builds]'):
            assert expected in out,out
    print('POSIX live MVU: real module replacement/refusal/state/render/pacing on one/four harts PASS')
