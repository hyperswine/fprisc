/* I32: wrapping two's-complement 32-bit arithmetic on every word size.
 * Keep the integer half independent of runtime.c so manual Builtin images
 * can use it without linking actors, floats, or the Base host runtime. */
#include "i32.h"
#if defined(FPR_BUILTIN_ARC) || defined(FPR_BUILTIN_RAW)
/* Exact metadata is required even though the Ok payload is immediate:
 * an Err owns a freshly allocated String which release must traverse. */
extern V fpr_builtin_alloc_adt(V bytes,uw fields);
#endif

static int32_t s32(V v) { return (int32_t)fpr_i32_bits(v); }
static unsigned count(V v) { return (unsigned)((uw)UNTAG(v) & 31u); }
static V add(V a,V b) { return fpr_i32_pack(fpr_i32_bits(a)+fpr_i32_bits(b)); }
static V sub(V a,V b) { return fpr_i32_pack(fpr_i32_bits(a)-fpr_i32_bits(b)); }
static V mul(V a,V b) { return fpr_i32_pack(fpr_i32_bits(a)*fpr_i32_bits(b)); }
static V divs(V a,V b) {
  int32_t x=s32(a),y=s32(b);
  if (!y) fpr_trap("I32: division by zero");
  if (x==INT32_MIN && y==-1) fpr_trap("I32: division overflow (INT32_MIN / -1)");
  return fpr_i32_pack((uint32_t)(x/y));
}
static V rems(V a,V b) {
  int32_t x=s32(a),y=s32(b);
  if (!y) fpr_trap("I32: division by zero");
  if (y==-1) return fpr_i32_pack(0);
  return fpr_i32_pack((uint32_t)(x%y));
}
static V divu(V a,V b) {
  uint32_t y=fpr_i32_bits(b);
  if (!y) fpr_trap("I32: division by zero");
  return fpr_i32_pack(fpr_i32_bits(a)/y);
}
static V remu(V a,V b) {
  uint32_t y=fpr_i32_bits(b);
  if (!y) fpr_trap("I32: division by zero");
  return fpr_i32_pack(fpr_i32_bits(a)%y);
}
#define COMP(name,type,op) static V name(V a,V b) { return BOOL((type)fpr_i32_bits(a) op (type)fpr_i32_bits(b)); }
COMP(lt,int32_t,<) COMP(gt,int32_t,>) COMP(le,int32_t,<=) COMP(ge,int32_t,>=)
COMP(eq,uint32_t,==) COMP(ne,uint32_t,!=)
COMP(ltu,uint32_t,<) COMP(gtu,uint32_t,>) COMP(leu,uint32_t,<=) COMP(geu,uint32_t,>=)
#define BIN(name,op) static V name(V a,V b) { return fpr_i32_pack(fpr_i32_bits(a) op fpr_i32_bits(b)); }
BIN(and_,&) BIN(or_,|) BIN(xor_,^)
static V not_(V a) { return fpr_i32_pack(~fpr_i32_bits(a)); }
static V neg(V a) { return fpr_i32_pack(0u-fpr_i32_bits(a)); }
static V shl(V a,V k) { return fpr_i32_pack(fpr_i32_bits(a)<<count(k)); }
static V shr(V a,V k) { return fpr_i32_pack(fpr_i32_bits(a)>>count(k)); }
static V sar(V a,V k) { return fpr_i32_pack((uint32_t)(s32(a)>>count(k))); }
static V rotl(V a,V k) {
  uint32_t x=fpr_i32_bits(a);unsigned n=count(k);
  return fpr_i32_pack(n ? (x<<n)|(x>>(32-n)) : x);
}
static V rotr(V a,V k) {
  uint32_t x=fpr_i32_bits(a);unsigned n=count(k);
  return fpr_i32_pack(n ? (x>>n)|(x<<(32-n)) : x);
}
/* Written without compiler bit builtins: manual bare-metal links do not
 * require libgcc merely to count a word's bits. */
static V clz(V a) {
  uint32_t x=fpr_i32_bits(a);unsigned n=0;
  if (!x) return TAG(32);
  while (!(x&0x80000000u)) { x<<=1;n++; }
  return TAG(n);
}
static V ctz(V a) {
  uint32_t x=fpr_i32_bits(a);unsigned n=0;
  if (!x) return TAG(32);
  while (!(x&1u)) { x>>=1;n++; }
  return TAG(n);
}
static V popcnt(V a) {
  uint32_t x=fpr_i32_bits(a);unsigned n=0;
  while (x) { x&=x-1;n++; }
  return TAG(n);
}
static V result(unsigned var,V value) {
#if defined(FPR_BUILTIN_ARC) || defined(FPR_BUILTIN_RAW)
  V r=fpr_builtin_alloc_adt(8+sizeof(V),1);
#else
  V r=fpr_alloc(8+sizeof(V));
#endif
  ((hdr_t *)r)->tid=T_RESULT;((hdr_t *)r)->var=var;
  FPR_FLD(r,0)=value;return r;
}
static V error(const char *s) {
  uw n=0;while(s[n])n++;
  return result(1,(V)fpr_mkstr((const uint8_t *)s,n));
}
static V ofInt(V v) { return fpr_i32_pack((uint32_t)UNTAG(v)); }
static V toInt(V v) {
  int32_t n=s32(v);
#if UINTPTR_MAX <= 0xFFFFFFFFu
  if (n<-(1<<30) || n>((1<<30)-1)) return error("I32.toInt: does not fit an Int (31 bits)");
#endif
  return result(0,TAG((sw)n));
}
static V toIntU(V v) {
  uint32_t n=fpr_i32_bits(v);
#if UINTPTR_MAX <= 0xFFFFFFFFu
  if (n>((1u<<30)-1)) return error("I32.toIntU: does not fit an Int (31 bits)");
#endif
  return result(0,TAG((sw)n));
}
static V digits(uint32_t n,int negative) {
  char buf[12];unsigned i=12;
  do { buf[--i]=(char)('0'+n%10u);n/=10u; } while(n);
  if (negative)buf[--i]='-';
  return (V)fpr_mkstr((const uint8_t *)buf+i,12-i);
}
static V str(V v) {
  int32_t n=s32(v);
  return digits(n<0 ? 0u-(uint32_t)n : (uint32_t)n,n<0);
}
static V strU(V v) { return digits(fpr_i32_bits(v),0); }
static V hex(V v) {
  char buf[8];unsigned i=8;uint32_t n=fpr_i32_bits(v);
  do { buf[--i]="0123456789abcdef"[n&15u];n>>=4; } while(n);
  return (V)fpr_mkstr((const uint8_t *)buf+i,8-i);
}
static V parse(V value) {
  if (!value || ISINT(value) || TID(value)!=T_STR) fpr_cpanic("I32.parse: not a String");
  const str_t *s=(const str_t *)value;uw i=0;int negative=0,previous=0,seen=0;
  unsigned base=10;uint32_t n=0;
  if (i<s->len && (s->bytes[i]=='+' || s->bytes[i]=='-'))negative=s->bytes[i++]=='-';
  if (i+1<s->len && s->bytes[i]=='0' && s->bytes[i+1]=='x') { base=16;i+=2; }
  for (;i<s->len;i++) {
    unsigned c=s->bytes[i],d;
    if (c=='_') {
      if (!previous || i+1==s->len) return error("I32.parse: misplaced underscore");
      previous=0;continue;
    }
    if(c>='0' && c<='9')d=c-'0';
    else if(base==16 && c>='a' && c<='f')d=c-'a'+10;
    else if(base==16 && c>='A' && c<='F')d=c-'A'+10;
    else return error("I32.parse: not a number");
    if(d>=base)return error("I32.parse: not a number");
    if(n>(UINT32_MAX-d)/base)return error("I32.parse: more than 32 bits");
    n=n*base+d;previous=1;seen=1;
  }
  if(!seen)return error("I32.parse: no digits");
  return result(0,fpr_i32_pack(negative ? 0u-n : n));
}

FPR_FN(fpr_g_I32_x2e_x2b,add,2); FPR_FN(fpr_g_I32_x2e_x2d,sub,2);
FPR_FN(fpr_g_I32_x2e_x2a,mul,2); FPR_FN(fpr_g_I32_x2e_x2f,divs,2);
FPR_FN(fpr_g_I32_x2erem,rems,2); FPR_FN(fpr_g_I32_x2edivU,divu,2); FPR_FN(fpr_g_I32_x2eremU,remu,2);
FPR_FN(fpr_g_I32_x2e_x3c,lt,2); FPR_FN(fpr_g_I32_x2e_x3e,gt,2);
FPR_FN(fpr_g_I32_x2e_x3c_x3d,le,2); FPR_FN(fpr_g_I32_x2e_x3e_x3d,ge,2);
FPR_FN(fpr_g_I32_x2e_x3d_x3d,eq,2); FPR_FN(fpr_g_I32_x2e_x21_x3d,ne,2);
FPR_FN(fpr_g_I32_x2eltU,ltu,2); FPR_FN(fpr_g_I32_x2egtU,gtu,2);
FPR_FN(fpr_g_I32_x2eleU,leu,2); FPR_FN(fpr_g_I32_x2egeU,geu,2);
FPR_FN(fpr_g_I32_x2eand,and_,2); FPR_FN(fpr_g_I32_x2eor,or_,2); FPR_FN(fpr_g_I32_x2exor,xor_,2);
FPR_FN(fpr_g_I32_x2enot,not_,1); FPR_FN(fpr_g_I32_x2eneg,neg,1);
FPR_FN(fpr_g_I32_x2eshl,shl,2); FPR_FN(fpr_g_I32_x2eshr,shr,2); FPR_FN(fpr_g_I32_x2esar,sar,2);
FPR_FN(fpr_g_I32_x2erotl,rotl,2); FPR_FN(fpr_g_I32_x2erotr,rotr,2);
FPR_FN(fpr_g_I32_x2eclz,clz,1); FPR_FN(fpr_g_I32_x2ectz,ctz,1); FPR_FN(fpr_g_I32_x2epopcnt,popcnt,1);
FPR_FN(fpr_g_I32_x2eofInt,ofInt,1); FPR_FN(fpr_g_I32_x2etoInt,toInt,1); FPR_FN(fpr_g_I32_x2etoIntU,toIntU,1);
FPR_FN(fpr_g_I32_x2estr,str,1); FPR_FN(fpr_g_I32_x2estrU,strU,1); FPR_FN(fpr_g_I32_x2ehex,hex,1);
FPR_FN(fpr_g_I32_x2eparse,parse,1);
