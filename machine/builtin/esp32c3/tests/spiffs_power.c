/* Run IDF's SPIFFS on a volatile NOR emulator, interrupting a single
 * append at each byte of every mutating HAL call and remounting from bytes. */
#include <assert.h>
#ifdef NDEBUG
#error Qualification checks require assertions
#endif
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>
#include "spiffs.h"

enum { CAPACITY = 65536, PAGE = 256, BLOCK = 4096, RECORD = 72 };
static unsigned char flash[CAPACITY], baseline[CAPACITY], work[PAGE * 2];
static uintptr_t fds[128], cache[256];
static spiffs fs;
static jmp_buf outage;
static unsigned byte_count, cut, erases;
static int injecting;

void spiffs_api_lock(spiffs *unused) {}
void spiffs_api_unlock(spiffs *unused) {}
static s32_t read_bytes(spiffs *unused, u32_t at, u32_t n, u8_t *dst) {
    assert(at <= CAPACITY && n <= CAPACITY - at);
    memcpy(dst, flash + at, n);
    return 0;
}
static void interruption(void) {
    if (injecting && byte_count++ == cut) longjmp(outage, 1);
}
static s32_t write_bytes(spiffs *unused, u32_t at, u32_t n, u8_t *src) {
    assert(at <= CAPACITY && n <= CAPACITY - at);
    for (unsigned i = 0; i < n; ++i) { interruption(); flash[at+i] &= src[i]; }
    return 0;
}
static s32_t erase(spiffs *unused, u32_t at, u32_t n) {
    assert(at <= CAPACITY && n <= CAPACITY - at && at % BLOCK == 0 && n % BLOCK == 0);
    ++erases;
    for (unsigned i = 0; i < n; ++i) { interruption(); flash[at+i] = 255; }
    return 0;
}
static int mount_fs(void) {
    spiffs_config config = {.phys_size=CAPACITY, .phys_erase_block=BLOCK,
        .log_block_size=BLOCK, .log_page_size=PAGE, .hal_read_f=read_bytes,
        .hal_write_f=write_bytes, .hal_erase_f=erase};
    memset(&fs, 0, sizeof(fs));
    memset(fds, 0, sizeof(fds));
    memset(cache, 0, sizeof(cache));
    return SPIFFS_mount(&fs, &config, work, (u8_t *)fds, sizeof(fds), cache, sizeof(cache), NULL);
}
static void make_record(unsigned n, unsigned char record[RECORD]) {
    memset(record, 0, RECORD);
    record[0]='F'; record[1]='J'; record[2]=1; record[3]=4;
    for (unsigned i=0; i<4; ++i) record[4+i] = n >> (8*i);
    uint32_t crc = crc32(0, record, 68);
    for (unsigned i=0; i<4; ++i) record[68+i] = crc >> (8*i);
}
static int append(unsigned n) {
    unsigned char record[RECORD];
    make_record(n, record);
    spiffs_file fd = SPIFFS_open(&fs, "/FPRJNL.BIN", SPIFFS_O_CREAT|SPIFFS_O_APPEND|SPIFFS_O_WRONLY, 0);
    if (fd < 0) return -1;
    uint32_t mtime=n;
    SPIFFS_fupdate_meta(&fs, fd, &mtime);
    int written=SPIFFS_write(&fs, fd, record, RECORD);
    spiffs_stat st;
    int flush=SPIFFS_fstat(&fs, fd, &st);
    int closed=SPIFFS_close(&fs, fd);
    return written==RECORD && !flush && !closed ? 0 : -1;
}
static int replay(unsigned expected) {
    spiffs_file fd=SPIFFS_open(&fs,"/FPRJNL.BIN",SPIFFS_O_RDONLY,0);
    assert(fd>=0);
    unsigned char record[RECORD], want[RECORD];
    for (unsigned i=0; i<expected; ++i) {
        make_record(i, want);
        if (SPIFFS_read(&fs,fd,record,RECORD)!=RECORD || memcmp(record,want,RECORD)) {
            fprintf(stderr,"cut %u lost acknowledged record %u\n",cut,i);
            return -1;
        }
    }
    int extra=SPIFFS_read(&fs,fd,record,RECORD);
    if (extra==RECORD) {
        make_record(expected,want);
        uint32_t stored = record[68] | ((uint32_t)record[69]<<8) | ((uint32_t)record[70]<<16) | ((uint32_t)record[71]<<24);
        if (record[0]=='F' && record[1]=='J' && record[2]==1 && record[3]>0 && record[3]<=64 && stored==crc32(0,record,68)) {
            assert(!memcmp(record,want,RECORD));
            assert(SPIFFS_read(&fs,fd,record,RECORD)==0);
        }
    } else assert(extra>=0);
    assert(!SPIFFS_close(&fs,fd));
    return 0;
}
int main(int argc, char **argv) {
    int collection = argc == 2 && strcmp(argv[1], "--gc") == 0;
    if (argc != 1 && !collection) return 2;
    memset(flash,255,sizeof(flash));
    assert(mount_fs()<0 && !SPIFFS_format(&fs) && !mount_fs());
    unsigned prefix = 3;
    if (collection) {
        prefix = 0;
        do {
            memcpy(baseline, flash, sizeof(flash));
            erases = 0;
            assert(!append(prefix));
            if (!erases) ++prefix;
        } while (!erases);
        printf("First garbage collection follows %u acknowledged records\n", prefix);
    } else {
        for (unsigned i=0; i<prefix; ++i) assert(!append(i));
        memcpy(baseline,flash,sizeof(flash));
    }
    for (cut=0;;++cut) {
        memcpy(flash,baseline,sizeof(flash));
        assert(!mount_fs());
        byte_count=0; injecting=1;
        if (!setjmp(outage)) {
            assert(!append(prefix));
            injecting=0;
            assert(!mount_fs() && !replay(prefix+1));
            break;
        }
        injecting=0;
        if (mount_fs() || replay(prefix)) return 1;
    }
    printf("%u interrupted byte positions preserved %u acknowledged records\n",cut,prefix);
    unsigned total=prefix+1;
    while (!append(total)) ++total;
    assert(!mount_fs() && !replay(total));
    printf("Volume full after %u acknowledged records, all replayed on remount\n",total);
    return 0;
}
