/* Unix process facilities: omitted by hosts without child processes or exec. */
#include "os_value.h"
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* ---- Os.run: a child with all three streams held ------------------------
 * fork/exec rather than posix_spawn for the chdir.  stdin is fed and both
 * outputs drained in ONE poll loop, so a child that fills a pipe while we
 * are still writing its input cannot deadlock us. */
static sw now_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (sw)ts.tv_sec * 1000 + ts.tv_nsec / 1000000; }
static V h_run(V argvv, V cwdv, V inv, V envv, V limitv) {
  if (ISINT(inv) || TID(inv) != T_STR) fpr_cpanic("Os.run: stdin is not a String");
  const str_t *in = (const str_t *)inv;
  size_t argc = 0;
  for (V c = argvv; !ISINT(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) argc++;
  if (!argc) return os_err("no program named");
  char **argv = calloc(argc + 1, sizeof *argv);
  if (!argv) fpr_cpanic("out of memory");
  size_t i = 0;
  for (V c = argvv; i < argc; c = ((V *)((char *)c + 8))[1]) argv[i++] = os_cstr(((V *)((char *)c + 8))[0], "Os.run: an argument is not a String");
  char *cwd = os_cstr(cwdv, "Os.run: the directory is not a String");
  size_t envc = 0;
  for (V c = envv; !ISINT(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) envc++;
  char **envs = calloc(envc + 1, sizeof *envs);
  if (!envs) fpr_cpanic("out of memory");
  { size_t k = 0; for (V c = envv; k < envc; c = ((V *)((char *)c + 8))[1]) envs[k++] = os_cstr(((V *)((char *)c + 8))[0], "Os.run: an environment entry is not a String"); }
  sw limit = ISINT(limitv) ? UNTAG(limitv) : 0, started = now_ms();
  int timed_out = 0;
  int pin[2], pout[2], perr[2], pexec[2];
  V result;
  if (pipe(pin) || pipe(pout) || pipe(perr) || pipe(pexec)) { result = os_errno(); goto done; }
  fcntl(pexec[1], F_SETFD, FD_CLOEXEC); /* closes on a successful exec: EOF means it ran */
  fflush(stdout); fflush(stderr);
  pid_t pid = fork();
  if (pid < 0) { result = os_errno(); goto done; }
  if (pid == 0) {
    dup2(pin[0], 0); dup2(pout[1], 1); dup2(perr[1], 2);
    close(pin[0]); close(pin[1]); close(pout[0]); close(pout[1]); close(perr[0]); close(perr[1]); close(pexec[0]);
    for (size_t k = 0; k < envc; k++) putenv(envs[k]); /* the child's copy; "NAME=value" */
    { sigset_t none; sigemptyset(&none); sigprocmask(SIG_SETMASK, &none, 0); signal(SIGPIPE, SIG_DFL); }
    if (!*cwd || !chdir(cwd)) execvp(argv[0], argv);
    int e = errno;
    if (write(pexec[1], &e, sizeof e) < 0) {}
    _exit(127);
  }
  close(pin[0]); close(pout[1]); close(perr[1]); close(pexec[1]);
  int child_errno = 0;
  if (read(pexec[0], &child_errno, sizeof child_errno) != sizeof child_errno) child_errno = 0;
  close(pexec[0]);
  signal(SIGPIPE, SIG_IGN); /* a child that does not read its input is not our death */
  fcntl(pin[1], F_SETFL, O_NONBLOCK);
  buf_t out = {0, 0, 0}, err = {0, 0, 0};
  size_t fed = 0;
  int open_in = 1, open_out = 1, open_err = 1;
  if (!in->len) { close(pin[1]); open_in = 0; }
  while (open_in || open_out || open_err) {
    struct pollfd p[3];
    int n = 0, ii = -1, io = -1, ie = -1;
    if (open_in) { p[n].fd = pin[1]; p[n].events = POLLOUT; ii = n++; }
    if (open_out) { p[n].fd = pout[0]; p[n].events = POLLIN; io = n++; }
    if (open_err) { p[n].fd = perr[0]; p[n].events = POLLIN; ie = n++; }
    int wait_ms = -1;
    if (limit > 0) {
      sw left = limit - (now_ms() - started);
      if (left <= 0) { timed_out = 1; kill(pid, SIGKILL); break; }
      wait_ms = (int)left;
    }
    int pr = poll(p, (nfds_t)n, wait_ms);
    if (pr < 0) { if (errno == EINTR) continue; break; }
    if (pr == 0) continue; /* the limit is checked at the top */
    if (ii >= 0 && p[ii].revents) {
      ssize_t w = write(pin[1], in->bytes + fed, in->len - fed);
      if (w > 0) fed += (size_t)w;
      if ((w < 0 && errno != EAGAIN && errno != EINTR) || fed == in->len) { close(pin[1]); open_in = 0; }
    }
    buf_t *bs[2] = {&out, &err};
    int idx[2] = {io, ie}, fds[2] = {pout[0], perr[0]}, *opens[2] = {&open_out, &open_err};
    for (int k = 0; k < 2; k++) {
      if (idx[k] < 0 || !p[idx[k]].revents) continue;
      if (!buf_room(bs[k], 65536)) fpr_cpanic("out of memory");
      ssize_t r = read(fds[k], bs[k]->p + bs[k]->n, bs[k]->cap - bs[k]->n);
      if (r > 0) bs[k]->n += (size_t)r;
      else if (r == 0 || (errno != EINTR && errno != EAGAIN)) { close(fds[k]); *opens[k] = 0; }
    }
  }
  if (open_in) close(pin[1]);
  if (open_out) close(pout[0]);
  if (open_err) close(perr[0]);
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  if (timed_out) {
    char msg[64];
    snprintf(msg, sizeof msg, "timed out after %ld ms", (long)limit);
    result = os_err(msg);
  } else if (child_errno) {
    errno = child_errno;
    result = os_errno(); /* it never ran: "No such file or directory" */
  } else {
    V f[3] = {TAG(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status)),
              os_str(out.p ? out.p : "", out.n), os_str(err.p ? err.p : "", err.n)};
    result = os_ok(os_cell(T_TUP3, 0, 3, f));
  }
  free(out.p); free(err.p);
done:
  for (i = 0; i < argc; i++) free(argv[i]);
  for (i = 0; i < envc; i++) free(envs[i]);
  free(argv); free(envs); free(cwd);
  return result;
}
FPR_FN(fpr_g_Os_x2erun, h_run, 5);

/* become another program: how a live server restarts into its rebuilt self
 * (std/live.fpr).  Sockets and files opened here are close-on-exec. */
/* what a new program must not inherit from the thread that started it: a hart
 * thread's signal mask (exec keeps the CALLING thread's, and a restarted server
 * with its wake-up signals blocked hangs one time in three), and the ignored
 * SIGPIPE (dispositions of SIG_IGN survive exec) */
static void clean_for_exec(void) {
  sigset_t none;
  sigemptyset(&none);
  pthread_sigmask(SIG_SETMASK, &none, 0);
  signal(SIGPIPE, SIG_DFL);
}

static V h_exec(V argvv) {
  size_t argc = 0;
  for (V c = argvv; !ISINT(c) && TID(c) == T_LIST && ((hdr_t *)c)->var == 1; c = ((V *)((char *)c + 8))[1]) argc++;
  if (!argc) return os_err("no program named");
  char **argv = calloc(argc + 1, sizeof *argv);
  if (!argv) fpr_cpanic("out of memory");
  size_t i = 0;
  for (V c = argvv; i < argc; c = ((V *)((char *)c + 8))[1]) argv[i++] = os_cstr(((V *)((char *)c + 8))[0], "Os.exec: an argument is not a String");
  fflush(stdout); fflush(stderr);
  clean_for_exec();
  execvp(argv[0], argv);
  V e = os_errno();
  signal(SIGPIPE, SIG_IGN);
  for (i = 0; i < argc; i++) free(argv[i]);
  free(argv);
  return e;
}
FPR_FN(fpr_g_Os_x2eexec, h_exec, 1);
