/* Unix terminal lifecycle, including signal-based restoration. */
#include "os_value.h"
#include <signal.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

/* ---- the terminal (std/term.fpr) -------------------------------------------
 * Raw mode is the whole of what a TUI needs from the machine: keys as they are
 * pressed, nothing echoed, reads that never wait (VMIN = VTIME = 0, so Os.ready
 * and Os.read on descriptor 0 behave as they do on a socket).  ISIG stays off
 * too: ^C is a KEY the program sees and decides about.  The terminal is put
 * back however the program ends. */
static struct termios tty_saved;
static int tty_is_raw;
static void tty_restore(void) {
  if (tty_is_raw) { tcsetattr(0, TCSAFLUSH, &tty_saved); tty_is_raw = 0; }
}
static void tty_signal(int sig) {
  tty_restore();
  signal(sig, SIG_DFL);
  raise(sig);
}
static V h_tty_raw(V onv) {
  int on = !ISINT(onv) && ((hdr_t *)onv)->var != 0;
  if (!on) { tty_restore(); return os_ok((V)&fpr_unit); }
  if (tty_is_raw) return os_ok((V)&fpr_unit);
  if (!isatty(0)) return os_err("stdin is not a terminal");
  if (tcgetattr(0, &tty_saved)) return os_errno();
  struct termios t = tty_saved;
  t.c_lflag &= (tcflag_t) ~(ICANON | ECHO | ISIG | IEXTEN);
  t.c_iflag &= (tcflag_t) ~(IXON | ICRNL);
  t.c_cc[VMIN] = 0;
  t.c_cc[VTIME] = 0;
  if (tcsetattr(0, TCSAFLUSH, &t)) return os_errno();
  static int hooked;
  if (!hooked) { hooked = 1; atexit(tty_restore); signal(SIGINT, tty_signal); signal(SIGTERM, tty_signal); signal(SIGHUP, tty_signal); }
  tty_is_raw = 1;
  return os_ok((V)&fpr_unit);
}
FPR_FN(fpr_g_Os_x2ettyRaw, h_tty_raw, 1);

static V h_tty_size(V u) {
  (void)u;
  struct winsize ws = {0};
  int fd = isatty(1) ? 1 : (isatty(0) ? 0 : -1);
  if (fd < 0 || ioctl(fd, TIOCGWINSZ, &ws)) { ws.ws_col = 0; ws.ws_row = 0; }
  V f[2] = {TAG((sw)ws.ws_col), TAG((sw)ws.ws_row)};
  return os_cell(T_TUP2, 0, 2, f);
}
FPR_FN(fpr_g_Os_x2ettySize, h_tty_size, 1);
