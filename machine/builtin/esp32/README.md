# Bare-metal LEDC PWM for ESP32-C3 and ESP32-P4

Import `pwm.fpr` from a Builtin program built for either chip. The
driver configures the 40 MHz crystal clock, the on-chip LEDC peripheral
and the GPIO matrix directly.

- `PWM.open channel timer pin frequencyHz` claims a channel and pin.
  It leaves the output low until the first pulse is set.
- `PWM.pulseUs channel width` sets the high time in microseconds.
  The width must be shorter than the period. Zero keeps the pin low.
  LEDC rounds the width to the nearest available timer count.
- `PWM.stop channel` drives the pin low and releases the PWM claim.
  The channel and pin can then be opened again.

Each call returns zero on success or a negative error. Both chips
have timers 0–3. The C3 has channels 0–5 and the P4 has channels 0–7.
Channels on the same timer must use the same frequency and can have
different pulse widths. The driver rejects frequencies its hardware
divider cannot represent. While a pin is claimed, leave its GPIO mux
and output configuration to PWM.

The C3 driver accepts GPIO0–10 and GPIO20–21. The P4 driver excludes
GPIO14–19 and GPIO54 for the onboard C6 connection. Check the board
pinout for other peripherals, straps and available header pins.

## Hobby servo example

`examples/servo.fpr` asks channel 0 to send a 1,500 µs pulse every
20 ms on GPIO4. Change the pin to suit the board. Use the servo's
rated supply and connect its ground to the ESP32 ground. The GPIO
carries the signal.

From the repository root, using the same toolchain as the two
bare-metal ports:

    machine/builtin/esp32c3/baremetal/build.sh build/c3-servo servo
    P4_SOURCE=machine/builtin/esp32/examples/servo.fpr \
        machine/builtin/esp32p4/baremetal/build.sh build/p4-servo

RAM-load `build/c3-servo/servo.bin` or `build/p4-servo/selfcheck.bin`
with esptool 4.x `load_ram`. On the P4, send `?` over UART0 after
the ROM handoff to start the Builtin program. The hardware continues
generating the pulses after FP-RISC main returns.

On the attached C3 and P4, a RAM-loaded test measured 1,000, 1,500
and 2,000 µs commands at 50 Hz and a 1,300 µs command at 100 Hz using
GPIO4's input readback and each chip's SYSTIMER. It also checked
timer conflicts, zero duty, stop-low and channel reuse. The bench
measured the control signal without a servo attached.
