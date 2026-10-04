#!/usr/bin/env python3
"""Load a Tang Nano 20K SimpleRisc binary through one persistent UART session.

DONE is emitted even after an illegal instruction. Require the board runtime's
FPR EXIT 0 marker as well, so an unexpected CPU halt cannot count as success.
"""
import argparse
import fcntl
import os
from pathlib import Path
import select
import struct
import sys
import termios
import time


def frame(image):
    if not image or len(image) > 65536:
        raise ValueError('image must contain 1..65536 bytes')
    image += b'\0' * (-len(image) % 4)
    return b'P' + struct.pack('<H', len(image) // 4) + image + b'R'


def open_port(port, baud):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, termios.TIOCEXCL)
        attrs = termios.tcgetattr(fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        speed = getattr(termios, f'B{baud}', None)
        attrs[4] = attrs[5] = speed or termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        if speed is None:
            if sys.platform != 'darwin':
                raise ValueError('arbitrary baud rates currently require macOS')
            fcntl.ioctl(fd, 0x80085402, struct.pack('L', baud))  # IOSSIOSPEED
        return fd
    except BaseException:
        os.close(fd)
        raise


def write_all(fd, data, timeout):
    deadline = time.monotonic() + timeout
    while data:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
            raise TimeoutError('UART write timed out')
        try:
            data = data[os.write(fd, data):]
        except BlockingIOError:
            continue


def receive(fd, timeout, until_done=False, display=False):
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], min(.05, max(0, deadline - time.monotonic())))
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            output.extend(chunk)
            if display:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
        if until_done and output.endswith(b'DONE'):
            break
    return bytes(output)


def run(image, port, baud, timeout):
    data = frame(image)
    fd = open_port(port, baud)
    try:
        # Stop a previous CPU before programming; never reopen during TX.
        write_all(fd, b'\x03', 2)
        receive(fd, .1)
        write_all(fd, b'X', 2)
        time.sleep(.02)
        write_all(fd, data, max(2, len(data) * 10 / baud + 2))
        termios.tcdrain(fd)
        output = receive(fd, timeout, until_done=True, display=True)
        if not output.endswith(b'FPR EXIT 0\nDONE'):
            raise RuntimeError(f'no successful runtime exit (received {len(output)} bytes)')
        return output
    finally:
        try:
            write_all(fd, b'\x03', 2)
            receive(fd, .25)
        finally:
            os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('--port', required=True, help='FPGA UART interface, not JTAG')
    parser.add_argument('--freq-mhz', type=float, default=96, help='loaded bitstream clock; baud = clock/868')
    parser.add_argument('--baud', type=int, help='override the derived baud rate')
    parser.add_argument('--timeout', type=float, default=30)
    args = parser.parse_args()
    baud = args.baud if args.baud is not None else round(args.freq_mhz * 1e6 / 868)
    if baud <= 0 or args.timeout <= 0:
        parser.error('baud and timeout must be positive')
    try:
        run(args.image.read_bytes(), args.port, baud, args.timeout)
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        print(f'\nSimpleRisc: {error}', file=sys.stderr)
        return 1
    print()
    return 0


if __name__ == '__main__':
    sys.exit(main())
