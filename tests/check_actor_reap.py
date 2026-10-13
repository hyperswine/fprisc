#!/usr/bin/env python3
"""A detached dead actor may wake the memory actor during reclamation.

Compile the real backlog selector with a test reaper that re-enters its
admission queue. The old selector called it while holding that queue's lock.
"""
from pathlib import Path
import os, shlex, subprocess, sys, tempfile
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='fpr-reap-') as directory:
    tmp = Path(directory)
    source = (ROOT/'runtime/actors.c').read_text()
    begin = source.index('static void reap(acb_t *a) {')
    end = source.index('\nextern void fpr_ctx_switch', begin)
    source = source[:begin] + 'static void test_reap(acb_t *a);\nstatic void reap(acb_t *a) { test_reap(a); }\n' + source[end:]
    (tmp/'actors-reap.c').write_text(source)
    harness = r'''
#include <assert.h>
#include <stdio.h>
#include "actors-reap.c"
static acb_t dead1, dead2, ready, memory;
fpr_hart_t fpr_harts[FPR_NHARTS];
uw fpr_live_harts = 1;
FPR_TLS fpr_hart_t *fpr_posix_hart;
#define test_hart fpr_harts[0]
static int reaped;
static void test_reap(acb_t *a) {
  assert(a == &dead1 || a == &dead2);
  assert(!test_hart.bl_lock.v); /* deterministic failure on the old selector */
  reaped++;
  if (a == &dead1) backlog_add(&test_hart, &memory);
}
void hal_ipi_send(uw hart) { (void)hart; }
void hal_putc(char c) { (void)c; }
void fpr_cpanic(const char *why) { fprintf(stderr,"%s\n",why); __builtin_trap(); }
int main(void) {
  fpr_posix_hart = &test_hart;
  test_hart.id = 0; test_hart.lcg = 12345;
  dead1.var = dead2.var = ST_DEAD;
  ready.var = memory.var = ST_READY;
  ready.weight = memory.weight = 1; ready.prio = 1;
  backlog_add(&test_hart, &dead1);
  backlog_add(&test_hart, &ready);
  backlog_add(&test_hart, &dead2);
  assert(select_backlog(&test_hart) == &ready);
  assert(reaped == 2 && test_hart.bl_len == 1);
  assert(test_hart.bl_head == &memory && test_hart.bl_tail == &memory);
  assert(select_backlog(&test_hart) == &memory);
  assert(!test_hart.bl_len && !test_hart.bl_head && !test_hart.bl_tail);
  puts("actor reap: detached cleanup can re-enter admission PASS");
}
'''
    (tmp/'reap.c').write_text(harness)
    linker = '-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections'
    exe = tmp/'reap'
    subprocess.run([*shlex.split(os.environ.get('CC','cc')), '-O2', '-DFPR_POSIX',
                    '-ffunction-sections', '-fdata-sections', '-I', str(ROOT/'runtime'),
                    str(tmp/'reap.c'), linker, '-o', str(exe)],check=True,timeout=60)
    subprocess.run([exe],check=True,timeout=10)
