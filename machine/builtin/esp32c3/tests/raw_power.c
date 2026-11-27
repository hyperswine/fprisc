#include "log.h"
#include <assert.h>
#include <errno.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>

static uint8_t media[65536], saved[sizeof(media)];
static jmp_buf power;
static int operation, limit = -1;
static int rd(void *ctx, size_t at, void *out, size_t n) {
    assert(at <= sizeof(media) && n <= sizeof(media)-at);
    memcpy(out,media+at,n);
    return 0;
}
static int wr(void *ctx, size_t at, const void *data, size_t n) {
    const uint8_t *p=data;
    assert(at <= sizeof(media) && n <= sizeof(media)-at);
    for (size_t i=0;i<n;i++) {
        for (unsigned bit=0;bit<8;bit++) {
            if (operation++ == limit) longjmp(power,1);
            if (!(p[i] & (1U<<bit))) media[at+i] &= ~(1U<<bit);
        }
    }
    return 0;
}
static uint32_t crc(const void *data,size_t n) { return crc32(0,data,n); }
static c3log fresh(void) {
    return (c3log){.bytes=sizeof(media),.read=rd,.program=wr,.crc=crc};
}
static size_t replay(c3log *l,const char *name,unsigned first,unsigned count) {
    size_t cursor=0;
    uint8_t p[64];
    for (unsigned i=0;i<count;i++) {
        assert(c3log_next(l,name,strlen(name),&cursor,p)==1);
        assert(p[0]==(uint8_t)(first+i));
    }
    return cursor;
}
static void exact(c3log *l,const char *name,unsigned first,unsigned count) {
    size_t cursor=replay(l,name,first,count);
    uint8_t p[64];
    assert(c3log_next(l,name,strlen(name),&cursor,p)==0);
}
static void append(c3log *l,const char *name,unsigned sequence) {
    uint8_t byte=sequence;
    assert(!c3log_append(l,name,strlen(name),&byte,1));
}
int main(void) {
    for(int stop=0; stop<=16*8; stop++) {
        memset(media,255,sizeof(media));
        operation=0;limit=stop;
        c3log l=fresh();
        if (!setjmp(power)) assert(!c3log_mount(&l));
        limit=-1;
        l=fresh();assert(!c3log_mount(&l));
        exact(&l,"A",0,0);
    }
    c3log l=fresh();assert(!c3log_mount(&l));
    append(&l,"A",10);append(&l,"B",40);append(&l,"A",11);
    memcpy(saved,media,sizeof(media));
    for(int stop=0; stop<=128*8; stop++) {
        memcpy(media,saved,sizeof(media)); l=fresh(); assert(!c3log_mount(&l));
        operation=0;limit=stop;
        if(!setjmp(power)) append(&l,"A",12);
        limit=-1;
        l=fresh();assert(!c3log_mount(&l));
        exact(&l,"B",40,1);
        size_t cursor=replay(&l,"A",10,2);
        uint8_t b[64];
        int extra=c3log_next(&l,"A",1,&cursor,b);
        assert(extra==0 || (extra==1 && b[0]==12));
        append(&l,"A",extra ? 13 : 12);
        l=fresh();assert(!c3log_mount(&l));exact(&l,"A",10,3+extra);
    }
    unsigned total=0;
    while (l.next < sizeof(media)/128) append(&l,"C",total++);
    uint8_t b=0;
    assert(c3log_append(&l,"C",1,&b,1)==-ENOSPC);
    l=fresh();assert(!c3log_mount(&l));exact(&l,"C",0,total);
    media[128+36]^=1; l=fresh();assert(c3log_mount(&l)==-EBADMSG);
    puts("PASS: 129 signature and 1025 record bit boundaries, replay+append after each reset, independent journals, full volume and committed CRC failure");
}
