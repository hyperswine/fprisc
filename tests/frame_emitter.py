"""One content-addressed, locked Haskell helper for all three frame suites.

Only the test generator is shared. Generated assembly, objects, executables and
FP-RISC caches keep each oracle's existing private directories and assertions.
"""
import fcntl
import hashlib
from pathlib import Path
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ('FrameEmitters.hs', 'EmitA64Frames.hs', 'EmitX64Frames.hs', 'EmitRVFrames.hs')


def build_emitter(env, cache=None):
    cache = Path(cache) if cache else ROOT / 'build/test-helpers/frames'
    # Cabal's selected compiler and installed package ABIs are part of the key.
    # Do not reuse a helper after a toolchain/dependency switch.
    began = time.monotonic()
    info = subprocess.check_output(['cabal', 'exec', '--', 'ghc', '--info'], cwd=ROOT, env=env)
    packages = subprocess.check_output(['cabal', 'exec', '--', 'sh', '-c', 'ghc-pkg dump'], cwd=ROOT, env=env)
    digest = hashlib.sha256(info + packages)
    inputs = sorted((ROOT / 'compiler').rglob('*.hs')) + [ROOT / 'tests' / p for p in SOURCES] + [Path(__file__)]
    inputs += [ROOT / p for p in ('fp-risc.cabal', 'cabal.project', 'cabal.project.local',
                                   'dist-newstyle/cache/plan.json') if (ROOT / p).is_file()]
    for path in inputs:
        digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes())
    key = digest.hexdigest()
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / key
    exe = destination / 'emit'
    with (cache / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if exe.is_file():
            print(f'frame emitter: reused ({time.monotonic()-began:.2f} s)', flush=True)
            return exe
        # Publish only a fully linked binary. Failed builds and killed processes
        # cannot leave a cache hit; different suites never race GHC's Main.o.
        with tempfile.TemporaryDirectory(prefix='compile-', dir=cache) as tmp:
            tmp = Path(tmp)
            result = subprocess.run(
                ['cabal', 'exec', '--', 'ghc', '-O1', '-w', '-icompiler', '-itests',
                 '-outputdir', str(tmp / 'ghc'), 'tests/FrameEmitters.hs', '-o', str(tmp / 'emit')],
                cwd=ROOT, env=env, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
            destination.mkdir(exist_ok=True)
            os.replace(tmp / 'emit', exe)
    print(f'frame emitter: built ({time.monotonic()-began:.2f} s)', flush=True)
    return exe
