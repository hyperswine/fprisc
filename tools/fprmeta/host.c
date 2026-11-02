/* Filesystem mechanisms for the manager. libarchive is the macOS system
 * library, never the Homebrew dylib. Its stable public read API is declared
 * here because Apple's SDK ships the library without its development header. */
#include "os_value.h"
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

struct archive; struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_gzip(struct archive *);
extern int archive_read_support_format_tar(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern mode_t archive_entry_perm(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);

static V good(void) { return os_ok((V)&fpr_unit); }
static int write_all(int fd, const char *s, size_t n) {
  while (n) { ssize_t w = write(fd, s, n); if (w < 0 && errno == EINTR) continue;
    if (w <= 0) return -1; s += w; n -= (size_t)w; } return 0;
}
static V lock_home(V p) {
  char *path = os_cstr(p, "Meta.lock");
  int fd = open(path, O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0600); free(path);
  if (fd < 0) return os_errno();
  struct stat st;
  if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid()
      || flock(fd, LOCK_EX|LOCK_NB)) { close(fd); return os_err("another manager is installing, or unsafe lock file"); }
  return os_ok(TAG(fd));
}
FPR_FN(fpr_g_Meta_x2elock, lock_home, 1);
static V unlock_home(V fd) { close((int)UNTAG(fd)); return (V)&fpr_unit; }
FPR_FN(fpr_g_Meta_x2eunlock, unlock_home, 1);

static V atomic_write(V p, V s) {
  char *path = os_cstr(p, "Meta.atomicWrite"), *tmp = malloc(strlen(path)+16);
  if (!tmp) { free(path); return os_err("out of memory"); }
  sprintf(tmp, "%s.XXXXXX", path);
  int fd = mkstemp(tmp), failed = fd < 0;
  const str_t *text = (const str_t *)s;
  if (!failed) failed = write_all(fd, text->bytes, text->len) || fsync(fd);
  if (fd >= 0 && close(fd)) failed = 1;
  if (!failed) failed = rename(tmp, path);
  if (!failed) {
    char *slash = strrchr(path, '/');
    if (slash) { *slash = 0; int dir = open(*path ? path : "/", O_RDONLY|O_DIRECTORY|O_CLOEXEC);
      failed = dir < 0 || fsync(dir); if (dir >= 0) close(dir); }
  }
  V result = failed ? os_errno() : good();
  unlink(tmp); free(tmp); free(path); return result;
}
FPR_FN(fpr_g_Meta_x2eatomicWrite, atomic_write, 2);
static V temp_dir(V p) {
  char *path = os_cstr(p, "Meta.tempDir"); char *r = mkdtemp(path);
  V result = r ? os_ok(os_str(r, strlen(r))) : os_errno(); free(path); return result;
}
FPR_FN(fpr_g_Meta_x2etempDir, temp_dir, 1);
static V file_size(V p) {
  char *path = os_cstr(p, "Meta.size"); struct stat st;
  int failed = lstat(path, &st); free(path);
  if (failed) return os_errno();
  if (!S_ISREG(st.st_mode)) return os_err("not a regular file");
  return os_ok(TAG(st.st_size));
}
FPR_FN(fpr_g_Meta_x2esize, file_size, 1);

/* Only relative names without control characters or traversal components.
 * Parent directories are opened one by one with O_NOFOLLOW. No file writes
 * can follow archive-created symlinks; hardlinks and devices are refused. */
static int safe_name(const char *p) {
  if (!p || !*p || *p == '/' || strlen(p) >= PATH_MAX) return 0;
  for (const char *c = p; *c; c++) if ((unsigned char)*c < 32 || *c == 127 || *c == '\\') return 0;
  const char *s = p;
  do { const char *e = strchr(s, '/'); size_t n = e ? (size_t)(e-s) : strlen(s);
    if (!n || (n==1 && s[0]=='.') || (n==2 && s[0]=='.' && s[1]=='.')) return 0;
    if (!e || !e[1]) break; s = e+1;
  } while (*s);
  return 1;
}
static int parent_fd(int root, char *path, char **leaf) {
  int dir = dup(root); if (dir < 0) return -1;
  char *start = path, *slash;
  while ((slash = strchr(start, '/'))) {
    *slash = 0;
    if (mkdirat(dir, start, 0700) && errno != EEXIST) { close(dir); return -1; }
    int next = openat(dir, start, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    close(dir); if (next < 0) return -1; dir = next; start = slash+1;
  }
  *leaf = start; return dir;
}
static V extract_archive(V p, V d) {
  char *path = os_cstr(p, "Meta.extract"), *dest = os_cstr(d, "Meta.extract");
  int root = open(dest, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  struct archive *a = archive_read_new();
  const char *why = NULL; char message[512] = "";
  char **links = calloc(10000, sizeof(char *)); size_t nlinks = 0, count = 0;
  int64_t total = 0; struct archive_entry *e;
  if (root < 0 || !a || !links) why = "cannot prepare archive extraction";
  if (!why) { archive_read_support_filter_gzip(a); archive_read_support_format_tar(a);
    if (archive_read_open_filename(a, path, 65536)) why = archive_error_string(a); }
  int status = 1;
  while (!why && (status = archive_read_next_header(a, &e)) == 0) {
    const char *name = archive_entry_pathname(e);
    while (name && !strncmp(name, "./", 2)) name += 2;
    if (!safe_name(name) || archive_entry_hardlink(e) || ++count > 10000) { why = "unsafe archive path, hardlink, or too many entries"; break; }
    char copy[PATH_MAX]; strcpy(copy, name); size_t n = strlen(copy);
    if (copy[n-1]=='/') copy[n-1]=0;
    char *leaf; int dir = parent_fd(root, copy, &leaf);
    if (dir < 0) { why = "archive parent is not a safe directory"; break; }
    mode_t kind = archive_entry_filetype(e);
    if (kind == S_IFDIR) {
      if (mkdirat(dir, leaf, 0700) && errno != EEXIST) why = "cannot create archive directory";
      int check = openat(dir, leaf, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
      if (check < 0) why = "archive directory collision"; else close(check);
    } else if (kind == S_IFREG) {
      int64_t size = archive_entry_size(e);
      if (size < 0 || size > 512LL*1024*1024 || total > 2LL*1024*1024*1024-size) why = "archive exceeds unpacked size limit";
      else total += size;
      int fd = why ? -1 : openat(dir, leaf, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600);
      if (!why && fd < 0) why = "duplicate or unsafe archive file";
      char buf[65536]; int64_t got = 0; ssize_t read = 0;
      while (!why && (read = archive_read_data(a, buf, sizeof(buf))) > 0) {
        got += read; if (got > size || write_all(fd, buf, (size_t)read)) why = "archive file exceeds declared size or cannot be written";
      }
      if (!why && (read < 0 || got != size)) why = "truncated archive file";
      if (fd >= 0) { if (fchmod(fd, archive_entry_perm(e)&0111 ? 0755 : 0644) || fsync(fd)) why = "cannot sync archive file"; close(fd); }
    } else if (kind == S_IFLNK) {
      const char *target = archive_entry_symlink(e);
      if (!target || !*target || *target=='/' || symlinkat(target, dir, leaf)) why = "unsafe or duplicate archive symlink";
      else { links[nlinks] = strdup(name); if (!links[nlinks++]) why = "out of memory"; }
    } else why = "archive contains a special file";
    close(dir);
  }
  if (!why && status != 1) why = archive_error_string(a);
  char base[PATH_MAX];
  if (!why && !realpath(dest, base)) why = "cannot resolve extraction directory";
  for (size_t i=0; !why && i<nlinks; i++) {
    char full[PATH_MAX], real[PATH_MAX];
    if (snprintf(full, sizeof(full), "%s/%s", dest, links[i]) >= (int)sizeof(full)
        || !realpath(full, real) || strncmp(real, base, strlen(base)) || real[strlen(base)]!='/')
      why = "archive symlink escapes its tree or is dangling";
  }
  if (why) snprintf(message, sizeof(message), "%s", why);
  if (a) archive_read_free(a); if (root >= 0) close(root);
  for (size_t i=0; i<nlinks; i++) free(links[i]); free(links); free(path); free(dest);
  return *message ? os_err(message) : good();
}
FPR_FN(fpr_g_Meta_x2eextract, extract_archive, 2);
