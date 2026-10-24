#!/usr/bin/env python3
"""Checked inference facts and lexical identity contracts."""
import os
from pathlib import Path
import shutil
import subprocess
ROOT=Path(__file__).resolve().parents[1]
env=dict(os.environ)
for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig','/usr/local/opt/libarchive/lib/pkgconfig'):
    if Path(keg).is_dir():
        env['PKG_CONFIG_PATH']=keg+':'+env.get('PKG_CONFIG_PATH','')
        break
ghc=['cabal','exec','--','runghc'] if shutil.which('cabal') else ['runghc']
subprocess.run([*ghc,'-w','-icompiler','tests/InferenceEvidence.hs'],cwd=ROOT,env=env,check=True,timeout=180)
