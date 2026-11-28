#include <errno.h>
#include "driver/gpio.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <string.h>
#include "bytes.h"

/* Header GPIOs on the C3 board. Exclude USB, flash and package-only pins. */
static bool header_pin(V pin) {
    if (!ISINT(pin)) return false;
    sw n = UNTAG(pin);
    return (n >= 0 && n <= 10) || n == 20 || n == 21;
}

static uint32_t inputs, outputs;

static V configure(V pin, V option, gpio_mode_t mode) {
    bool output = mode != GPIO_MODE_INPUT;
    if (!header_pin(pin) || !ISBOOL(option)) return TAG(-EINVAL);
    gpio_num_t n = UNTAG(pin);
    uint32_t mask = 1U << n;
    gpio_config_t config = {
        .pin_bit_mask = mask,
        .mode = mode,
        .pull_up_en = !output && BOOL_VAL(option),
    };
    if (output && gpio_set_level(n, BOOL_VAL(option)) != ESP_OK) return TAG(-EIO);
    if (gpio_config(&config) != ESP_OK) return TAG(-EIO);
    inputs = (inputs & ~mask) | (output ? 0 : mask);
    outputs = (outputs & ~mask) | (output ? mask : 0);
    return TAG(0);
}
static V input(V pin, V pull_up) { return configure(pin, pull_up, GPIO_MODE_INPUT); }
static V output(V pin, V initial_high) { return configure(pin, initial_high, GPIO_MODE_OUTPUT); }
static V open_drain(V pin, V released) { return configure(pin, released, GPIO_MODE_OUTPUT_OD); }
static V read_pin(V pin) {
    if (!header_pin(pin) || !(inputs & (1U << UNTAG(pin)))) return TAG(-EINVAL);
    return TAG(gpio_get_level(UNTAG(pin)));
}
static V write_pin(V pin, V high) {
    if (!header_pin(pin) || !ISBOOL(high) || !(outputs & (1U << UNTAG(pin)))) return TAG(-EINVAL);
    return TAG(gpio_set_level(UNTAG(pin), BOOL_VAL(high)) == ESP_OK ? 0 : -EIO);
}
/* Little-endian C3 timestamps occupy eight caller-owned bytes. memcpy
 * also supports stamps within a packed record. */
static V now_ms(V addr) {
    int64_t ms = esp_timer_get_time() / 1000;
    memcpy(buffer_ptr(addr), &ms, sizeof(ms));
    return V_UNIT;
}
static V after_ms(V addr, V delta, V dest) {
    int64_t ms;
    memcpy(&ms, buffer_ptr(addr), sizeof(ms));
    if (ms < 0 || !ISINT(delta) || UNTAG(delta) < 0 || ms > INT64_MAX - UNTAG(delta))
        return TAG(-EINVAL);
    ms += UNTAG(delta);
    memcpy(buffer_ptr(dest), &ms, sizeof(ms));
    return TAG(0);
}
static V sleep_until(V deadline) {
    int64_t ms;
    memcpy(&ms, buffer_ptr(deadline), sizeof(ms));
    for (;;) {
        int64_t now = esp_timer_get_time() / 1000;
        if (ms <= now) return V_UNIT;
        int64_t remaining = ms - now;
        TickType_t ticks = pdMS_TO_TICKS(remaining > 1000 ? 1000 : remaining);
        vTaskDelay(ticks ? ticks : 1);
    }
}
FPR_FN(fpr_g_EspGPIO_x2einput, input, 2);
FPR_FN(fpr_g_EspGPIO_x2eoutput, output, 2);
FPR_FN(fpr_g_EspGPIO_x2eread, read_pin, 1);
FPR_FN(fpr_g_EspGPIO_x2ewrite, write_pin, 2);
FPR_FN(fpr_g_EspClock_x2enowMs, now_ms, 1);
FPR_FN(fpr_g_EspClock_x2esleepUntil, sleep_until, 1);
FPR_FN(fpr_g_EspClock_x2eafterMs, after_ms, 3);
FPR_FN(fpr_g_EspGPIO_x2eopenDrain, open_drain, 2);
