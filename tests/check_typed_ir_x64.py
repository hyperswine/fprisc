#!/usr/bin/env python3
"""Shared IR checks plus direct x64 runtime integration on a matching host."""
import runpy
import sys
from pathlib import Path
sys.argv[1:1] = ['--backend', 'x64']
runpy.run_path(str(Path(__file__).with_name('check_typed_ir_native.py')), run_name='__main__')
