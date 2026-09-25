/* esp.c (esp-idf) -- the board, as FP-RISC primitives.
 *
 * Declared by a program (or std module) as signatures with no body --
 *   Esp.core : Unit -> Int .
 * -- and linked here, the way any host facility is reached (docs/HAL.md).
 *
 * Ints are 31 bits on rv32 (a tagged word): times are kept in units that
 * fit: milliseconds since boot wrap after ~12 days.  The Base builtins
 * (Sys.args, env, exit, readLine, stderr, timeUs) are machine/posix/base.c,
 * shared with the posix system. */
#include "fpr.h"
#include "esp_timer.h"
#include "esp_cpu.h"
#include "esp_heap_caps.h"
#include "esp_random.h"

static V e_core(V u) { (void)u; return TAG((sw)esp_cpu_get_core_id()); }
FPR_FN(fpr_g_Esp_x2ecore, e_core, 1);

static V e_ms(V u) { (void)u; return TAG((sw)((esp_timer_get_time() / 1000) & 0x3fffffff)); }
FPR_FN(fpr_g_Esp_x2ems, e_ms, 1);

static V e_free_kb(V u) { (void)u; return TAG((sw)(esp_get_free_heap_size() >> 10)); }
FPR_FN(fpr_g_Esp_x2efreeKb, e_free_kb, 1);

/* Esp.random: 30 bits from the hardware RNG (esp_random) -- a non-negative Int */
static V e_random(V u) { (void)u; return TAG((sw)(esp_random() & 0x3fffffff)); }
FPR_FN(fpr_g_Esp_x2erandom, e_random, 1);
