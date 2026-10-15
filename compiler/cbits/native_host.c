/* Structured host observations from kernel APIs. No process spawning. */
#include <sys/utsname.h>
#include <sys/statvfs.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <sys/time.h>
#else
#include <sys/sysinfo.h>
#include <dirent.h>
#include <mntent.h>
#endif
typedef void (*observe)(int,long long,long long,const char *,const char *);
int fpr_native_host(int max,observe emit,char **error){
  struct utsname u;long long uptime=0;int count=0;
#define FAIL(msg) do{*error=strdup(msg);return -1;}while(0)
  if(max<1)FAIL("host observation limit must be positive");
  if(uname(&u))FAIL(strerror(errno));
  char os[1024];snprintf(os,sizeof os,"%s %s %s %s",u.sysname,u.release,u.version,u.machine);
  emit(0,0,0,u.nodename,os);
#ifdef __APPLE__
  struct timeval boot,now;size_t n=sizeof boot;int bootmib[]={CTL_KERN,KERN_BOOTTIME};
  if(sysctl(bootmib,2,&boot,&n,NULL,0)||gettimeofday(&now,NULL))FAIL(strerror(errno));uptime=now.tv_sec-boot.tv_sec;
  struct statfs *mounts=NULL;int nm=getmntinfo(&mounts,MNT_NOWAIT);if(nm<=0)FAIL(strerror(errno));
  for(int i=0;i<nm;i++){if(++count>max)FAIL("host observation limit exceeded");
    emit(2,(long long)mounts[i].f_blocks*mounts[i].f_bsize,(long long)mounts[i].f_bavail*mounts[i].f_bsize,mounts[i].f_mntonname,"");}
  int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};n=0;
  if(sysctl(mib,4,NULL,&n,NULL,0))FAIL(strerror(errno));
  /* A caller-supplied bound caps the allocation even if the kernel grows. */
  size_t cap=n+sizeof(struct kinfo_proc)*32;if(cap/sizeof(struct kinfo_proc)>(size_t)max)FAIL("host process limit exceeded");
  struct kinfo_proc *ps=malloc(cap);if(!ps)FAIL("host allocation failed");n=cap;
  if(sysctl(mib,4,ps,&n,NULL,0)){free(ps);FAIL(strerror(errno));}
  for(size_t i=0;i<n/sizeof *ps;i++)emit(3,ps[i].kp_proc.p_pid,ps[i].kp_eproc.e_ppid,ps[i].kp_proc.p_comm,"");
  free(ps);
#else
  struct sysinfo info;if(sysinfo(&info))FAIL(strerror(errno));uptime=info.uptime;
  FILE *mt=setmntent("/proc/mounts","r");if(!mt)FAIL(strerror(errno));struct mntent *m;
  while((m=getmntent(mt))){struct statvfs st;if(statvfs(m->mnt_dir,&st))continue;
    if(++count>max){endmntent(mt);FAIL("host observation limit exceeded");}
    emit(2,(long long)st.f_blocks*st.f_frsize,(long long)st.f_bavail*st.f_frsize,m->mnt_dir,"");}endmntent(mt);
  DIR *dir=opendir("/proc");if(!dir)FAIL(strerror(errno));struct dirent *de;count=0;
  while((de=readdir(dir))){char *end;long pid=strtol(de->d_name,&end,10);if(*end||pid<=0)continue;
    if(++count>max){closedir(dir);FAIL("host process limit exceeded");}
    char path[128],line[4096];snprintf(path,sizeof path,"/proc/%ld/stat",pid);FILE *f=fopen(path,"r");if(!f)continue;
    char *got=fgets(line,sizeof line,f);fclose(f);if(!got)continue;
    char *start=strchr(line,'('),*stop=strrchr(line,')');long ppid;char state;
    if(start && stop && sscanf(stop+1," %c %ld",&state,&ppid)==2){*stop=0;emit(3,pid,ppid,start+1,"");}
  }closedir(dir);
#endif
  emit(1,uptime,0,"","");*error=strdup("");return 0;
}
