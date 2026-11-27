/* sol_serial.c -- the serial-port transport behind Sol's Serial resource
 * (sol-vm/Sol/Serial.hs). Raw 8N1, no flow control, any baud rate: a rate
 * termios names is set the portable way; any other (62212 for a 54 MHz
 * Spectre) through IOSSIOSPEED on macOS and termios2 on Linux. The descriptor
 * stays non-blocking; reads and writes wait with poll, so every wait has a
 * timeout. Each function answers a value >= 0, or -errno. */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>
#if defined(__APPLE__)
#include <IOKit/serial/ioss.h>
#elif defined(__linux__)
#include <asm/ioctls.h> /* TCGETS2 / TCSETS2 */
/* asm/termbits.h would redefine struct termios; termios2 and BOTHER are all
 * that is needed from it (the asm-generic layout, NCCS 19) */
struct termios2 {
  tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
  cc_t c_line;
  cc_t c_cc[19];
  speed_t c_ispeed, c_ospeed;
};
#ifndef BOTHER
#define BOTHER 0010000
#endif
#endif

static speed_t standard_speed(int baud) {
  switch (baud) {
    case 9600: return B9600; case 19200: return B19200; case 38400: return B38400;
    case 57600: return B57600; case 115200: return B115200; case 230400: return B230400;
    default: return 0;
  }
}

#if defined(__linux__)
static int custom_speed(int fd, int baud) {
  struct termios2 t2;
  if (ioctl(fd, TCGETS2, &t2) != 0) return -errno;
  t2.c_cflag &= ~CBAUD; t2.c_cflag |= BOTHER;
  t2.c_ispeed = (speed_t)baud; t2.c_ospeed = (speed_t)baud;
  return ioctl(fd, TCSETS2, &t2) == 0 ? 0 : -errno;
}
#endif

int sol_serial_open(const char *path, int baud) {
  if (baud <= 0) return -EINVAL;
  int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (fd < 0) return -errno;
  struct termios t;
  if (tcgetattr(fd, &t) != 0) { int e = errno; close(fd); return -e; }
  cfmakeraw(&t);
  t.c_cflag |= CLOCAL | CREAD;
  t.c_cflag &= ~(CSTOPB | PARENB);
  t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 0;
  speed_t std = standard_speed(baud);
  if (std) { cfsetispeed(&t, std); cfsetospeed(&t, std); }
  if (tcsetattr(fd, TCSANOW, &t) != 0) { int e = errno; close(fd); return -e; }
  if (!std) {
#if defined(__APPLE__)
    speed_t s = (speed_t)baud;
    if (ioctl(fd, IOSSIOSPEED, &s) != 0) { int e = errno; close(fd); return -e; }
#elif defined(__linux__)
    int r = custom_speed(fd, baud);
    if (r != 0) { close(fd); return r; }
#else
    close(fd); return -EINVAL;
#endif
  }
  tcflush(fd, TCIOFLUSH);
  return fd;
}

/* every byte, waiting up to timeout_ms in total; answers the count written */
int sol_serial_write(int fd, const uint8_t *buf, int len, int timeout_ms) {
  int done = 0;
  while (done < len) {
    struct pollfd p = { fd, POLLOUT, 0 };
    int r = poll(&p, 1, timeout_ms);
    if (r < 0) { if (errno == EINTR) continue; return -errno; }
    if (r == 0) return done;
    ssize_t n = write(fd, buf + done, (size_t)(len - done));
    if (n < 0) { if (errno == EAGAIN || errno == EINTR) continue; return -errno; }
    done += (int)n;
  }
  return done;
}

/* what has arrived, up to cap bytes, waiting up to timeout_ms for the first;
 * 0 means nothing arrived in time */
int sol_serial_read(int fd, uint8_t *buf, int cap, int timeout_ms) {
  for (;;) {
    struct pollfd p = { fd, POLLIN, 0 };
    int r = poll(&p, 1, timeout_ms);
    if (r < 0) { if (errno == EINTR) continue; return -errno; }
    if (r == 0) return 0;
    ssize_t n = read(fd, buf, (size_t)cap);
    if (n < 0) { if (errno == EAGAIN || errno == EINTR) continue; return -errno; }
    if (n == 0) return -EIO; /* readable with nothing to read: the other end closed (macOS pipes report it without POLLHUP) */
    return (int)n;
  }
}

int sol_serial_close(int fd) { return close(fd) == 0 ? 0 : -errno; }

/* ---- child processes (Sol's Proc.open): the same fd transport ------------
 * A child runs with its stdin and stdout on pipes and its stderr inherited,
 * in its own process group so a kill reaches what it starts. The parent's
 * ends are non-blocking and close-on-exec; sol_serial_read/_write serve them
 * as they serve a port. argv is NULL-terminated. Answers the pid, or -errno. */
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
extern char **environ;

int sol_proc_spawn(char *const argv[], int *to_child, int *from_child) {
  int in[2], out[2];
  if (pipe(in) != 0) return -errno;
  if (pipe(out) != 0) { int e = errno; close(in[0]); close(in[1]); return -e; }
  posix_spawn_file_actions_t fa;
  posix_spawnattr_t at;
  posix_spawn_file_actions_init(&fa);
  posix_spawnattr_init(&at);
  posix_spawn_file_actions_adddup2(&fa, in[0], 0);
  posix_spawn_file_actions_adddup2(&fa, out[1], 1);
  posix_spawn_file_actions_addclose(&fa, in[0]);
  posix_spawn_file_actions_addclose(&fa, in[1]);
  posix_spawn_file_actions_addclose(&fa, out[0]);
  posix_spawn_file_actions_addclose(&fa, out[1]);
  posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&at, 0);
  pid_t pid;
  int r = posix_spawnp(&pid, argv[0], &fa, &at, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  posix_spawnattr_destroy(&at);
  close(in[0]);
  close(out[1]);
  if (r != 0) { close(in[1]); close(out[0]); return -r; }
  fcntl(in[1], F_SETFL, fcntl(in[1], F_GETFL) | O_NONBLOCK);
  fcntl(out[0], F_SETFL, fcntl(out[0], F_GETFL) | O_NONBLOCK);
  fcntl(in[1], F_SETFD, FD_CLOEXEC);
  fcntl(out[0], F_SETFD, FD_CLOEXEC);
  *to_child = in[1];
  *from_child = out[0];
  return (int)pid;
}

/* wait up to timeout_ms for the child to end: its exit status, 128+signal
 * when a signal ended it, -ETIMEDOUT when it is still running, or -errno */
int sol_proc_wait(int pid, int timeout_ms) {
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;) {
    int st;
    pid_t r = waitpid((pid_t)pid, &st, WNOHANG);
    if (r < 0) { if (errno == EINTR) continue; return -errno; }
    if (r == (pid_t)pid) return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    clock_gettime(CLOCK_MONOTONIC, &now);
    long ms = (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
    if (ms >= timeout_ms) return -ETIMEDOUT;
    struct timespec nap = { 0, 2000000 };
    nanosleep(&nap, NULL);
  }
}

/* signal the child's process group */
int sol_proc_signal(int pid, int sig) { return kill(-(pid_t)pid, sig) == 0 ? 0 : -errno; }
