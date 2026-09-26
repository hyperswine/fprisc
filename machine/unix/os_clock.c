/* Hosted calendar clock: seconds since the epoch and the local zone's offset.
 * Separate from the filesystem because a 31-bit Int cannot hold today's
 * epoch seconds (rv32: ESP-IDF), and newlib has no tm_gmtoff: a board links
 * os_fs.c without this, and a program asking for the wall clock there fails
 * at link time by name rather than getting a wrong number. */
#include "os_value.h"
#include <time.h>

static V h_wall_clock(V u) { (void)u; return TAG((sw)time(0)); }
FPR_FN(fpr_g_Os_x2ewallClock, h_wall_clock, 1);
/* the local zone's offset from UTC at that instant, in seconds east (DST
 * included): the one thing a clock needs that only the OS knows */
static V h_tz_offset(V secs) {
  time_t t = (time_t)UNTAG(secs);
  struct tm tm;
  if (!localtime_r(&t, &tm)) return TAG(0);
  return TAG((sw)tm.tm_gmtoff);
}
FPR_FN(fpr_g_Os_x2etzOffset, h_tz_offset, 1);
