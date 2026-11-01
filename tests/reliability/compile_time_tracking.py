#!/usr/bin/env python3
"""Report-only compile-time tracking (#39 item D): vecwide on every run,
clientstate (minutes) only when RELIABILITY_FULL=1 (the nightly run).
Never fails on a number; fails only if the measuring script itself breaks."""
import os, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
args = [sys.executable, str(ROOT / 'tests' / 'check_compile_budget.py'), '--tracked']
if os.environ.get('RELIABILITY_FULL') == '1': args.append('--nightly')
sys.exit(subprocess.run(args, cwd=ROOT).returncode)
