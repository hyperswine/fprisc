#!/usr/bin/env python3
"""Checked inference facts and lexical identity contracts."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
env=dict(os.environ)
for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig','/usr/local/opt/libarchive/lib/pkgconfig'):
    if Path(keg).is_dir():
        env['PKG_CONFIG_PATH']=keg+':'+env.get('PKG_CONFIG_PATH','')
        break
sys.path.insert(0, str(ROOT / 'tests'))
from haskell_units import run_units
run_units(['InferenceEvidence'], env, timeout=180)
