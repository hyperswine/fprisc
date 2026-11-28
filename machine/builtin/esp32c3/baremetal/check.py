"""RAM-load the bare-metal self-check using esptool 4.x."""
import argparse
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram
from serial import Serial, SerialException


def receive(serial, size, timeout):
    received = bytearray()
    deadline = time.monotonic() + timeout
    while len(received) < size and time.monotonic() < deadline:
        received.extend(serial.read(size - len(received)))
    if len(received) != size:
        raise RuntimeError(f"Expected {size} bytes, received {received!r}")
    return received


def stamp(serial, tag, timeout):
    record = receive(serial, 9, timeout)
    if record[:1] != tag:
        raise RuntimeError(f"Expected {tag!r}, received {record!r}")
    return int.from_bytes(record[1:], "little")


def check_button(serial):
    first = stamp(serial, b"A", 10)
    host_start = time.monotonic()
    second = stamp(serial, b"B", 5)
    host_ms = (time.monotonic() - host_start) * 1000
    device_ms = second - first
    if not 1000 <= device_ms <= 1005 or abs(host_ms - device_ms) > 150:
        raise RuntimeError(f"Clock mismatch: device={device_ms} ms, host={host_ms:.1f} ms")
    print(f"Clock PASS: device={device_ms} ms, host={host_ms:.1f} ms", flush=True)

    previous = second
    for tag, prompt, timeout in (
        (b"1", "GPIO9 high. Press and release BOOT.", 10),
        (b"0", "GPIO9 low. Release BOOT.", 600),
        (b"1", "GPIO9 high again.", 60),
    ):
        current = stamp(serial, tag, timeout)
        if current - previous < 20:
            raise RuntimeError(f"Expected a 20 ms debounce window: {previous} → {current}")
        print(f"{current} ms: {prompt}", flush=True)
        previous = current
    if receive(serial, len(b"FPR DONE\n"), 10) != b"FPR DONE\n":
        raise RuntimeError("Missing return from FP-RISC main")
    print("BOOT press/release PASS", flush=True)


def check_flash(port, button):
    # Opening the port after USB re-enumerates preserves normal flash boot.
    marker = b"FPR C3 FLASH " + (b"button" if button else b"selfcheck") + b"\n"
    with Serial(port=None, baudrate=115200, timeout=0.2) as serial:
        serial.port = port
        serial.dtr = serial.rts = False
        deadline = time.monotonic() + 30
        while not serial.is_open:
            try:
                serial.open()
            except SerialException:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        serial.write(b"?")
        buffered = bytearray()
        while not buffered.endswith(marker) and time.monotonic() < deadline:
            buffered.extend(serial.read(1))
        if not buffered.endswith(marker):
            raise RuntimeError(f"Missing flash startup marker: {buffered[-1024:]!r}")
        print(marker.decode().strip(), flush=True)
        if button:
            check_button(serial)
        else:
            check_selftest(serial)

def check(port, image, button=False):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-C3":
            raise RuntimeError(f"Expected ESP32-C3, found {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=image))
        serial = chip._port
        serial.timeout = 0.2
        if button:
            return check_button(serial)
        check_selftest(serial)
    finally:
        chip._port.close()


def check_selftest(serial):
    output = bytearray()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        output.extend(serial.read(256))
        if b"C3 BARE METAL integer self-check: 827204 [PASS]\nFPR DONE\n" in output:
            print(output.decode(errors="replace").strip())
            return
    raise RuntimeError(f"Missing self-check result. Received {output[:1800]!r}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image", nargs="?")
    parser.add_argument("--flash", action="store_true", help="attach to a normally booted flash app")
    parser.add_argument("--button", action="store_true", help="verify a physical BOOT press and release")
    args = parser.parse_args()
    if args.flash == bool(args.image):
        parser.error("Specify a RAM image or --flash")
    if args.flash:
        check_flash(args.port, args.button)
    else:
        check(args.port, args.image, args.button)
