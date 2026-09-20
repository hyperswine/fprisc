"""drive examples/todo.fpr through a pseudo-terminal: real raw mode, real keys"""
import fcntl, json, os, pty, select, struct, sys, termios, time
fpr, app, store = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.execv(fpr, [fpr, 'run', app, store])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
out = b''
def pump(seconds):
    global out
    end = time.time() + seconds
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try: out += os.read(fd, 65536)
            except OSError: return
def until(text, seconds=60):
    end = time.time() + seconds
    while text.encode() not in out and time.time() < end: pump(0.1)
    assert text.encode() in out, (text, out[-400:])
until('To do')
for keys, want in [(b'buy milk\r', '[ ] buy milk'), ('café ☕\r'.encode(), 'café ☕'), (b'third\r', '[ ] third'),
                   (b'\x1b[A\x1b[A\t', '[x] buy milk'), (b'\x1b[B\x1b[3~', '1 of 2 done'), (b'x\x7f', 'saved')]:
    os.write(fd, keys); until(want)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0)); pump(0.5)
until('up 1 s', 10)
os.write(fd, b'\x11')                       # Ctrl-q
pump(1.5)
_, status = os.waitpid(pid, 0)
saved = json.load(open(store))
assert os.WEXITSTATUS(status) == 0, status
assert saved == [{'done': True, 'text': 'buy milk'}, {'done': False, 'text': 'third'}], saved
assert b'\x1b[?1049l' in out and b'\x1b[?25h' in out, 'the terminal was not put back'
print(json.dumps(saved, ensure_ascii=False))
