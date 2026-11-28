#include "log.h"
#include "esp_flash.h"
#include "esp_partition.h"
#include "esp_rom_crc.h"
#include "esp_system.h"
#include <assert.h>
#include <stdio.h>
#ifdef NDEBUG
#error Media qualification requires enabled assertions
#endif

static int read_at(void *part,size_t at,void *buf,size_t n) {
    return esp_partition_read(part,at,buf,n) == ESP_OK ? 0 : -1;
}
static int program(void *part,size_t at,const void *buf,size_t n) {
    if (n == 4 && at % C3LOG_SLOT_BYTES == 124) {
        puts("FAULT: durable body verified, resetting before commit word");
        fflush(stdout);
        esp_restart();
    }
    return esp_partition_write(part,at,buf,n) == ESP_OK ? 0 : -1;
}
static uint32_t crc(const void *p,size_t n) { return esp_rom_crc32_le(0,p,n); }
void app_main(void) {
    const esp_partition_t *p=esp_partition_find_first(ESP_PARTITION_TYPE_DATA,0x40,"fprjournal");
    assert(p && p->address==0x280000 && p->size==65536);
    uint32_t actual;
    ESP_ERROR_CHECK(esp_flash_get_physical_size(NULL,&actual));
    assert(actual>=p->address+p->size);
    esp_flash_default_chip->size=p->address+p->size;
    c3log log={.context=(void *)p,.bytes=p->size,.read=read_at,.program=program,.crc=crc};
    assert(!c3log_mount(&log));
    printf("Next unused physical slot %u\n",(unsigned)log.next); fflush(stdout);
    const char torn[]="INTERRUPTED-MEDIA-WRITE";
    int rc=c3log_append(&log,"FPRJNL.BIN",10,torn,sizeof(torn)-1);
    printf("Unexpected return %d\n",rc);
    abort();
}
