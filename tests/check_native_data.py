#!/usr/bin/env python3
"""Static-data layouts compared with independent predecessor snapshots."""
import os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
 env=os.environ.copy()
 for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig','/usr/local/opt/libarchive/lib/pkgconfig'):
  if Path(keg).is_dir():env['PKG_CONFIG_PATH']=keg+':'+env.get('PKG_CONFIG_PATH','');break
 with tempfile.TemporaryDirectory(prefix='fpr-native-data-') as d:
  out=Path(d);exe=out/'native-data'
  subprocess.run(['cabal','exec','--','ghc','-O0','-icompiler','-outputdir',str(out),'tests/NativeData.hs','-o',str(exe)],cwd=ROOT,env=env,check=True,timeout=240)
  subprocess.run([str(exe)],cwd=ROOT,check=True,timeout=30)

if __name__=='__main__':main()
