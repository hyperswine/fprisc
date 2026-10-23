#!/usr/bin/env python3
"""Paired cost of adding d8..d15 to the hosted A64 context switch.

Measures direct hot-context switches, excluding scheduler/GC and hart-layout
cache effects. Both variants use identical 24-word storage to isolate the
save/restore instructions. The integer variant uses FPR_QOSAPP's old sequence.
"""
import argparse
import json
import platform
import random
import statistics
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = r'''
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
static uintptr_t a[24],b[24],stack[16384];
extern void fpr_ctx_switch(uintptr_t*,uintptr_t*);
static void other(void) { for (;;) fpr_ctx_switch(b,a); }
static uint64_t ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000u+t.tv_nsec; }
int main(int argc,char **argv) {
  unsigned long n=argc>1?strtoul(argv[1],0,10):10000000;
  b[0]=(uintptr_t)other; b[1]=(uintptr_t)(stack+16384);
  for (unsigned long i=0;i<10000;i++) fpr_ctx_switch(a,b);
  uint64_t start=ns();
  for (unsigned long i=0;i<n;i++) fpr_ctx_switch(a,b);
  printf("%llu\n",(unsigned long long)(ns()-start));
}
'''

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--runs',type=int,default=31)
    ap.add_argument('--round-trips',type=int,default=10000000)
    args=ap.parse_args()
    if platform.machine() not in ('arm64','aarch64'):
        ap.error('requires native AArch64')
    if args.runs < 3 or args.round_trips < 1:
        ap.error('requires at least 3 runs and a positive round-trip count')
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    source=out/'bench.c';source.write_text(SOURCE)
    for variant in ('integer','fp'):
        subprocess.run(['clang','-O2','-ffixed-x28',*(['-DFPR_QOSAPP'] if variant=='integer' else []),str(source),str(ROOT/'machine/unix/ctx_a64.S'),'-o',str(out/variant)],check=True)
    rng=random.Random(7208);rows=[]
    for n in range(args.runs):
        variants=['integer','fp'];rng.shuffle(variants);row={}
        for v in variants:
            row[v]=int(subprocess.check_output([str(out/v),str(args.round_trips)],text=True,timeout=60))
        rows.append(row)
        print(f'{n+1}/{args.runs}: '+str(row),flush=True)
    ratios=[r['fp']/r['integer'] for r in rows]
    deltas=[(r['fp']-r['integer'])/(2*args.round_trips) for r in rows]
    boots=sorted(statistics.median(rng.choices(ratios,k=len(ratios))) for _ in range(10000))
    result={'host':platform.platform(),'runs':args.runs,'round_trips':args.round_trips,
            'scope':__doc__,'rounds_ns':rows,'median_paired_ratio':statistics.median(ratios),
            'ci95':[boots[250],boots[9749]],'median_extra_ns_per_switch':statistics.median(deltas),
            'median_ns_per_switch':{v:statistics.median(r[v] for r in rows)/(2*args.round_trips) for v in ('integer','fp')}}
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='rounds_ns'},indent=2))

if __name__=='__main__':
    main()
