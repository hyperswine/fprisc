"""Shared execution/linkage support for focused x64 probes, not a macOS backend."""
import os
import platform
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(args, env=None, timeout=240):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, (args, p.returncode, p.stdout[-4000:], p.stderr[-4000:])
    return p.stdout


def host():
    mac = platform.system() == 'Darwin'
    if platform.machine() in ('x86_64', 'AMD64'):
        return mac, [], 'native x86-64'
    if mac and subprocess.run(['arch', '-x86_64', '/usr/bin/true'],
                              capture_output=True).returncode == 0:
        return True, ['arch', '-x86_64'], 'Rosetta x86-64'
    return None


def environment(cache):
    # Set every exercised optimization explicitly, independent of the shell.
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               XDG_CACHE_HOME=str(cache), FPR_NO_INLINE='1',
               FPR_NO_FIELD_WORKERS='1', FPR_NO_SCALAR_WORKERS='1',
               FPR_NO_REGISTERS='1', FPR_RETAINED_REGISTERS='0',
               FPR_COSTED_REGISTERS='0', FPR_COMPACT_FRAMES='0',
               FPR_SELF_LOOPS='0')
    env.pop('FPR_FOREIGN', None)
    env.pop('FPR_TYPED_IR', None)
    return env


def adapt(assembly, mac):
    # Single-threaded harness cells replace Linux TLS on BOTH platforms.
    # Reject leftover ELF relocations rather than silently expanding scope.
    for symbol, cell in [('fpr_posix_hart', 'probe_hart'),
                         ('fpr_x64_a6', 'probe_a6'), ('fpr_x64_a7', 'probe_a7')]:
        assembly = assembly.replace('%fs:' + symbol + '@tpoff', cell + '(%rip)')
    instructions = '\n'.join(line.split('#', 1)[0] for line in assembly.splitlines())
    assert '@' not in instructions and '%fs:' not in instructions, 'unsupported linkage in x64 probe'
    if mac:
        assembly = re.sub(r'\b(?:fpr_|probe_)[A-Za-z0-9_]+',
                          lambda m: '_' + m[0], assembly)
    return assembly


def link(sources, executable, mac, env):
    run([shutil.which('clang') or 'cc', *(['-arch', 'x86_64'] if mac else []),
         '-O2', *sources, '-o', executable], env)
    if mac:
        run(['codesign', '--force', '--sign', '-', executable], env)
