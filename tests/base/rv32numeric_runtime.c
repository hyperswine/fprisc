/* Runtime-level RV32 numeric ABI probe. Linked as fpr_fn_main by the
 * Tang Nano Base host (FPR_QEMU=1 also runs it on qemu-system-riscv32).
 * This bypasses source lowering so a compiler and runtime ABI bug cannot
 * accidentally agree with one another. */
#include "fpr.h"
#include "i32.h"

#define PRIM1(n) extern V n(V)
#define PRIM2(n) extern V n(V,V)
PRIM1(fpr_prim_fn_F64_x2etoInt);
PRIM1(fpr_prim_fn_F64_x2estr);
PRIM1(fpr_prim_fn_F32_x2estr);
PRIM2(fpr_prim_fn_F64_x2e_x2b);
PRIM2(fpr_prim_fn_F64_x2e_x3d_x3d);
PRIM2(fpr_prim_fn_F32_x2e_x3d_x3d);
PRIM2(fpr_prim_fn__x3d_x3d);
#define PAP(n) extern const pap0_t fpr_g_##n
PAP(I64_x2eparse); PAP(I64_x2estr); PAP(I64_x2ehex);
PAP(I64_x2e_x2b); PAP(I64_x2e_x2a); PAP(I64_x2edivU);
PAP(I64_x2etoInt); PAP(I64_x2eofF64Bits); PAP(I64_x2etoF64Bits);
PAP(I64_x2ehi); PAP(I64_x2ehiWord); PAP(I64_x2eloWord); PAP(I64_x2efromWords);
PAP(keep); PAP(Vec_x2enewAs); PAP(Vec_x2epush); PAP(Vec_x2eget); PAP(Vec_x2efree);
PAP(I32_x2e_x2b); PAP(I32_x2e_x2a); PAP(I32_x2e_x2f); PAP(I32_x2erem);
PAP(I32_x2edivU); PAP(I32_x2etoInt); PAP(I32_x2etoIntU); PAP(I32_x2estr);
PAP(I32_x2etoI64U); PAP(I32_x2eofI64); PAP(I32_x2eofF64); PAP(I32_x2eofF64U);
PAP(I32_x2eofF32Bits); PAP(I32_x2etoF32Bits);
#define CALL1(n,a) fpr_apply((V)&fpr_g_##n,(a))
#define CALL2(n,a,b) fpr_apply(CALL1(n,a),(b))

static void check(int yes, const char *why) { if (!yes) fpr_cpanic(why); }
static V text(const char *s) { uw n=0; while(s[n])n++; return (V)fpr_mkstr((const uint8_t *)s,n); }
static void eqtext(V v,const char *s) {
  check(!ISINT(v) && TID(v)==T_STR,"numeric probe expected String");
  str_t *t=(str_t *)v; uw n=0;
  while(s[n]) {
    if (n>=t->len || t->bytes[n]!=(uint8_t)s[n]) {
      const char *p="numeric probe got: "; while(*p)hal_putc(*p++);
      for(uw i=0;i<t->len;i++)hal_putc((char)t->bytes[i]);
      p=" expected: "; while(*p)hal_putc(*p++);
      p=s;while(*p)hal_putc(*p++);hal_putc('\n');
      fpr_cpanic("numeric probe String differs");
    }
    n++;
  }
  check(n==t->len,"numeric probe String length differs");
}
static V parse(const char *s) {
  V r=CALL1(I64_x2eparse,text(s));
  check(TID(r)==T_RESULT && ((hdr_t *)r)->var==0,"I64.parse refused valid bits");
  return FPR_FLD(r,0);
}
static V product2(uint32_t tid,V a,V b) {
  V v=fpr_alloc(8+2*sizeof(V));
  ((hdr_t *)v)->tid=tid; ((hdr_t *)v)->var=tid==T_LIST ? 1 : 0;
  FPR_FLD(v,0)=a; FPR_FLD(v,1)=b;
  return v;
}

V fpr_fn_main(void) {
  check(sizeof(fpr_num64_t)==24 && offsetof(fpr_num64_t,val)==16,"wide numeric layout changed");
  V half=fpr_f64_from_bits32(0x3ff80000u,0), two=fpr_f64_from_bits32(0x40000000u,0);
  eqtext(fpr_prim_fn_F64_x2estr(fpr_prim_fn_F64_x2e_x2b(half,two)),"3.5");
  eqtext(fpr_prim_fn_F64_x2estr(fpr_f64_from_bits32(0x41f00000u,0)),"4294967296");
  V lower=fpr_f64_from_bits32(0x3ff00000u,0x80000001u);
  eqtext(CALL1(I64_x2ehex,CALL1(I64_x2eofF64Bits,lower)),"3ff0000080000001");
  V minuszero=fpr_f64_from_bits32(0x80000000u,0);
  eqtext(CALL1(I64_x2ehex,CALL1(I64_x2eofF64Bits,minuszero)),"8000000000000000");
  eqtext(fpr_prim_fn_F32_x2estr(fpr_f32_from_bits32(0x80000000u)),"-0");
  eqtext(fpr_prim_fn_F32_x2estr(fpr_f32_from_bits32(0x7f800000u)),"Inf");
  V nan=fpr_f64_from_bits32(0x7ff80000u,123), nan32=fpr_f32_from_bits32(0x7fc00001u);
  check(UNTAG(fpr_prim_fn_F64_x2etoInt(fpr_f64_from_bits32(0xc1d00000u,0x00200000u)))==-1073741824,
        "F64.toInt rejected an in-range truncated minimum");
  check(fpr_prim_fn_F64_x2e_x3d_x3d(nan,nan)==(V)&fpr_false,"F64 NaN equals itself");
  check(fpr_prim_fn_F32_x2e_x3d_x3d(nan32,nan32)==(V)&fpr_false,"F32 NaN equals itself");
  V max=parse("9223372036854775807"), one=parse("1"), neg=parse("0xffffffffffffffff");
  eqtext(CALL1(I64_x2estr,CALL2(I64_x2e_x2b,max,one)),"-9223372036854775808");
  eqtext(CALL1(I64_x2estr,CALL2(I64_x2e_x2a,parse("4294967296"),parse("4294967296"))),"0");
  eqtext(CALL1(I64_x2estr,CALL2(I64_x2edivU,neg,parse("2"))),"9223372036854775807");
  V intresult=CALL1(I64_x2etoInt,max);
  check(((hdr_t *)intresult)->var==1,"I64.toInt silently truncated");
  V words=CALL2(I64_x2efromWords,CALL1(I64_x2ehiWord,neg),CALL1(I64_x2eloWord,neg));
  eqtext(CALL1(I64_x2ehex,words),"ffffffffffffffff");
  V round=CALL1(I64_x2etoF64Bits,CALL1(I64_x2eofF64Bits,lower));
  check(fpr_prim_fn_F64_x2e_x3d_x3d(round,lower)==(V)&fpr_true,"I64 float bit roundtrip differs");

  V pair=fpr_alloc(8+2*sizeof(V)); ((hdr_t *)pair)->tid=T_TUP2; ((hdr_t *)pair)->var=0;
  FPR_FLD(pair,0)=max; FPR_FLD(pair,1)=neg;
  V copy=CALL1(keep,pair);
  check(copy!=pair && FPR_FLD(copy,0)!=max,"keep shared numeric boxes");
  check(fpr_prim_fn__x3d_x3d(pair,copy)==(V)&fpr_true,"copied I64 tuple differs");

  V vec=CALL1(Vec_x2enewAs,text("d"));
  vec=CALL2(Vec_x2epush,half,vec); vec=CALL2(Vec_x2epush,two,vec);
  V duplicate=CALL1(keep,vec);
  V got=CALL2(Vec_x2eget,TAG(0),duplicate), value=FPR_FLD(got,0);
  check(fpr_prim_fn_F64_x2e_x3d_x3d(value,half)==(V)&fpr_true,"kept float Vector differs");
#if UINTPTR_MAX <= 0xFFFFFFFFu
  check(value!=half,"RV32 kept float Vector shares source box");
  check(fpr_prim_fn__x3d_x3d(nan,nan)==(V)&fpr_false,"boxed generic NaN equals itself");
  static const hdr_t nil={T_LIST,0};
  V nanpair=product2(T_TUP2,nan,nan32), nanlist=product2(T_LIST,nan,(V)&nil);
  check(fpr_prim_fn__x3d_x3d(nanpair,nanpair)==(V)&fpr_false,"shared NaN tuple equals itself");
  check(fpr_prim_fn__x3d_x3d(nanlist,nanlist)==(V)&fpr_false,"shared NaN list equals itself");
  V negativezeros=product2(T_TUP2,minuszero,fpr_f32_from_bits32(0x80000000u));
  V positivezeros=product2(T_TUP2,fpr_f64_from_bits32(0,0),fpr_f32_from_bits32(0));
  check(fpr_prim_fn__x3d_x3d(negativezeros,positivezeros)==(V)&fpr_true,"signed-zero tuples differ");
  V negativezerolist=product2(T_LIST,minuszero,(V)&nil);
  V positivezerolist=product2(T_LIST,fpr_f64_from_bits32(0,0),(V)&nil);
  check(fpr_prim_fn__x3d_x3d(negativezerolist,positivezerolist)==(V)&fpr_true,"signed-zero lists differ");
  check(fpr_prim_fn__x3d_x3d(vec,vec)==(V)&fpr_true,"Vector identity equality changed");
#endif
  CALL1(Vec_x2efree,vec); CALL1(Vec_x2efree,duplicate);
  V max32=fpr_i32_pack(0x7fffffffu),minus32=fpr_i32_pack(0xffffffffu),one32=fpr_i32_pack(1);
  eqtext(CALL1(I32_x2estr,CALL2(I32_x2e_x2b,max32,one32)),"-2147483648");
  check(fpr_i32_bits(CALL2(I32_x2e_x2a,minus32,minus32))==1,"I32 multiply does not wrap");
  check(fpr_i32_bits(CALL2(I32_x2edivU,minus32,fpr_i32_pack(2)))==0x7fffffffu,"I32 unsigned divide differs");
  check(fpr_i32_bits(CALL2(I32_x2erem,fpr_i32_pack(0x80000000u),minus32))==0,"I32 min rem -1 differs");
  eqtext(CALL1(I64_x2estr,CALL1(I32_x2etoI64U,minus32)),"4294967295");
  check(fpr_i32_bits(CALL1(I32_x2eofI64,neg))==UINT32_MAX,"I32.ofI64 loses low bits");
  V ni=CALL1(I32_x2eofF64,fpr_f64_from_bits32(0xc1e00000u,0x00100000u)); /* -2147483648.5 */
  check(((hdr_t *)ni)->var==0 && fpr_i32_bits(FPR_FLD(ni,0))==0x80000000u,"I32 float signed boundary refused after truncation");
  V nu=CALL1(I32_x2eofF64U,fpr_f64_from_bits32(0xbfe00000u,0)); /* -0.5 -> 0 */
  check(((hdr_t *)nu)->var==0 && fpr_i32_bits(FPR_FLD(nu,0))==0,"I32 float unsigned truncation differs");
  V bitrt=CALL1(I32_x2eofF32Bits,CALL1(I32_x2etoF32Bits,minus32));
  check(fpr_i32_bits(bitrt)==UINT32_MAX,"I32 F32 bitcast changes NaN bits");
#if UINTPTR_MAX <= 0xFFFFFFFFu
  check(((hdr_t *)CALL1(I32_x2etoInt,max32))->var==1,"I32.toInt silently truncates on RV32");
  check(((hdr_t *)CALL1(I32_x2etoIntU,minus32))->var==1,"I32.toIntU silently truncates on RV32");
  V boxcopy=CALL1(keep,minus32);
  check(boxcopy!=minus32 && fpr_prim_fn__x3d_x3d(boxcopy,minus32)==(V)&fpr_true,"I32 keep/equality differs");
#endif
#ifdef FPR_TEST_I64_HALF_TRAP
  (void)CALL1(I64_x2ehi,neg);
  fpr_cpanic("I64.hi silently truncated unsigned half");
#elif defined(FPR_TEST_FLOAT_INT_TRAP)
  (void)fpr_prim_fn_F64_x2etoInt(fpr_f64_from_bits32(0x41d00000u,0));
  fpr_cpanic("F64.toInt silently truncated out-of-range value");
#elif defined(FPR_TEST_I32_DIV_TRAP)
  (void)CALL2(I32_x2e_x2f,fpr_i32_pack(0x80000000u),minus32);
  fpr_cpanic("I32 min/-1 did not trap");
#elif defined(FPR_TEST_FLOAT_INT_MIN_TRAP)
  (void)fpr_prim_fn_F64_x2etoInt(fpr_f64_from_bits32(0xc1d00000u,0x00400000u));
  fpr_cpanic("F64.toInt silently truncated below the tagged minimum");
#elif defined(FPR_TEST_FLOAT_INT_NAN_TRAP)
  (void)fpr_prim_fn_F64_x2etoInt(nan);
  fpr_cpanic("F64.toInt accepted NaN");
#else
  const char *s="RV32 numeric runtime: all ok\n"; while(*s)hal_putc(*s++);
  return (V)&fpr_unit;
#endif
}
