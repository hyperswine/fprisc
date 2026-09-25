"""console.py PORT -- be an FP-RISC program's terminal on the board.

`fpr run --system=esp-idf` ends here (run.sh), so a board program behaves
like a posix one under `fpr run`:

- the board is reset, and its boot chatter is dropped; from the runtime's
  first line on, the program's output goes to stdout, and the runtime's own
  "[fpr] ..." lines and ESP-IDF's error lines to stderr (FPR_ESP_VERBOSE=1
  passes ESP-IDF's info and warning lines through too);
- lines on stdin are typed into the console (Enter as CR, which the board's
  stdin turns into "\\n"), once the runtime is up: Sys.readLine reads them;
- the exit status is the program's: the board prints
  "[fpr] program ended (status N)" when it ends, and this exits N.  A panic
  ends with status 1 the same way.  A board that resets under the program
  (a crash, a watchdog) exits 2, saying so.  A program that never ends
  (a server) runs until interrupted: Ctrl-C exits 130, or FPR_ESP_TIMEOUT=N
  seconds exits 124, as timeout(1) does.

Needs pyserial (ESP-IDF's Python environment has it).
"""
import os
import re
import sys
import threading
import time

import serial

port = sys.argv[1]
verbose = os.environ.get("FPR_ESP_VERBOSE") == "1"
deadline = time.time() + float(os.environ["FPR_ESP_TIMEOUT"]) if os.environ.get("FPR_ESP_TIMEOUT") else None
idf_log = re.compile(r"^(\x1b\[0;3\dm)?([IWED]) \(\d+\) ")
ended = re.compile(r"^\[fpr\] program ended \(status (\d+)\)")

s = serial.Serial()
s.port, s.baudrate, s.timeout = port, 115200, 0.1
s.dtr = False
s.rts = False
s.open()
s.rts = True            # reset: EN low ...
time.sleep(0.1)
s.rts = False           # ... and released

running = threading.Event()   # the runtime is up: the console's input is being read

def type_stdin():
    # typed before the runtime is up, input would meet a board still booting,
    # whose console driver discards what came before it (main.c flushes it)
    running.wait()
    for line in sys.stdin:
        s.write(line.rstrip("\r\n").encode() + b"\r")

threading.Thread(target=type_stdin, daemon=True).start()

started = False         # the runtime's first line seen
buf = b""
status = None
try:
    while status is None:
        if deadline and time.time() > deadline:
            sys.stderr.write("fpr run: FPR_ESP_TIMEOUT reached; the program was still running\n")
            status = 124
            break
        buf += s.read(4096)
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            line = raw.decode("utf-8", "replace").rstrip("\r")
            if not started:
                started = line.startswith("[fpr] ")
                if not started:
                    continue
                running.set()
            elif line.startswith("rst:") or "Guru Meditation" in line:
                sys.stderr.write("fpr run: the board reset under the program: " + line + "\n")
                if "(Breakpoint)" in line:
                    # FP-RISC code has no breakpoints and no debugger is attached:
                    # this is the watchpoint on the running actor's stack bottom
                    sys.stderr.write("fpr run: that is the stack guard: C code on an actor's stack ran past"
                                     " its bottom (machine/esp-idf/hal.c hal_actor_stack)\n")
                status = 2
                break
            m = ended.match(line)
            if m:
                status = int(m.group(1))
                break
            log = idf_log.match(line)
            if log:
                if log.group(2) == "E" or verbose:
                    sys.stderr.write(re.sub(r"\x1b\[[0-9;]*m", "", line) + "\n")
                continue
            if line.startswith("[fpr] "):
                sys.stderr.write(line + "\n")
            else:
                sys.stdout.write(re.sub(r"\x1b\[[0-9;]*m", "", line) + "\n")
                sys.stdout.flush()
except KeyboardInterrupt:
    status = 130
finally:
    s.close()
sys.exit(status)
