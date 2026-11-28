"""Verify the temporary P4 cold-boot journal via the board's UART."""
import argparse
import re
import time

from serial import Serial

OK = b"00000000"
SAMPLE_SECONDS = 60


class Console:
    def __init__(self, port):
        self.serial = Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=5)
        self.serial.port = port
        self.serial.dtr = self.serial.rts = False
        self.pending = b""

    def line(self, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                line = line.rstrip(b"\r")
                if (line.startswith((b"FPR P4", b"P4 BARE METAL")) or
                        b"Loaded app from partition" in line):
                    print(line.decode(errors="replace"), flush=True)
                return line
            self.pending += self.serial.read(512)
        raise RuntimeError("Timed out waiting for P4 UART output")

    def until(self, pattern, seconds=20):
        deadline = time.monotonic() + seconds
        while (remaining := deadline - time.monotonic()) > 0:
            line = self.line(remaining)
            match = re.fullmatch(pattern, line)
            if match:
                return match
            if b"FAIL" in line:
                raise RuntimeError(line.decode(errors="replace"))
        raise RuntimeError(f"Did not receive {pattern!r}")

    def send(self, letter, pattern):
        self.serial.write(letter)
        return self.until(pattern)

    def reset_and_check(self):
        self.serial.rts = True
        time.sleep(0.15)
        self.serial.rts = False
        self.until(rb".*Loaded app from partition at offset 0xd10000.*")
        self.until(rb"FPR P4 FLASH BOOT")
        self.until(rb"P4 BARE METAL integer self-check: 827204 \[PASS\]")
        self.until(rb"FPR P4 FLASH LAYOUT " + OK)
        self.until(rb"FPR P4 JOURNAL MOUNT " + OK)
        self.until(rb"FPR P4 FLASH BOUNDS PASS")
        self.until(rb"FPR P4 FLASH READY")

    def records(self):
        self.serial.write(b"L")
        records = []
        while True:
            line = self.line()
            value = re.fullmatch(rb"FPR P4 RECORD ([0-9a-f]{8})", line)
            if value:
                records.append(int(value[1], 16))
                continue
            count = re.fullmatch(rb"FPR P4 JOURNAL records ([0-9a-f]{8})", line)
            if count:
                if int(count[1], 16) != len(records):
                    raise RuntimeError("Journal record count mismatched")
                self.until(rb"FPR P4 LIST " + OK)
                return records
            if line.startswith(rb"FPR P4 LIST"):
                raise RuntimeError("Journal readback failed")


def check_endurance(console, seconds):
    before = console.records()
    if before != [1, 3]:
        raise RuntimeError("Expected the committed records from the power-cut test")
    seen = 0
    started = time.monotonic()
    first = last = None
    while True:
        sample = time.monotonic()
        now = int(console.send(b"H", rb"FPR P4 UPTIME ms ([0-9a-f]{8})")[1], 16)
        if first is None:
            first = now
        if last is not None and not 0 < now - last <= (SAMPLE_SECONDS + 5) * 1000:
            raise RuntimeError("Unexpected device time gap or reboot")
        last = now
        console.send(b"W", rb"FPR P4 APPEND " + OK)
        seen += 1
        elapsed = (now - first) / 1000
        if elapsed >= seconds and time.monotonic() - started >= seconds:
            break
        interval = min(SAMPLE_SECONDS, max(1, seconds - elapsed + 0.1))
        time.sleep(max(0, interval - (time.monotonic() - sample)))
    expected = before + [4] * seen
    if console.records() != expected:
        raise RuntimeError("Journal endurance records did not match")
    console.reset_and_check()
    if console.records() != expected:
        raise RuntimeError("Journal endurance records did not replay after reset")
    print(f"Journal endurance PASS {elapsed:.3f} s, {seen} verified appends", flush=True)


def check(port, phase, seconds):
    console = Console(port)
    with console.serial:
        if phase == "begin":
            console.reset_and_check()
            if console.records():
                raise RuntimeError("Expected an empty journal after staging")
            console.send(b"E", rb"FPR P4 SCRATCH " + OK)
            console.send(b"1", rb"FPR P4 APPEND " + OK)
            if console.records() != [1]:
                raise RuntimeError("Expected one committed journal record")
            console.send(b"2", rb"FPR P4 CUT READY")
        elif phase == "recover":
            if console.records() != [1]:
                raise RuntimeError("Expected only the committed record after power loss")
            console.send(b"3", rb"FPR P4 APPEND " + OK)
            if console.records() != [1, 3]:
                raise RuntimeError("The journal did not resume after the torn append")
            print("Journal power-cut recovery PASS", flush=True)
        elif phase == "endurance":
            check_endurance(console, seconds)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("phase", choices=("begin", "recover", "endurance"))
    parser.add_argument("--seconds", type=int, default=7200)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error("--seconds must be positive")
    check(args.port, args.phase, args.seconds)
