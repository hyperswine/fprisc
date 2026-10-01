"""Sol tail calls: a known saturated call in tail position is a TailCall that
REPLACES the frame.  Before 2026-10-02 the VM stacked a Haskell continuation
per call (Call then Ret), so a measured countdown of n iterations held O(n)
memory: 1.8 GB per million.  Three shapes, each run at 3M iterations under a
peak-RSS ceiling well below the old growth:
  * a self tail call through a `measure`      (tabling-eligible: exercises
    the table-aware tail entry, whose probe used to keep a continuation)
  * mutual tail calls ping/pong              (tabling-ineligible)
  * the bytecode listing names TailCall and no Ret follows it
"""
from pathlib import Path
import os, platform, resource, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
subprocess.run(['make', 'fpr'], check=True, capture_output=True, timeout=300)
TMP = tempfile.TemporaryDirectory(prefix='fpr-soltail-')
N = 3_000_000
LIMIT_MB = 400  # the old VM needed ~5.4 GB here; the fixed one ~30 MB

SELF = f"""count : (n : Int | measure n) -> Int -> Int .
count n acc | n <= 0 = acc.
count n acc = count (n - 1) (acc + 1).
main = print (count {N} 0).
"""
MUTUAL = f"""ping : unsafe Int -> Int -> Int .
ping n acc = case n <= 0 of True -> acc | False -> pong (n - 1) (acc + 1).
pong : unsafe Int -> Int -> Int .
pong n acc = case n <= 0 of True -> acc | False -> ping (n - 1) (acc + 2).
main = print (ping {N} 0).
"""

def peak_mb():
    r = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    return r / (1024 * 1024) if platform.system() == 'Darwin' else r / 1024

def run(name, src, expect):
    f = Path(TMP.name) / f'{name}.sol'
    f.write_text(src)
    p = subprocess.run(['./fpr', 'sol', str(f)], capture_output=True, text=True, timeout=600)
    assert p.returncode == 0, f'{name}: {p.stdout}{p.stderr}'
    assert p.stdout.strip().splitlines()[-1] == str(expect), f'{name}: {p.stdout}'
    peak = peak_mb()
    # ru_maxrss over children is a running maximum: the make above counts
    # too, so the bound is on the whole, not a delta
    assert peak < LIMIT_MB, f'{name}: peak RSS {peak:.0f} MB, the frame is not being replaced'
    return peak

p1 = run('self', SELF, N)
p2 = run('mutual', MUTUAL, (N // 2) * 3)
listing = subprocess.run(['./fpr', 'compile', '--target=bytecode', str(Path(TMP.name) / 'self.sol')],
                         capture_output=True, text=True, timeout=120).stdout
body = listing[listing.index('count (arity'):]
body = body[:body.index('\n\n')] if '\n\n' in body else body
assert 'TailCall "count"' in body, body
assert body.rstrip().splitlines()[-1].split()[1] == 'TailCall', body
print(f'Sol tail calls: a measured self loop and a mutual ping/pong of {N:,} iterations run in bounded memory (peak {max(p1, p2):.0f} MB); the listing ends in TailCall with no Ret after it: PASS')
