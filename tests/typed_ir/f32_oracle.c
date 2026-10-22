/* Included after the shared kernel oracle runtime: F32 columns (kind 7, rep 4),
   values as their 32 bits in the word; every expected value is computed with
   C float arithmetic one rounding at a time (volatile stops contraction). */
extern V fpr_fn_probeMap(V,V),fpr_fn_probeFilter(V,V),fpr_fn_probeFold(V,V,V);
static V fb(float f) { union { float f; uint32_t u; } c; c.f=f; return (V)(uintptr_t)c.u; }
static float bf(V v) { union { uint32_t u; float f; } c; c.u=(uint32_t)(uintptr_t)v; return c.f; }
int main(void) {
#ifdef __riscv
    __asm__ volatile("mv tp,%0" :: "r"(hart) : "memory");
#endif
    hart[57]=0; hart[58]=(V)UINTPTR_MAX;
    V cells[128]; uint8_t kinds[8]={7}; Col col={128,cells}; Col *cols[]={&col};
    float expected[128];
    int cases=0;
    for(int n=0;n<100;n++) for(int ci=-3;ci<=3;ci++) {
        float c=(float)ci*0.75f;
        used=0; hart[0]=1;
        Vec v={9006,4,n,0,0,1,kinds,n?cols:0};
        for(int i=0;i<n;i++) { expected[i]=(float)(i-20)*0.5f; cells[i]=fb(expected[i]); }
        CHECK(fpr_fn_probeMap(fb(c),(V)&v)==(V)&v);
        for(int i=0;i<n;i++) {
            volatile float t=expected[i]*c; volatile float r=t+0.5f; expected[i]=r;
            CHECK((uint32_t)cells[i]==(uint32_t)fb(expected[i]));
        }
        CHECK(fpr_fn_probeFilter(fb(c),(V)&v)==(V)&v);
        int kept=0;
        for(int i=0;i<n;i++) if(expected[i]>c) { CHECK((uint32_t)cells[kept]==(uint32_t)fb(expected[i])); expected[kept++]=expected[i]; }
        CHECK(v.len==kept);
        V pair=fpr_fn_probeFold(fb(c),fb(1.0f),(V)&v);
        float acc=1.0f;
        for(int i=0;i<kept;i++) { volatile float t=expected[i]*c; volatile float s=acc+t; acc=s; }
        CHECK((uint32_t)*(V*)((char*)pair+8)==(uint32_t)fb(acc));
        CHECK(*(V*)((char*)pair+8+sizeof(V))==(V)&v);
        cases++;
    }
    /* an Int vector, then an F64 column under the float representation: generic */
    Vec bad={9006,1,5,0,0,1,kinds,cols};
    CHECK(fpr_fn_probeMap(fb(1.0f),(V)&bad)==123);
    bad.rep=4; kinds[0]=3;
    CHECK(fpr_fn_probeFilter(fb(1.0f),(V)&bad)==123);
    CHECK(fallbacks==2 && yields>100 && cases==700);
    say("TYPED_KERNEL_PASS 700 F32 cases: map, filter, fold, empty columns, guard fallbacks, hostile yields\n");
    return 0;
}
