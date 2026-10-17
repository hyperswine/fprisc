#!/usr/bin/env python3
"""Contracts survive function values, partial calls and lexical shadowing.

The compiler must already be built (check_base does that once). These are
execution/compile refusals, not AST snapshots: both Base and Sol use the
shared precondition pass. Runtime failures must precede the function body;
Sol must also roll back any earlier buffered file writes.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / 'fpr'
CONTRACTS = '''
L = use "std/list".
positive : (n : Int | n > 0) -> Int.
positive n = n.
later : Int -> (n : Int | n > 0) -> Int.
later base n = base + n.
last : (a : Int | a > 0) -> Int -> (b : Int | b > 0) -> Int.
last a middle b = a + middle + b.
alias = positive.
ops = { run = positive }.
choose flag = case flag of True -> positive | False -> positive.
apply f x = f x.
'''

with tempfile.TemporaryDirectory(prefix='fpr-ho-contracts-') as tmp:
    work = Path(tmp)
    env = os.environ | {'FPR_HOME': str(ROOT), 'FPR_PATH': str(ROOT),
                       'SOL_CACHE_DIR': str(work / 'sol-cache'), 'SOL_GPU': '0'}
    env.pop('FPR_FOREIGN', None)

    def invoke(args, code=0, needle=None, extra_env=None):
        p = subprocess.run([str(a) for a in args], cwd=work,
                           env=env | (extra_env or {}), capture_output=True,
                           text=True, timeout=120)
        out = p.stdout + p.stderr
        assert p.returncode == code, (args, p.returncode, out)
        if needle is not None:
            assert needle in out, (args, needle, out)
        return p

    def source(name, text, mode, code=0, needle=None, flags=()):
        p = work / (name + ('.sol' if mode == 'sol' else '.fpr'))
        p.write_text(text)
        if mode == 'sol':
            return invoke([FPR, 'sol', p], code, needle)
        exe = work / name
        invoke([FPR, 'build', *flags, p, '-o', exe])
        return invoke([exe], code, needle)

    good_body = '''
partial = later 10;
partial2 = last 1 2;
(tupleFn, v) = (positive, 7);
print "good: {L.map positive [1,2]} {alias 3} {ops.run 4} {(choose True) 5} {apply positive 6} {tupleFn v} {partial 8} {partial2 9}"
'''
    for mode in ('native', 'sol'):
        entry = '> ' if mode == 'sol' else 'main = '
        p = source('good-' + mode, CONTRACTS + entry + good_body + '.', mode)
        assert 'good: [1, 2] 3 4 5 6 7 18 12' in p.stdout, p.stdout

        probes = {
            'map': ('print "{L.map positive [1,-1]}"', 'positive'),
            'alias': ('print "{alias (-1)}"', 'positive'),
            'record': ('print "{ops.run (-1)}"', 'positive'),
            'returned': ('print "{(choose True) (-1)}"', 'positive'),
            'argument': ('print "{apply positive (-1)}"', 'positive'),
            'tuple': ('(f, v) = (positive, -1); print "{f v}"', 'positive'),
            'partial': ('f = later 1; print "{f (-1)}"', 'later'),
            'repartial': ('f = last 1; g = f 2; print "{g (-1)}"', 'last'),
            'pipeline': ('print "{[1,-1] |> L.map positive}"', 'positive'),
        }
        for name, (body, blame) in probes.items():
            source(name + '-' + mode, CONTRACTS + entry + body + '.', mode,
                   code=1, needle='precondition violated: ' + blame)

        # Named Boolean helpers are ordinary source functions. Shadowing
        # one must not manufacture a proof of the condition it ignores.
        shadow_fact = '''
positive : (n : Int | n > 0) -> Int.
positive n = u = print "invalid body"; n.
'''
        for label, global_helper, local_helper in [
            ('local', '', 'and2 a b = True; '),
            ('global', 'and2 a b = True.\n', ''),
        ]:
            body = local_helper + 'x = parseInt "-1"; case and2 (x > 0) True of '
            body += 'True -> print "{positive x}" | False -> print "safe"'
            p = source('boolean-fact-' + label + '-' + mode,
                       shadow_fact + global_helper + entry + body + '.', mode,
                       code=1, needle='precondition violated: positive')
            assert 'invalid body\n' not in p.stdout, p.stdout
        # Prefix helper syntax in a signature is logical grammar and
        # cannot call a same-named local/global source definition.
        logical_contract = '''
bounded : (n : Int | and2 (n > 0) (n < 10)) -> Int.
bounded n = n.
'''
        for label, global_helper, local_helper in [
            ('local', '', 'and2 a b = True; '),
            ('global', 'and2 a b = True.\n', ''),
        ]:
            source('boolean-predicate-' + label + '-' + mode,
                   logical_contract + global_helper + entry + local_helper
                   + 'print "{bounded (parseInt "-1")}".', mode, code=1,
                   needle='precondition violated: bounded')
        source('boolean-or-predicate-' + mode, '''
bounded : (n : Int | or2 (n > 0) (n < -10)) -> Int.
bounded n = n.
or2 a b = True.
''' + entry + 'print "{bounded (parseInt "-1")}".', mode,
               code=1, needle='precondition violated: bounded')

        # A failing first parameter is checked when the PAP is created,
        # even if the resulting function would never be invoked.
        source('early-' + mode, CONTRACTS + entry
               + 'f = last (-1); print "must-not-run".', mode, code=1,
               needle='precondition violated: last')
        timing = '''
emit n = u = print "argument {n}"; n.
ordered : Int -> (n : Int | n > 0) -> (m : Int | m > 0) -> Int.
ordered base n m = u = print "body"; base + n + m.
'''
        p = source('timing-' + mode, timing + entry + '''
f = ordered (emit 10) (emit 2);
u = print "between";
a = f (emit 3);
b = f (emit 4);
print "result: {a} {b}".
''', mode)
        assert p.stdout.splitlines() == [
            'argument 10', 'argument 2', 'between', 'argument 3', 'body',
            'argument 4', 'body', 'result: 15 16'], p.stdout
        # Escaped values are checked when their full signature saturates.
        # Creating their PAP evaluates/captures supplied arguments once,
        # but does not run the original body or its remaining boundary.
        p = source('escaped-timing-' + mode, timing + 'escaped = ordered.\n'
                   + entry + 'f = escaped (emit 10) (emit (-1)); '
                   'u = print "created"; print "done".', mode)
        assert p.stdout.splitlines() == ['argument 10', 'argument -1', 'created', 'done'], p.stdout
        p = source('escaped-saturate-' + mode, timing + 'escaped = ordered.\n'
                   + entry + 'f = escaped (emit 10) (emit (-1)); '
                   'u = print "between"; print "{f (emit 3)}".', mode,
                   code=1, needle='precondition violated: ordered')
        assert '\nbody\n' not in p.stdout, p.stdout
        if mode == 'native':
            assert p.stdout.splitlines()[:4] == ['argument 10', 'argument -1', 'between', 'argument 3'], p.stdout

        overapplied = '''
checked : (n : Int | n > 0) -> (Int -> Int).
checked n = u = print "body"; fn m -> n + m.
escapedChecked = checked.
emit n = u = print "argument"; n.
'''
        for name, expression in [('direct', 'checked (parseInt "1") (emit 2)'),
                                 ('alias', 'escapedChecked (parseInt "1") (emit 2)')]:
            raw = overapplied.replace('(n : Int | n > 0)', 'Int')
            baseline = source('overapplied-raw-' + name + '-' + mode, raw
                              + entry + 'print "{' + expression + '}".', mode)
            p = source('overapplied-' + name + '-' + mode, overapplied
                       + entry + 'print "{' + expression + '}".', mode)
            assert p.stdout == baseline.stdout, (name, mode, baseline.stdout, p.stdout)
            if name == 'direct':
                assert p.stdout.splitlines() == ['body', 'argument', '3'], p.stdout

        # Top-level parameters, lambda parameters, local function names,
        # case patterns and guard patterns must shadow global contracts.
        shadows = '''
call positive = positive (-1).
local u = positive n = n; positive (-2).
patternFn u = case (fn n -> n) of positive -> positive (-3).
guardFn positive | positive (-4) == -4 = 4.
guardFn _ = 0.
guardPat u | positive <- (fn n -> n) = positive (-5).
guardPat _ = 0.
'''
        p = source('shadow-' + mode, CONTRACTS + shadows + entry + '''
pcv0 = -6;
print "shadow: {call (fn n -> n)} {local Unit} {patternFn Unit} {guardFn (fn n -> n)} {guardPat Unit} {(fn positive -> positive pcv0) (fn n -> n)}".
''', mode)
        assert 'shadow: -1 -2 -3 4 -5 -6' in p.stdout, p.stdout
        # The old generated `pcv0` let could capture this second argument.
        p = source('fresh-' + mode, CONTRACTS + entry
                   + 'pcv0 = 9; x = later pcv0 (parseInt "2"); print "fresh: {x}".', mode)
        assert 'fresh: 11' in p.stdout, p.stdout

        guards = '''
valid : (n : Int | n > 0) -> Bool.
valid n = True.
guarded n | valid n = 1.
guarded _ = 0.
'''
        source('guard-check-' + mode, guards + entry + 'print "{guarded (-1)}".',
               mode, code=1, needle='precondition violated: valid')

        # Native specialization occurs after the contract pass. Replacing
        # a Sig/Struct projection must retain the checked record entry.
        specialized = '''
UnaryPositive = Sig { add : Int -> Int }.
N.add : (n : Int | n > 0) -> Int.
N = Struct UnaryPositive { add = fn n -> u = print "invalid body"; n }.
useStruct (s : UnaryPositive) x = s.add x.
'''
        p = source('specialized-' + mode, specialized + entry
                   + 'print "{useStruct N (-1)}".', mode, code=1,
                   needle='precondition violated: N.add')
        assert 'invalid body\n' not in p.stdout, p.stdout
        for name, expr in [('member', 'print "{N.add (-1)}"'),
                           ('member-value', 'f = N.add; print "{f (-1)}"')]:
            p = source(name + '-' + mode, specialized + entry + expr + '.',
                       mode, code=1, needle='precondition violated: N.add')
            assert 'invalid body\n' not in p.stdout, p.stdout

        # Imported signatures must generate checked entries in their own
        # native unit and in Sol's merged bytecode program.
        (work / 'checked-module.fpr').write_text(CONTRACTS)
        source('import-' + mode, 'L = use "std/list".\nM = use "checked-module.fpr".\n' + entry
               + 'print "{L.map M.positive [-1]}".', mode, code=1,
               needle='precondition violated: ')

    source('dynamic-module', 'M = use "checked-module.fpr".\n'
           'main = f = Mod.fn M "positive"; print "{f (-1)}".',
           'native', code=1, needle='precondition violated: ')
    source('vector-map', CONTRACTS + '''
main = v = Vec.map positive (Vec.fromList [1,-1]);
       (n, v2) = Vec.len v; u = Vec.free v2; print "{n}".
''', 'native', code=1, needle='precondition violated: positive')

    # Repeated declarations of one foreign primitive across distinct
    # imported units share one checked entry, without duplicate symbols.
    foreign_header = 'Sys.sleepUs : (n : Int | n > 0) -> Unit.\nnap = Sys.sleepUs.\n'
    (work / 'sleep-a.fpr').write_text(foreign_header + 'marker = 1.\n')
    (work / 'sleep-b.fpr').write_text(foreign_header + 'marker = 2.\n')
    foreign_imports = 'A = use "sleep-a.fpr".\nB = use "sleep-b.fpr".\n'
    source('foreign-units', foreign_imports
           + 'main = a = A.nap 1; b = B.nap 1; print "foreign units: okay".',
           'native', needle='foreign units: okay')
    for label in ('A', 'B'):
        source('foreign-invalid-' + label, foreign_imports
               + 'main = ' + label + '.nap (-1).', 'native', code=1,
               needle='precondition violated: Sys.sleepUs')

    # Type inference may add a hidden vector-layout descriptor. Export
    # checks compare declared/source arity, not this implementation arity.
    (work / 'vector-evidence.fpr').write_text('''
create : (n : Int | n > 0) -> a -> Vector a.
create n value = Vec.fromList [value].
''')
    source('vector-evidence-host', '''
M = use "vector-evidence.fpr".
main = v = M.create 1 42; (n, v2) = Vec.len v;
       u = Vec.free v2; print "vector evidence: {n}".
''', 'native', needle='vector evidence: 1')

    rollback = work / 'must-not-exist'
    source('rollback', CONTRACTS + f'> u = writePath "{rollback}" "partial"; '
           'print "{L.map positive [-1]}".', 'sol', code=1,
           needle='precondition violated: positive')
    assert not rollback.exists()

    # Checked entries preserve true linear parameter/return types. A PAP
    # owning a Vector may be invoked once, and reuse remains a compile error.
    linear = '''
readAt : (Vector Int) -> (i : Int | i >= 0) -> (Int, (Vector Int)).
readAt v i = Vec.get i v.
'''
    source('linear-once', linear + '''
main = v = Vec.push 42 (Vec.new Unit); f = readAt v;
       (x, v2) = f 0; u = Vec.free v2; print "linear: {x}".
''', 'native', needle='linear: 42')
    bad = work / 'linear-twice.fpr'
    bad.write_text(linear + '''
main = v = Vec.push 42 (Vec.new Unit); f = readAt v;
       (x, v2) = f 0; (y, v3) = f 0;
       a = Vec.free v2; b = Vec.free v3; print "{x} {y}".
''')
    invoke([FPR, 'build', bad, '-o', work / 'linear-twice'], 1,
           "linear variable 'f' used 2 time(s)")

    # Direct proved calls retain their original resource bound. A checked
    # callback has real failure-path costs; they must not be hidden behind
    # an invented unsafe annotation or the raw function's declaration.
    direct = work / 'direct.fpr'
    direct.write_text('''
positive : (n : Int | n > 0) -> Int | work positive <= 0 | alloc positive <= 0.
positive n = n.
main : Int | work main <= 1 | alloc main <= 0.
main = positive 2.
''')
    p = invoke([FPR, 'build', '--cost', '-v', direct, '-o', work / 'direct'], needle='PROVEN',
               extra_env={'FPR_PRECOND_NOTES': '1'})
    assert 'main -> positive requires (2 > 0): discharged statically' in p.stdout
    assert '0 runtime-checked' in p.stdout, p.stdout
    bounded = work / 'bounded-callback.fpr'
    bounded.write_text('''
positive : (n : Int | n > 0) -> Int | work positive <= 0 | alloc positive <= 0.
positive n = n.
apply f n = f n.
main : Int | work main <= 100.
main = apply positive 2.
''')
    invoke([FPR, 'build', bounded, '-o', work / 'bounded-callback'], 1, 'UNPROVED')

    exported = work / 'exported.fpr'
    exported.write_text('positive : (n : Int | n > 0) -> Int.\npositive n = n.\n')
    assembly = work / 'exported.s'
    invoke([ROOT / 'fprc', '--profile=bare-metal-builtin', '--arc', '--lib',
            '--export=positive:checked_positive', exported, assembly])
    asm = assembly.read_text()
    trampoline = asm.split('\nchecked_positive:\n', 1)[1]
    assert 'fpr_fn__x24precond0_x2epositive' in trampoline, trampoline[:1500]
    foreign = work / 'foreign.fpr'
    foreign.write_text('external : (n : Int | n > 0) -> Int.\n'
                       'main = f = external; f 1.\n')
    invoke([ROOT / 'fprc', '--profile=bare-metal-builtin', foreign, assembly])
    asm = assembly.read_text()
    assert 'fpr_fn__x24precond0_x2eexternal:' in asm
    assert 'fpr_g_external' in asm or 'fpr_fn_external' in asm

    # Returned-function definitions are not silently eta-expanded across
    # effects. Direct saturated use still works; an escape is refused.
    staged = '''
makeChecked : (x : Int | x > 0) -> (y : Int | y > 0) -> Int.
makeChecked x = u = print "body-before-later-arg"; fn y -> x + y.
'''
    source('staged-direct', staged + 'main = print "{makeChecked 1 2}".',
           'native', needle='body-before-later-arg')
    for mode in ('native', 'sol'):
        entry = '> ' if mode == 'sol' else 'main = '
        p = work / ('staged-escape.' + ('sol' if mode == 'sol' else 'fpr'))
        p.write_text(staged + entry + 'f = makeChecked 1; u = print "later"; print "{f 2}".')
        args = [FPR, 'sol', p] if mode == 'sol' else [FPR, 'build', p, '-o', work / 'staged-escape']
        invoke(args, 1, 'preserve application timing')
        for label, declaration in [
            ('global', 'limit = 10.\npositive : (n : Int | n > limit) -> Int.\npositive n = n.\n'),
            ('relational', 'positive : (limit : Int | limit >= 0) -> (n : Int | n > limit) -> Int.\npositive limit n = n.\n'),
        ]:
            p = work / ('free-' + label + ('.sol' if mode == 'sol' else '.fpr'))
            p.write_text(declaration + entry + 'limit = -10; print "must-not-run".')
            args = [FPR, 'sol', p] if mode == 'sol' else [FPR, 'build', p, '-o', work / ('free-' + label)]
            invoke(args, 1, 'free predicate names are not supported: limit')

    # A contract-only shared module must retain its real source identity
    # after remapping root export pointers to checked entries.
    ext = '.dylib' if os.uname().sysname == 'Darwin' else '.so'
    module = work / ('contract-only' + ext)
    invoke([FPR, 'build', '--module', exported, '-o', module])
    host = '''unsafe base.
N = use "std/native".
P = use "std/program".
require b why = case b of True -> Unit | False -> error why.
main =
  attached = case N.attach "MODULE" of Ok h -> Unit | Err why -> error why;
  hash = Mod.hashAt 0;
  u = require (hash != "") "module source hash lost";
  (found, f) = Mod.findAt 0 "positive";
  byHash = Mod.fn hash "positive";
  v = require (found == 1 and f 2 == 2 and byHash 3 == 3) "module lookup failed";
  input = case P.args Unit of Nil -> 2 | _ -> (-1);
  print "module: {f input}".
'''.replace('MODULE', str(module))
    source('module-host', host, 'native', needle='module: 2')
    invoke([work / 'module-host', 'invalid'], 1, 'precondition violated: positive')

print('Higher-order contracts: native + Sol aliases, callbacks, records, returns, partials, guards, imports, order, rollback and linear ownership HOLD; direct budgets prove and checked costs remain visible')
