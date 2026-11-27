"""Compare a flash-booted journal with a host witness across physical power removal."""
import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import secrets
import time

from serial import Serial, SerialException

from check_board import receive
from check_journal import replay


@contextmanager
def attach(port):
    with Serial(port=None, baudrate=115200, timeout=0.25, write_timeout=3) as serial:
        serial.dtr = False
        serial.rts = False
        serial.port = port
        serial.open()
        end = time.monotonic() + 10
        while serial.read(1024):
            if time.monotonic() >= end:
                raise RuntimeError("Console did not become quiet")
        yield serial


def digest(records):
    value = hashlib.sha256()
    for item in records:
        value.update(bytes([len(item)]) + item)
    return value.hexdigest()


def sample(run_id, index):
    return b"C3POWER" + run_id + index.to_bytes(4, "little")


def arm(port, path):
    run_id = secrets.token_bytes(8)
    with attach(port) as serial:
        initial = replay(serial)
        with path.open("x", buffering=1) as witness:
            print(json.dumps([len(initial), digest(initial), run_id.hex()]), file=witness)
            for index in range(3000):
                item = sample(run_id, index)
                print("send", index, file=witness)
                try:
                    serial.write(b"A" + bytes([len(item)]) + item)
                    status = receive(serial, 1)
                except (SerialException, OSError):
                    if index == 0:
                        raise
                    print("Serial connection lost. Reconnect power and run verify.", flush=True)
                    return
                if status != b"\x06":
                    raise RuntimeError(f"Missing ACK for {index}, response {status!r}")
                print("ack", index, file=witness)
                if index == 0:
                    print("First ACK recorded. Remove C3 power while appends continue.", flush=True)
                time.sleep(0.1)
    raise RuntimeError("Reached 3,000 appends without an observed disconnect")


def verify(port, path):
    header, *events = path.read_text().splitlines()
    count, fingerprint, run_id = json.loads(header)
    sent = acked = 0
    for entry in events:
        if entry == f"send {sent}" and sent == acked:
            sent += 1
        elif entry == f"ack {acked}" and sent == acked + 1:
            acked += 1
        else:
            raise RuntimeError("Inconsistent host witness")
    if not acked:
        raise RuntimeError("No acknowledged test record")
    with attach(port) as serial:
        records, healthy = replay(serial, return_health=True)
        if len(records) < count or digest(records[:count]) != fingerprint:
            raise RuntimeError("Original journal prefix changed")
        appended = records[count:]
        if not acked <= len(appended) <= sent:
            raise RuntimeError(f"Expected {acked} to {sent} test records, got {len(appended)}")
        if appended != [sample(bytes.fromhex(run_id), n) for n in range(len(appended))]:
            raise RuntimeError("Unexpected record contents or ordering")
        if not healthy:
            if len(appended) != acked or sent != acked + 1:
                raise RuntimeError("Damaged suffix outside the single interrupted append")
            serial.write(b"R")
            if receive(serial, 1) != b"\x06" or replay(serial) != records:
                raise RuntimeError("Damaged-tail recovery failed")
        print(f"PASS: {count} prior records, {acked} acknowledged, {len(appended)} recovered, repaired={not healthy}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("arm", "verify"))
    parser.add_argument("port")
    parser.add_argument("witness", type=Path)
    args = parser.parse_args()
    (arm if args.mode == "arm" else verify)(args.port, args.witness)
