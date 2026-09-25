/* esp.c (esp-idf) -- the board, as FP-RISC primitives.
 *
 * Declared by a program (or std module) as signatures with no body --
 *   Esp.core : Unit -> Int .
 * -- and linked here, the way any host facility is reached (docs/HAL.md).
 *
 * Ints are 31 bits on rv32 (a tagged word): times are kept in units that
 * fit.  Milliseconds since boot wrap after ~12 days; microseconds would
 * wrap after ~18 minutes, so Sys.timeUs is given only for short intervals. */
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

/* Sys.timeUs: microseconds since boot, modulo 2^30 (~18 minutes) */
static V s_time_us(V u) { (void)u; return TAG((sw)(esp_timer_get_time() & 0x3fffffff)); }
FPR_FN(fpr_g_Sys_x2etimeUs, s_time_us, 1);

/* ---- GPIO -----------------------------------------------------------------
 * Reading is by REGISTER, and changes nothing: Esp.gpioLevel is the pad's
 * input bit, Esp.gpioInfo how the pin is configured right now.  A pin whose
 * input is not enabled reads 0 whatever the pad does -- gpioInfo says which.
 * Configuring and driving (gpioInput, gpioOutput, gpioWrite) go through IDF's
 * driver: they change the pin, so use them only on pins the board leaves free. */
#include "hal/gpio_ll.h"
#include "soc/gpio_struct.h"
#include "driver/gpio.h"
#include "soc/soc_caps.h"

static int pin_ok(V p) { return ISINT(p) && UNTAG(p) >= 0 && UNTAG(p) < SOC_GPIO_PIN_COUNT; }

static V g_pins(V u) { (void)u; return TAG(SOC_GPIO_PIN_COUNT); }
FPR_FN(fpr_g_Esp_x2egpioPins, g_pins, 1);

static V g_level(V p) {
  if (!pin_ok(p)) fpr_cpanic("Esp.gpioLevel: no such pin");
  return TAG((sw)gpio_ll_get_level(&GPIO, (uint32_t)UNTAG(p)));
}
FPR_FN(fpr_g_Esp_x2egpioLevel, g_level, 1);

/* bit 0 input enabled, 1 output enabled, 2 pull-up, 3 pull-down, 4 open-drain,
 * bits 8.. the IO_MUX function (1 = GPIO) */
static V g_info(V p) {
  if (!pin_ok(p)) fpr_cpanic("Esp.gpioInfo: no such pin");
  bool pu, pd, ie, oe, od, slp;
  uint32_t drv, fun, sig;
  gpio_ll_get_io_config(&GPIO, (uint32_t)UNTAG(p), &pu, &pd, &ie, &oe, &od, &drv, &fun, &sig, &slp);
  return TAG((sw)(ie | oe << 1 | pu << 2 | pd << 3 | od << 4 | fun << 8));
}
FPR_FN(fpr_g_Esp_x2egpioInfo, g_info, 1);

/* pull: 0 none, 1 up, 2 down */
static V g_input(V p, V pull) {
  if (!pin_ok(p)) fpr_cpanic("Esp.gpioInput: no such pin");
  gpio_config_t c = {.pin_bit_mask = 1ULL << UNTAG(p), .mode = GPIO_MODE_INPUT,
                     .pull_up_en = UNTAG(pull) == 1, .pull_down_en = UNTAG(pull) == 2,
                     .intr_type = GPIO_INTR_DISABLE};
  return TAG((sw)gpio_config(&c));
}
FPR_FN(fpr_g_Esp_x2egpioInput, g_input, 2);
static V g_output(V p) {
  if (!pin_ok(p)) fpr_cpanic("Esp.gpioOutput: no such pin");
  gpio_config_t c = {.pin_bit_mask = 1ULL << UNTAG(p), .mode = GPIO_MODE_INPUT_OUTPUT, .intr_type = GPIO_INTR_DISABLE};
  return TAG((sw)gpio_config(&c));
}
FPR_FN(fpr_g_Esp_x2egpioOutput, g_output, 1);
static V g_write(V p, V level) {
  if (!pin_ok(p)) fpr_cpanic("Esp.gpioWrite: no such pin");
  return TAG((sw)gpio_set_level((gpio_num_t)UNTAG(p), UNTAG(level) ? 1 : 0));
}
FPR_FN(fpr_g_Esp_x2egpioWrite, g_write, 2);

/* Diagnostic stream used by shared libraries (including Poller fallback). */
#include <stdio.h>
static V s_stderr(V value) {
  if (ISINT(value) || TID(value) != T_STR) fpr_cpanic("Sys.stderr: expected String");
  const str_t *s = (const str_t *)value;
  fwrite(s->bytes, 1, s->len, stderr);
  fflush(stderr);
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Sys_x2estderr, s_stderr, 1);
