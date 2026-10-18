/* Tang Nano SD SPI HAL: registers and one bounded scratch sector only.
 * The card protocol, CRC, partition and file logic live in FP-RISC.
 * Single caller, manual Base ownership; no DMA or filesystem C library.
 */
#include "fpr.h"
#include <string.h>

#ifdef FPR_SD_HAL_TEST
extern uint32_t fpr_sd_hal_test_read(unsigned reg);
extern void fpr_sd_hal_test_write(unsigned reg, uint32_t value);
#define REG_READ(reg) fpr_sd_hal_test_read(reg)
#define REG_WRITE(reg, value) fpr_sd_hal_test_write(reg, value)
#else
#define SPI ((volatile uint32_t *)0x10001000u)
#define REG_READ(reg) SPI[reg]
#define REG_WRITE(reg, value) (SPI[reg] = (value))
#endif

static uint32_t control = 255u << 8;
static uint8_t sector[512];

static sw integer(V v) {
  if (!ISINT(v)) fpr_cpanic("SdSpi: expected Int");
  return UNTAG(v);
}
static unsigned index_of(V v) {
  sw n = integer(v);
  if (n < 0 || n >= 512) fpr_cpanic("SdSpi: sector index outside 0..511");
  return (unsigned)n;
}
static V h_select(V on) {
  if (ISINT(on) || !on || TID(on) != T_BOOL || ((const hdr_t *)on)->var > 1)
    fpr_cpanic("SdSpi.select: expected Bool");
  control = (control & ~1u) | ((const hdr_t *)on)->var;
  REG_WRITE(2, control);
  return (V)&fpr_unit;
}
static V h_divider(V v) {
  sw n = integer(v);
  if (n < 0 || n > 255) fpr_cpanic("SdSpi.divider: outside 0..255");
  control = (control & 1u) | ((uint32_t)n << 8);
  REG_WRITE(2, control);
  return (V)&fpr_unit;
}
static V h_transfer(V v) {
  sw n = integer(v);
  if (n < 0 || n > 255) fpr_cpanic("SdSpi.transfer: outside 0..255");
  if (REG_READ(3) != 0x53445031u) return TAG(-1); /* SDP1 capability */
  unsigned budget = 1000000;
  while (REG_READ(1) & 1u) if (!--budget) return TAG(-1);
  REG_WRITE(0, (uint32_t)n);
  budget = 1000000;
  while (REG_READ(1) & 1u) if (!--budget) return TAG(-1);
  return TAG(REG_READ(0) & 255u);
}
static V h_get(V v) { return TAG(sector[index_of(v)]); }
static V h_set(V iv, V bv) {
  unsigned i = index_of(iv);
  sw b = integer(bv);
  if (b < 0 || b > 255) fpr_cpanic("SdSpi.bufferSet: outside 0..255");
  sector[i] = (uint8_t)b;
  return (V)&fpr_unit;
}
static V h_text(V v) {
  sw n = integer(v);
  if (n < 0 || n > 512) fpr_cpanic("SdSpi.bufferText: outside 0..512");
  return (V)fpr_mkstr(sector, (uw)n);
}
static V h_load(V v) {
  if (ISINT(v) || TID(v) != T_STR) fpr_cpanic("SdSpi.bufferLoad: expected String");
  const str_t *s = (const str_t *)v;
  if (s->len > sizeof(sector)) return BOOL(0);
  memcpy(sector, s->bytes, s->len);
  memset(sector + s->len, 0, sizeof(sector) - s->len);
  return BOOL(1);
}

FPR_FN(fpr_g_SdSpi_x2eselect, h_select, 1);
FPR_FN(fpr_g_SdSpi_x2edivider, h_divider, 1);
FPR_FN(fpr_g_SdSpi_x2etransfer, h_transfer, 1);
FPR_FN(fpr_g_SdSpi_x2ebufferGet, h_get, 1);
FPR_FN(fpr_g_SdSpi_x2ebufferSet, h_set, 2);
FPR_FN(fpr_g_SdSpi_x2ebufferText, h_text, 1);
FPR_FN(fpr_g_SdSpi_x2ebufferLoad, h_load, 1);
