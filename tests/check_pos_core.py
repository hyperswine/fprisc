#!/usr/bin/env python3
"""POS arithmetic: independent boundary oracle, contracts and proven budgets.

Uses the existing compiler executable. The suite deliberately does not rebuild
it, so it can also run against a selected compiler build in a larger check.
"""
import os
from pathlib import Path
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = ROOT / "fpr"
CORE = ROOT / "examples" / "pos1_core.fpr"
MAX = (1 << 62) - 1
MIN = -(1 << 62)


def run(args, env, timeout=180):
    return subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=timeout)


def literal(rows):
    return "[" + ",".join(f"({a},{b})" for a, b in rows) + "]"


with tempfile.TemporaryDirectory(prefix="fpr-pos-core-") as tmp:
    d = Path(tmp)
    env = {**os.environ, "XDG_CACHE_HOME": os.environ.get("XDG_CACHE_HOME", str(d / "cache"))}
    random_source = random.Random(170026)
    extreme = [MIN, -1, 0, 1, 998, 999, 1000, 9998, 9999, 10000, MAX]
    quantities = [(a, b) for a in extreme for b in extreme]
    quantities += [(random_source.randint(-100, 20000), random_source.randint(-100, 2000))
                   for _ in range(200)]
    cash = [(a, b) for a in [MIN, -1, 0, 1, 550, MAX] for b in [MIN, -1, 0, 1, 549, 550, 1000, MAX]]
    cash += [(random_source.randint(0, MAX), random_source.randint(0, MAX)) for _ in range(100)]
    stocks = [(a, b) for a in extreme for b in [-1, 0, 1, 2, 999, 1000, MAX]]
    stocks += [(random_source.randint(0, 10000), random_source.randint(1, 999)) for _ in range(100)]
    source = d / "oracle.fpr"
    source.write_text(f'''profile base.
Core = use "{CORE.with_suffix('')}".
List = use "std/list".
emitQ (stock, requested) = print "q {{stock}} {{requested}} {{Core.quantity stock requested}}".
emitCash (total, tendered) = print "c {{total}} {{tendered}} {{Core.cash total tendered}}".
emitStock (stock, delta) = print "s {{stock}} {{delta}} {{Core.restock stock delta}}".
main =
  _ = List.fold (fn ignored row -> emitQ row) Unit {literal(quantities)};
  _ = List.fold (fn ignored row -> emitCash row) Unit {literal(cash)};
  _ = List.fold (fn ignored row -> emitStock row) Unit {literal(stocks)};
  _ = print (List.map (Core.boundedQuantity 3) [0,2,4,999]);
  _ = print (List.map (Core.difference 0) [0,1,{MAX}]);
  alias = Core.addStock;
  print (alias 9998 1).
''')
    image = d / "oracle"
    built = run([FPR, "build", source, "-o", image], env)
    assert built.returncode == 0, built.stdout + built.stderr
    for harts in ("1", "4"):
        result = run([image], {**env, "FPR_HARTS": harts})
        assert result.returncode == 0, result.stdout + result.stderr
        expected = []
        for stock, requested in quantities:
            expected.append(f"q {stock} {requested} {max(0, min(stock, requested, 999))}")
        for total, tendered in cash:
            value = ("InvalidCash" if min(total, tendered) < 0 else
                     f"Short {total - tendered}" if tendered < total else
                     f"Change {tendered - total}")
            expected.append(f"c {total} {tendered} {value}")
        for stock, delta in stocks:
            value = ("BadDelta" if not 1 <= delta <= 999 else
                     "FullShelf" if not 0 <= stock <= 9999 or stock + delta > 9999 else
                     f"Added {stock + delta}")
            expected.append(f"s {stock} {delta} {value}")
        expected += ["[0, 2, 3, 3]", f"[0, -1, {-MAX}]", "Added 9999"]
        assert result.stdout.splitlines() == expected, result.stdout + result.stderr
    print("POS core: independent quantity/cash/restock oracle, full Int boundaries, one/four harts: PASS")

    # Exercise the actual register's callers, with an in-memory model. This
    # commits only pending journal lines; it opens no store or listening port.
    app_source = d / "app.fpr"
    app_source.write_text(f'''profile base.
App = use "{ROOT / 'examples' / 'pos1'}".
List = use "std/list".
main =
  model = App.seed |> App.foldE (fn text state -> App.apply state text) App.initModel;
  session = {{App.noSess | sid = 1, cashier = "ana", cart = [("FW",2),("BR",1)]}};
  started = App.sPut model session;
  paid = App.checkout started 1 session 0 2000;
  cashier = App.sGet paid.sess 1;
  _ = print "cash {{paid.nsale}} {{paid.revenue}} {{App.stockOf paid.cat "FW"}} {{App.stockOf paid.cat "BR"}}";
  _ = print cashier.toast;
  short = App.checkout started 1 session 0 1000;
  shortSession = App.sGet short.sess 1;
  _ = print "short {{short.nsale}} {{App.stockOf short.cat "FW"}} {{shortSession.toast}}";
  card = App.checkout started 1 session 1 0;
  _ = print "card {{card.nsale}} {{card.revenue}}";
  added = App.restock started 1 session "FW" 3;
  addedSession = App.sGet added.sess 1;
  _ = print "stock {{App.stockOf added.cat "FW"}} {{addedSession.toast}}";
  huge = {{started | cat = App.mapP started.cat "FW" (fn product -> {{product | stock = {MAX}}})}};
  refused = App.restock huge 1 session "FW" 1;
  refusedSession = App.sGet refused.sess 1;
  _ = print "full {{List.length refused.pend}} {{refusedSession.toast}}";
  invalid = App.checkout started 1 session 0 (-1);
  invalidSession = App.sGet invalid.sess 1;
  print "invalid {{invalid.nsale}} {{invalidSession.toast}}".
''')
    app_image = d / "app"
    built = run([FPR, "build", app_source, "-o", app_image], env)
    assert built.returncode == 0, built.stdout + built.stderr
    result = run([app_image], env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.splitlines() == [
        "cash 1 1760 10 11",
        "first sale of the day: receipt #1 for 17.60   change 2.40",
        "short 0 12 cash short by 7.60",
        "card 1 1760",
        "stock 15 flat white: +3, now 15",
        "full 0 flat white: the shelf holds 9999",
        "invalid 0 invalid cash amount",
    ], result.stdout + result.stderr
    print("POS app: checkout, stock, receipt totals, change and ordinary refusals: PASS")

    # Build the real module's public contracts and scalar resource promises.
    budget = run([FPR, "build", "--module", "--cost", CORE, "-o", d / "core-module"], env)
    assert budget.returncode == 0, budget.stdout + budget.stderr
    for name, work, alloc in [("boundedQuantity", 3, 0), ("difference", 1, 0), ("addStock", 7, 16)]:
        for kind, bound in [("work", work), ("alloc", alloc)]:
            claim = f"{name}: declared {kind} <= {bound}   derived {bound}   PROVEN"
            assert claim in budget.stdout, budget.stdout
    print("POS core: six scalar work/allocation declarations proved: PASS")

    # Bypassing normal validation is a programmer error, for either scalar
    # argument. Contract checks must also survive taking an imported function
    # as a value, which is the higher-order enforcement regression.
    bad_calls = [
        ("quantity-stock", "Core.boundedQuantity (-1) 1", "boundedQuantity"),
        ("quantity-request", "Core.boundedQuantity 1 1000", "boundedQuantity"),
        ("cash-left", "Core.difference (-1) 0", "difference"),
        ("cash-right", "Core.difference 0 (-1)", "difference"),
        ("restock-stock", "Core.addStock 10000 1", "addStock"),
        ("restock-delta", "Core.addStock 0 0", "addStock"),
        ("quantity-alias", "f 1 1000", "boundedQuantity"),
        ("cash-map", "List.map (Core.difference 0) [-1]", "difference"),
    ]
    for label, call, name in bad_calls:
        bad = d / f"bad-{label}.fpr"
        binding = "f = Core.boundedQuantity; " if label == "quantity-alias" else ""
        bad.write_text(f'''profile base.
Core = use "{CORE.with_suffix('')}".
List = use "std/list".
main = {binding}print ({call}).
''')
        bad_image = d / f"bad-{label}"
        built = run([FPR, "build", bad, "-o", bad_image], env)
        assert built.returncode == 0, built.stdout + built.stderr
        result = run([bad_image], env)
        assert result.returncode != 0, f"{label} bypassed its contract: {result.stdout}{result.stderr}"
        diagnostic = result.stdout + result.stderr
        assert "precondition violated" in diagnostic and name in diagnostic, diagnostic
    print("POS core: direct, aliased and mapped invalid contracts refuse by name: PASS")
