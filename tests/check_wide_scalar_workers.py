#!/usr/bin/env python3
"""Exercise mixed raw Int and Bool scalar worker arguments across native spill cells."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from check_product_returns import ROOT, run

WIDTHS = (6, 7, 8, 9, 16, 63, 64)
STEPS = 4051


def lanes(width):
    # Put Booleans in both register and spill slots, mixed with raw Ints.
    return [i for i in range(1, width) if i % 4 == 0]


def arguments(width, seed):
    return [
        ((i + seed) % 3 == 0) if i in lanes(width) else (i * 7 - 2 * seed)
        for i in range(1, width)
    ]


def answer(width, steps, seed):
    values = arguments(width, seed)
    for boolean in (False, True):
        locations = [
            i for i in range(width - 1) if ((i + 1 in lanes(width)) == boolean)
        ]
        for j, i in enumerate(locations):
            values[i] = arguments(width, seed)[locations[(j + steps) % len(locations)]]
    return sum(
        i * (11 if v is True else -13 if v is False else v)
        for i, v in enumerate(values, 1)
    )


def pack(fields, aggregate):
    return "(" + ",".join(fields) + ")" if aggregate else " ".join(fields)


def call_arguments(width, seed, aggregate=False):
    return pack(
        [
            str(x) if type(x) is bool or x >= 0 else f"(0 - {-x})"
            for x in arguments(width, seed)
        ],
        aggregate,
    )


def definition(width, aggregate=False, increment=False):
    params = [f"x{i}" for i in range(1, width)]
    rotate = list(params)
    for boolean in (False, True):
        locations = [
            i for i in range(width - 1) if ((i + 1 in lanes(width)) == boolean)
        ]
        for j, i in enumerate(locations):
            rotate[i] = params[locations[(j + 1) % len(locations)]]
    if increment:
        rotate = [
            field if i in lanes(width) else f"({field} + 1)"
            for i, field in enumerate(rotate, 1)
        ]
    total = " + ".join(
        f"{i} * " + (f"(if {x} then 11 else (0 - 13))" if i in lanes(width) else x)
        for i, x in enumerate(params, 1)
    )
    return (
        f"wide{width} n "
        + pack(params, aggregate)
        + f" = "
        + ("if n == (0 - 1) then 777 else " if width == 64 else "")
        + f"if n <= 0 then {total} else wide{width} (n - 1) "
        + pack(rotate, aggregate)
        + "."
    )


def fixture():
    functions = [
        "unsafe base.",
        "Wide.opaque : a -> a.",
        "Wide.fakeInt : Unit -> Int.",
        "Wide.cloneBool : Unit -> Bool.",
        "mark n = _ = print n; n.",
    ]
    branches = []
    for width in WIDTHS:
        functions.append(definition(width))

        def args(seed):
            return call_arguments(width, seed)

        functions.append(f"start{width} n = wide{width} n " + args(1) + ".")
        branches.append(f'["w{width}"] -> print (start{width} {STEPS})')
        if width == 64:
            for seed in (1, 2, 3):
                functions.append(
                    f"actor{seed} parent self = send parent (wide64 {STEPS + seed} {args(seed)})."
                )
            functions.append(f"dynamic64 f n = f n {args(3)}.")
            branches.append(
                f'["dynamic"] -> print (dynamic64 (Wide.opaque wide64) {STEPS})'
            )
            params64 = args(1).split()  # seed one has only positive Ints.
            bad = list(params64)
            bad[-1] = "(Wide.fakeInt Unit)"
            branches.append('["guard"] -> print (wide64 (0 - 1) ' + " ".join(bad) + ")")
            clone = list(params64)
            clone[59] = "(Wide.cloneBool Unit)"
            branches.append('["bool"] -> print (wide64 0 ' + " ".join(clone) + ")")
            params64[-1] = "(mark 4611686018427387903)"
            branches.append(
                '["overflow"] -> _ = print 71; print (wide64 0 '
                + " ".join(params64)
                + ")"
            )
            branches.append(
                '["actors"] -> me = myself 0; a = spawn (actor1 me); b = spawn (actor2 me); c = spawn (actor3 me); x = receiveFrom me a; y = receiveFrom me b; z = receiveFrom me c; print "{keep x} {keep y} {keep z}"'
            )
    return (
        "\n".join(functions)
        + "\nmain = case Sys.args Unit of\n"
        + "\n  | ".join([*branches, '_ -> error "unknown case"'])
        + ".\n"
    )


def module_boundary(compiler, directory, target, env, enabled, rows):
    options = ["--target=" + target] if target else []
    name = "wide-enabled" if enabled else "wide-general"
    module = directory / (
        name + (".dylib" if os.uname().sysname == "Darwin" else ".so")
    )
    public = directory / "public.fpr"
    public.write_text("unsafe base.\n" + definition(64) + "\n")
    result = run([compiler, "build", public, "--module", *options, "-o", module], env)
    assert result.returncode == 0, result.stderr[-3000:]
    caller = directory / "caller.fpr"
    caller.write_text(
        'unsafe base.\nN = use "std/native".\nR = use "std/reload".\n'
        "ok r = case r of Ok u -> u | Err why -> error why.\n"
        f'main = _ = ok (N.attach "{module}"); f = R.bindAt 0 "wide64"; '
        f"print (f {STEPS} {call_arguments(64, 3)}).\n"
    )
    opposite = dict(env, FPR_NO_SCALAR_WORKERS="1" if enabled else "0")
    exe = directory / ("caller-" + name)
    result = run(
        [compiler, "build", caller, "--harts", "4", *options, "-o", exe], opposite
    )
    assert result.returncode == 0, result.stderr[-3000:]
    for harts in (1, 4):
        result = run([exe], dict(opposite, FPR_HARTS=str(harts)))
        assert (
            result.returncode == 0
            and result.stdout == str(answer(64, STEPS, 3)) + "\n"
            and not result.stderr
        ), result
        rows.append(
            dict(
                case="separate-module",
                enabled=enabled,
                harts=harts,
                stdout=result.stdout,
            )
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=ROOT / "fpr")
    parser.add_argument("--before", action="store_true")
    parser.add_argument("--target", choices=["macos-x86_64"])
    parser.add_argument("--record", type=Path)
    args = parser.parse_args()
    compiler = args.compiler.resolve()
    rows = []
    outcomes = {}
    cases = {f"w{w}": str(answer(w, STEPS, 1)) + "\n" for w in WIDTHS}
    cases.update(
        guard="777\n",
        bool=str(answer(64, 0, 1) + 60 * 24) + "\n",
        dynamic=str(answer(64, STEPS, 3)) + "\n",
        actors=" ".join(str(answer(64, STEPS + s, s)) for s in (1, 2, 3)) + "\n",
        overflow="71\n4611686018427387903\n",
    )
    with tempfile.TemporaryDirectory(prefix="fpr-wide-scalar-") as tmp:
        tmp = Path(tmp)
        src = tmp / "wide.fpr"
        src.write_text(fixture())
        hal = tmp / "opaque.c"
        hal.write_text(
            '#include "fpr.h"\nstatic V identity(V x){return x;}\nstatic V bad(V u){(void)u;return (V)&fpr_unit;}\nstatic V boolean(V u){(void)u;static const uint64_t t=((uint64_t)1<<32)|1;return (V)&t;}\nFPR_FN(fpr_g_Wide_x2efakeInt,bad,1);\nFPR_FN(fpr_g_Wide_x2ecloneBool,boolean,1);\nFPR_FN(fpr_g_Wide_x2eopaque,identity,1);\n'
        )
        env = {k: v for k, v in os.environ.items() if not k.startswith("FPR_")}
        env.update(
            FPR_HOME=str(ROOT),
            FPR_PATH=str(ROOT),
            XDG_CACHE_HOME=str(tmp / "cache"),
            FPR_NO_INLINE="1",
        )
        for enabled in (False, True):
            mode = dict(env, FPR_NO_SCALAR_WORKERS="0" if enabled else "1")
            exe = tmp / f"wide-{enabled}"
            p = run(
                [
                    compiler,
                    "build",
                    src,
                    "--harts",
                    "4",
                    "--keep",
                    "--with",
                    hal,
                    *(["--target=" + args.target] if args.target else []),
                    "-o",
                    exe,
                ],
                mode,
            )
            assert p.returncode == 0, p.stderr[-4000:]
            files = list((tmp / "cache/fpr/build").glob("wide-*.s"))
            assert len(files) == 1
            asm = files[0].read_text()
            files[0].unlink()
            emitted = sorted(
                map(int, re.findall(r"^# fn \$worker\.scalar\.wide(\d+) ", asm, re.M))
            )
            assert emitted == [
                w for w in WIDTHS if enabled and (not args.before or w <= 8)
            ], (enabled, emitted)
            for harts in (1, 4):
                for case, expected in cases.items():
                    p = run([exe, case], dict(mode, FPR_HARTS=str(harts)))
                    assert p.stdout == expected, (
                        case,
                        harts,
                        p.stdout,
                        expected,
                        p.stderr,
                    )
                    if case == "overflow":
                        assert p.returncode != 0 and "Int overflow" in p.stderr, p
                    else:
                        assert p.returncode == 0 and not p.stderr, p
                    value = (p.stdout, p.stderr, p.returncode)
                    if enabled:
                        assert outcomes[harts, case] == value, (
                            case,
                            value,
                            outcomes[harts, case],
                        )
                    else:
                        outcomes[harts, case] = value
                    rows.append(
                        dict(
                            enabled=enabled,
                            harts=harts,
                            case=case,
                            stdout=p.stdout,
                            stderr=p.stderr,
                            exit=p.returncode,
                            emitted=emitted,
                        )
                    )
            probe = tmp / "fuel.c"
            probe.write_text("""#include "fpr.h"
#include "sched_probe.h"
#include <stdatomic.h>
#include <stdio.h>
static _Atomic uint64_t exhausted;
void fpr_sched_probe(unsigned event, uw hart, uw actor) {
    (void)hart;
    if (event == FPR_SCHED_FUEL && actor < 64)
        atomic_fetch_or_explicit(&exhausted, UINT64_C(1)<<actor,memory_order_relaxed);
}
__attribute__((destructor)) static void report(void) {
    fprintf(stderr,"WIDE_FUEL_MASK %llu\\n",(unsigned long long)atomic_load(&exhausted));
}
""")
            # --cc selects a distinct, instrumented runtime cache as well as the HAL.
            cc = tmp / "probe-cc"
            cc.write_text(
                '#!/usr/bin/env python3\nimport os,sys\nos.execvp("cc", ["cc", "-DFPR_SCHED_PROBE=1", *sys.argv[1:]])\n'
            )
            cc.chmod(0o755)
            instrumented = tmp / f"fuel-{enabled}"
            p = run(
                [
                    compiler,
                    "build",
                    src,
                    "--harts",
                    "4",
                    "--with",
                    hal,
                    "--with",
                    probe,
                    "--cc",
                    cc,
                    *(["--target=" + args.target] if args.target else []),
                    "-o",
                    instrumented,
                ],
                mode,
            )
            assert p.returncode == 0, p.stderr[-3000:]
            for harts in (1, 4):
                p = run([instrumented, "actors"], dict(mode, FPR_HARTS=str(harts)))
                mask = re.fullmatch(r"WIDE_FUEL_MASK (\d+)\n", p.stderr)
                assert (
                    p.returncode == 0
                    and p.stdout == cases["actors"]
                    and mask
                    and int(mask[1]).bit_count() >= 3
                ), (harts, p)
                rows.append(
                    dict(
                        enabled=enabled,
                        harts=harts,
                        case="observed-actor-fuel",
                        actor_mask=int(mask[1]),
                        stdout=p.stdout,
                    )
                )
            module_boundary(compiler, tmp, args.target, mode, enabled, rows)
            print(
                "Wide scalar ABI:",
                emitted,
                "direct, dynamic, actors and overflow on 1/4 workers PASS",
                flush=True,
            )
    if args.record:
        args.record.write_text(
            json.dumps(
                dict(
                    compiler_sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(),
                    source_sha256=hashlib.sha256(fixture().encode()).hexdigest(),
                    target=args.target or "host",
                    rows=rows,
                ),
                indent=2,
            )
            + "\n"
        )


if __name__ == "__main__":
    main()
