/* Streaming libarchive writer; caller supplies admission budgets. */
#include <archive.h>
#include <archive_entry.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
int fpr_native_archive(const char *source,const char *target,long long maxEntries,long long maxBytes,char **error){
  struct archive *disk=NULL,*out=NULL;struct archive_entry *entry=NULL;
  char *tmp=NULL,*why=NULL;int fd=-1,ok=0;long long entries=0,bytes=0;
#define FAIL(msg) do {const char *reason=(msg);why=strdup(reason?reason:"native archive failure");goto done;} while(0)
#define CHECK(a,expr) do{if((expr)<ARCHIVE_OK)FAIL(archive_error_string(a)?archive_error_string(a):"archive failure");}while(0)
  if(maxEntries<1||maxBytes<1)FAIL("archive limits must be positive");
  tmp=malloc(strlen(target)+24);if(!tmp)FAIL("archive allocation failed");
  sprintf(tmp,"%s.sol-archive.XXXXXX",target);fd=mkstemp(tmp);if(fd<0)FAIL(strerror(errno));
  disk=archive_read_disk_new();out=archive_write_new();entry=archive_entry_new();
  if(!disk||!out||!entry)FAIL("archive allocation failed");
  archive_read_disk_set_symlink_physical(disk);
  CHECK(disk,archive_read_disk_open(disk,source));
  /* WARN includes libarchive's external-gzip fallback: refuse it before open. */
  CHECK(out,archive_write_add_filter_gzip(out));CHECK(out,archive_write_set_format_pax_restricted(out));CHECK(out,archive_write_open_fd(out,fd));
  for(;;){
    int r=archive_read_next_header2(disk,entry);if(r==ARCHIVE_EOF)break;CHECK(disk,r);
    const char *src=archive_entry_sourcepath(entry);if(!src)FAIL("missing archive source path");
    char *path=strdup(src);if(!path)FAIL("archive allocation failed");
    struct stat before;
    if(lstat(path,&before)){free(path);FAIL("cannot stat archive input");}
    mode_t type=archive_entry_filetype(entry);long long size=archive_entry_size(entry);
    if(type!=AE_IFREG && type!=AE_IFDIR && type!=AE_IFLNK){free(path);FAIL("archive refuses special files");}
    if(++entries>maxEntries || size<0 || (type==AE_IFREG && size>maxBytes-bytes)){free(path);FAIL("archive budget exceeded");}
    if(type==AE_IFREG)bytes+=size;
    /* Never store absolute or parent-traversing archive member names. */
    const char *member=archive_entry_pathname(entry);while(*member=='/')member++;
    if(!*member || !strcmp(member,"..") || !strncmp(member,"../",3) || strstr(member,"/../") || (strlen(member)>3 && !strcmp(member+strlen(member)-3,"/.."))){free(path);FAIL("unsafe archive member path");}
    char *name=strdup(member);if(!name){free(path);FAIL("archive allocation failed");}
    archive_entry_set_pathname(entry,name);free(name);
    if(type==AE_IFDIR){r=archive_read_disk_descend(disk);if(r<ARCHIVE_OK){free(path);FAIL("cannot descend archive source");}}
    r=archive_write_header(out,entry);if(r<ARCHIVE_OK){free(path);FAIL(archive_error_string(out));}
    if(type==AE_IFREG){
      char buf[65536];long long copied=0;la_ssize_t n;
      while((n=archive_read_data(disk,buf,sizeof buf))>0){if(n>size-copied){free(path);FAIL("archive input changed while reading");}copied+=n;
        if(archive_write_data(out,buf,(size_t)n)!=n){free(path);FAIL("archive write failed");}}
      if(n<0 || copied!=size){free(path);FAIL("archive input changed or could not be read");}
    }
    struct stat st;
    if(lstat(path,&st) || st.st_dev!=before.st_dev || st.st_ino!=before.st_ino || st.st_size!=before.st_size || st.st_mtime!=before.st_mtime){free(path);FAIL("archive input changed while reading");}
#ifdef __APPLE__
    if(st.st_mtimespec.tv_nsec!=before.st_mtimespec.tv_nsec || st.st_ctimespec.tv_sec!=before.st_ctimespec.tv_sec || st.st_ctimespec.tv_nsec!=before.st_ctimespec.tv_nsec){free(path);FAIL("archive input changed while reading");}
#else
    if(st.st_mtim.tv_nsec!=before.st_mtim.tv_nsec || st.st_ctim.tv_sec!=before.st_ctim.tv_sec || st.st_ctim.tv_nsec!=before.st_ctim.tv_nsec){free(path);FAIL("archive input changed while reading");}
#endif
    free(path);archive_entry_clear(entry);
  }
  CHECK(out,archive_write_close(out));if(fsync(fd))FAIL(strerror(errno));
  if(close(fd)){fd=-1;FAIL(strerror(errno));}fd=-1;
  if(rename(tmp,target))FAIL(strerror(errno));
  /* Make publication durable before the Sol completion record is fsynced. */
  char *parent=strdup(target);if(!parent)FAIL("archive published but directory sync allocation failed");
  char *slash=strrchr(parent,'/');
  if(slash){if(slash==parent)slash[1]=0;else *slash=0;}else {free(parent);parent=strdup(".");}
  int dirfd=parent?open(parent,O_RDONLY|O_DIRECTORY):-1;free(parent);
  if(dirfd<0)FAIL("archive published but directory could not be opened for sync");
  int syncError=fsync(dirfd);close(dirfd);
  if(syncError)FAIL("archive published but directory sync failed");ok=1;
done:
  archive_entry_free(entry);if(disk)archive_read_free(disk);if(out)archive_write_free(out);
  if(fd>=0)close(fd);if(!ok && tmp)unlink(tmp);free(tmp);
  *error=why?why:strdup("");return ok?0:-1;
}
