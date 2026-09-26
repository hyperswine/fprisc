/* gpio.c (platform/esp-idf) -- GPIO pins, for std/gpio.
 *
 * Reading is by REGISTER, and changes nothing: GpioHost.level is the pad's
 * input bit, GpioHost.info how the pin is configured right now.  A pin whose
 * input is not enabled reads 0 whatever the pad does -- info says which.
 * Configuring and driving (input, output, write) go through IDF's driver:
 * they change the pin, so use them only on pins the board leaves free.
 * These are register reads and short driver calls: no job, no broker. */
#include "fpr.h"
#include "hal/gpio_ll.h"
#include "soc/gpio_struct.h"
#include "driver/gpio.h"
#include "soc/soc_caps.h"

static int pin_ok(V p) { return ISINT(p) && UNTAG(p) >= 0 && UNTAG(p) < SOC_GPIO_PIN_COUNT; }

static V g_pins(V u) { (void)u; return TAG(SOC_GPIO_PIN_COUNT); }
FPR_FN(fpr_g_GpioHost_x2epins, g_pins, 1);

static V g_level(V p) {
  if (!pin_ok(p)) fpr_cpanic("Gpio.level: no such pin");
  return TAG((sw)gpio_ll_get_level(&GPIO, (uint32_t)UNTAG(p)));
}
FPR_FN(fpr_g_GpioHost_x2elevel, g_level, 1);

/* bit 0 input enabled, 1 output enabled, 2 pull-up, 3 pull-down, 4 open-drain,
 * bits 8.. the IO_MUX function (1 = GPIO) */
static V g_info(V p) {
  if (!pin_ok(p)) fpr_cpanic("Gpio.info: no such pin");
  bool pu, pd, ie, oe, od, slp;
  uint32_t drv, fun, sig;
  gpio_ll_get_io_config(&GPIO, (uint32_t)UNTAG(p), &pu, &pd, &ie, &oe, &od, &drv, &fun, &sig, &slp);
  return TAG((sw)(ie | oe << 1 | pu << 2 | pd << 3 | od << 4 | fun << 8));
}
FPR_FN(fpr_g_GpioHost_x2einfo, g_info, 1);

/* pull: 0 none, 1 up, 2 down */
static V g_input(V p, V pull) {
  if (!pin_ok(p)) fpr_cpanic("Gpio.input: no such pin");
  gpio_config_t c = {.pin_bit_mask = 1ULL << UNTAG(p), .mode = GPIO_MODE_INPUT,
                     .pull_up_en = UNTAG(pull) == 1, .pull_down_en = UNTAG(pull) == 2,
                     .intr_type = GPIO_INTR_DISABLE};
  return TAG((sw)gpio_config(&c));
}
FPR_FN(fpr_g_GpioHost_x2einput, g_input, 2);
static V g_output(V p) {
  if (!pin_ok(p)) fpr_cpanic("Gpio.output: no such pin");
  gpio_config_t c = {.pin_bit_mask = 1ULL << UNTAG(p), .mode = GPIO_MODE_INPUT_OUTPUT, .intr_type = GPIO_INTR_DISABLE};
  return TAG((sw)gpio_config(&c));
}
FPR_FN(fpr_g_GpioHost_x2eoutput, g_output, 1);
static V g_write(V p, V level) {
  if (!pin_ok(p)) fpr_cpanic("Gpio.write: no such pin");
  return TAG((sw)gpio_set_level((gpio_num_t)UNTAG(p), UNTAG(level) ? 1 : 0));
}
FPR_FN(fpr_g_GpioHost_x2ewrite, g_write, 2);
