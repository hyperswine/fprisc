/* fsx.c — tiny POSIX helpers for the crash-atomic commit path (Txn.hs).
 *
 * FFI'd directly rather than going through the `unix` package because the
 * openFd signature changed across unix versions and these three calls are
 * the whole surface we need. Works unchanged on Linux and macOS.
 */
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/types.h>
#include <stdio.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif

/* fsync the file (or directory) at path. Best-effort: returns -1 if the
 * path cannot be opened or the filesystem refuses (some network FSes do);
 * the caller treats failure as "no durability upgrade", not an error. */
int sol_fsync_path(const char *p) {
  int fd = open(p, O_RDONLY);
  if (fd < 0) return -1;
  int r = fsync(fd);
  close(fd);
  return r;
}

/* is the process alive? kill(pid, 0) probes without signalling; EPERM
 * means it exists but is not ours — still alive for lock purposes. */
int sol_pid_alive(int pid) {
  if (pid <= 0) return 0;
  if (kill((pid_t)pid, 0) == 0) return 1;
  return errno == EPERM;
}

int sol_getpid(void) { return (int)getpid(); }

/* crash NOW: no atexit handlers, no Haskell RTS shutdown, no buffered
 * flushes — the honest simulation of a kill -9 for SOL_CRASH_AT. */
void sol_hard_exit(int code) { _exit(code); }

/* Atomic same-filesystem rename. No-clobber uses the host's exclusive
 * rename primitive, never a racy existence test or link/unlink fallback. */
int sol_rename_now(const char *source, const char *target, int replace) {
  int result;
  if (replace) result = rename(source, target);
#if defined(__APPLE__)
  else result = renamex_np(source, target, RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
  else result = (int)syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, target, 1 /* RENAME_NOREPLACE */);
#else
  else { errno = ENOTSUP; result = -1; }
#endif
  return result == 0 ? 0 : errno;
}
