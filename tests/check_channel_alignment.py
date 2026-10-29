#!/usr/bin/env python3
"""Channel carving/reuse at grant offsets, with runtime alignment sanitization.

The temporary actor copy supplies exact/larger grants only during the C probe.
Ordinary startup and the native actor programs use the real memory provider.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = r'''
static _Thread_local unsigned char ch_test_storage[16 * sizeof(chblk_t) + 4 * FPR_CACHELINE]
  __attribute__((aligned(FPR_CACHELINE)));
static _Thread_local uw ch_test_offset, ch_test_extra, ch_test_got, ch_test_requests;
#define CH_CHECK(ok, why) do { if (!(ok)) fpr_cpanic("channel alignment: " why); } while (0)
static void *ch_test_block(uw n) {
  CH_CHECK(n >= 4 * sizeof(chblk_t) + _Alignof(chblk_t) - 1, "grant lacks alignment headroom");
  ch_test_requests++;
  ch_test_got = n + ch_test_extra;
  CH_CHECK(FPR_CACHELINE + ch_test_offset + ch_test_got <= sizeof ch_test_storage, "fixture extent");
  return ch_test_storage + FPR_CACHELINE + ch_test_offset;
}
static uw ch_test_size(void *p) {
  CH_CHECK(p == ch_test_storage + FPR_CACHELINE + ch_test_offset, "size queried with adjusted grant pointer");
  return ch_test_got;
}
static void ch_test_aligned(chan_t *channels) {
  CH_CHECK(!((uw)channels % _Alignof(chblk_t)), "block alignment");
  for (uw i = 0; i < MAXSND; i++) {
    chan_t *c = &channels[i];
    CH_CHECK(!((uw)c % _Alignof(chan_t)), "channel alignment");
    CH_CHECK(!((uw)&c->rh % FPR_CACHELINE), "consumer cache line");
    CH_CHECK(!((uw)&c->rv0 % FPR_CACHELINE), "inline ring cache line");
    CH_CHECK(c->rh == 0 && c->rt == 0 && c->rv == &c->rv0, "channel initialization");
  }
}
static V ch_test_probe(V unused) {
  (void)unused;
  /* No actor creation/yield occurs inside this probe. Borrow only the list
   * heads, never their locks; restore them before returning to the program. */
  fpr_lock(&chb_lock);
  chblk_t *saved_limbo = chb_limbo; chb_limbo = 0;
  fpr_unlock(&chb_lock);
  fpr_lock(&chb_fl.mu);
  fpr_flnode_t *saved_free = chb_fl.head; chb_fl.head = 0;
  fpr_unlock(&chb_fl.mu);
  ch_test_active = 1;
  for (uw extra = 0; extra < 3; extra++) {
    for (uw off = 0; off < _Alignof(chblk_t); off++) {
      __builtin_memset(ch_test_storage, 0xa5, sizeof ch_test_storage);
      ch_test_offset = off;
      ch_test_extra = extra ? 2 * sizeof(chblk_t) - (extra == 2 ? _Alignof(chblk_t) - 1 : 0) : 0;
      ch_test_requests = 0;
      chan_t *first = chb_take();
      CH_CHECK(first && ch_test_requests == 1, "fresh carve");
      char *raw = (char *)ch_test_storage + FPR_CACHELINE + off;
      uw skip = (-(uw)raw) & (_Alignof(chblk_t) - 1);
      uw count = (ch_test_got - skip) / sizeof(chblk_t);
      uw expected = extra == 0 ? 4 : (extra == 1 || skip == 0 ? 6 : 5);
      CH_CHECK(count == expected, "lost cells in exact/larger/tight-tail grant");
      CH_CHECK((char *)first == raw + skip, "first cell extent");
      chan_t *seen[6] = {first};
      ch_test_aligned(first);
      for (uw i = 1; i < count; i++) {
        chan_t *channels = chb_take();
        CH_CHECK(ch_test_requests == 1, "freelist caused another grant");
        CH_CHECK((char *)channels >= raw + skip && (char *)channels + sizeof(chblk_t) <= raw + ch_test_got,
                 "freelist cell outside grant");
        for (uw j = 0; j < i; j++)
          CH_CHECK((char *)channels + sizeof(chblk_t) <= (char *)seen[j] ||
                   (char *)seen[j] + sizeof(chblk_t) <= (char *)channels, "overlapping cells");
        seen[i] = channels;
        ch_test_aligned(channels);
      }
      CH_CHECK(!chb_fl.head, "unconsumed or partial freelist cell");
      /* The fixture treats its own limbo entry as quiescent. Epoch ordering
       * is unchanged in production; here we check the reused cell's layout. */
      chb_limbo_put(first);
      CH_CHECK(chb_take() == first && ch_test_requests == 1 && !chb_limbo, "limbo reuse");
      ch_test_aligned(first);
      char *used_end = raw + skip + count * sizeof(chblk_t);
      for (char *p = (char *)ch_test_storage; p < raw + skip; p++)
        CH_CHECK((unsigned char)*p == 0xa5, "write before aligned carve");
      for (char *p = used_end; p < (char *)ch_test_storage + sizeof ch_test_storage; p++)
        CH_CHECK((unsigned char)*p == 0xa5, "write after whole-cell carve");
    }
  }
  ch_test_active = 0;
  fpr_lock(&chb_fl.mu); chb_fl.head = saved_free; fpr_unlock(&chb_fl.mu);
  fpr_lock(&chb_lock); chb_limbo = saved_limbo; fpr_unlock(&chb_lock);
  return TAG(1);
}
FPR_FN(fpr_g_Channel_x2echeck, ch_test_probe, 1);
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--actors-source', type=Path, default=ROOT / 'runtime/actors.c')
    ap.add_argument('--cacheline', type=int, action='append', choices=(64, 128))
    args = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='fpr-channel-align-') as directory:
        tmp = Path(directory)
        source = args.actors_source.read_text()
        declarations = ('static _Thread_local int ch_test_active;\n'
                        'static void *ch_test_block(uw n);\nstatic uw ch_test_size(void *p);\n')
        marker = 'static void *big_block_d(uw n, int direct) {'
        assert source.count(marker) == 1
        source = source.replace(marker, declarations + marker + '\n  if (ch_test_active) return ch_test_block(n);')
        marker = 'static uw big_block_size(void *p, uw want) {'
        assert source.count(marker) == 1
        source = source.replace(marker, marker + '\n  if (ch_test_active) return ch_test_size(p);')
        marker = 'static int chb_matured(chblk_t *b) {'
        assert source.count(marker) == 1
        source = source.replace(marker, marker + '\n  if (ch_test_active) return 1;')
        actors = tmp / 'actors.c'
        actors.write_text(source + '\n' + PROBE)
        probe = tmp / 'probe.fpr'
        probe.write_text('unsafe base.\nChannel.check : Unit -> Int.\nmain = print (Channel.check Unit).\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp / 'cache')),
                   UBSAN_OPTIONS='halt_on_error=1')
        for line in args.cacheline or (64, 128):
            cc = tmp / ('cc-' + str(line))
            cc.write_text('#!/usr/bin/env python3\nimport os,sys\na=[' + repr(str(actors))
                          + ' if x.endswith("/runtime/actors.c") else x for x in sys.argv[1:]]\n'
                          + 'os.execvp("cc",["cc","-fsanitize=alignment","-DFPR_CACHELINE=' + str(line) + '",*a])\n')
            cc.chmod(0o755)
            for name, program in [('probe', probe), ('locality', ROOT / 'tests/base/locality.fpr'),
                                  ('inboxshared', ROOT / 'tests/base/inboxshared.fpr')]:
                exe = tmp / (name + '-' + str(line))
                b = subprocess.run([ROOT / 'fpr', 'build', program, '--harts', '4', '--cc', cc, '-o', exe],
                                   cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
                assert b.returncode == 0, b.stdout + b.stderr
                for harts in ('1', '4'):
                    p = subprocess.run([exe], cwd=ROOT, env=dict(env, FPR_HARTS=harts, FPR_BLOCK_SPIN_NS='0'),
                                       capture_output=True, text=True, timeout=60)
                    assert p.returncode == 0 and not p.stderr, (line, name, harts, p.stdout, p.stderr)
                    if name == 'probe': assert p.stdout == '1\n', p.stdout
                    elif name == 'locality': assert p.stdout == 'locality 200030000\n', p.stdout
                    else: assert 'HOLDS' in p.stdout and 'PANIC' not in p.stdout, p.stdout
                print(f'channel alignment: cacheline={line} {name} 1/4 harts PASS', flush=True)


if __name__ == '__main__':
    main()
