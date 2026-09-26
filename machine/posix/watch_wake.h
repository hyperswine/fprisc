/* Private wake transport. Called with the watcher mutex held after opening. */
#ifndef FPR_WATCH_WAKE_H
#define FPR_WATCH_WAKE_H
#ifdef FPR_ESP_IDF
#include "esp_vfs_eventfd.h"
static pthread_once_t eventfd_once = PTHREAD_ONCE_INIT;
static esp_err_t eventfd_status;
static void watch_eventfd_init(void) {
  esp_vfs_eventfd_config_t cfg = { .max_fds = 24 };
  eventfd_status = esp_vfs_eventfd_register(&cfg);
}
static int watch_wake_open(int fds[2]) {
  pthread_once(&eventfd_once, watch_eventfd_init);
  if (eventfd_status != ESP_OK) { errno = EIO; return -1; }
  fds[0] = fds[1] = eventfd(0, 0);
  return fds[0] < 0 ? -1 : 0;
}
static void watch_wake_close(int fds[2]) { close(fds[0]); }
static void watch_wake_signal(int fds[2]) {
  uint64_t one = 1;
  if (write(fds[1], &one, sizeof one) != sizeof one) fpr_cpanic("watcher eventfd write failed");
}
static void watch_wake_drain(int fds[2]) {
  uint64_t count;
  /* A single read resets the count. IDF eventfd has no EFD_NONBLOCK;
   * draining in a loop would block on the second read while holding mu. */
  if (read(fds[0], &count, sizeof count) != sizeof count) fpr_cpanic("watcher eventfd read failed");
}
#else
static int watch_wake_open(int fds[2]) {
  if (pipe(fds)) return -1;
  for (int i = 0; i < 2; i++) {
    int flags = fcntl(fds[i], F_GETFL);
    if (flags < 0 || fcntl(fds[i], F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) {
      int saved = errno; close(fds[0]); close(fds[1]); errno = saved; return -1;
    }
  }
  return 0;
}
static void watch_wake_close(int fds[2]) { close(fds[0]); close(fds[1]); }
static void watch_wake_signal(int fds[2]) {
  char byte = 1; ssize_t n;
  do n = write(fds[1], &byte, 1); while (n < 0 && errno == EINTR);
  /* Full means a wake is already pending. */
  if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) fpr_cpanic("watcher pipe write failed");
}
static void watch_wake_drain(int fds[2]) {
  char bytes[64]; ssize_t n;
  do n = read(fds[0], bytes, sizeof bytes); while (n > 0 || (n < 0 && errno == EINTR));
}
#endif
#endif
