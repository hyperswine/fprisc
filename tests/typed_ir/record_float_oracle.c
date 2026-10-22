extern V fpr_fn_sampleFloat(V), fpr_fn_probeFloatMap(V,V), fpr_fn_probeFloatFilter(V);
extern V fpr_fn_probeFloatFold(V,V,V,V);
static V bits(double d) { union {double d; V v;} u={.d=d}; return u.v; }
static double number(V v) { union {double d; V v;} u={.v=v}; return u.d; }
static int equalFloat(V a,double b) { double d=number(a); return d==b || (d!=d && b!=b); }
int main(void) {
#ifdef __riscv
    __asm__ volatile("mv tp,%0" :: "r"(hart) : "memory");
#endif
    hart[57]=0;hart[58]=(V)UINTPTR_MAX;hart[0]=1;
    V sample=fpr_fn_sampleFloat(tag(2));
    uint32_t shape=((uint32_t*)sample)[0],variant=((uint32_t*)sample)[1];
    V cells[3][100];uint8_t kinds[]={1,3,3};Col col[3];Col *cols[3];
    for(int j=0;j<3;j++) {col[j]=(Col){100,cells[j]};cols[j]=&col[j];}
    for(int n=0;n<100;n++) for(int cap=-2;cap<=2;cap++) {
        used=0;hart[0]=1;
        V c=fpr_fn_sampleFloat(tag(cap));
        Vec v={9006,3,n,shape,variant,3,kinds,n?cols:0};
        for(int i=0;i<n;i++) {cells[0][i]=i;cells[1][i]=bits(i*0.5);cells[2][i]=bits(0.25-i*0.125);}
        CHECK(fpr_fn_probeFloatMap(c,(V)&v)==(V)&v);
        for(int i=0;i<n;i++) {CHECK(cells[0][i]==i+cap);CHECK(equalFloat(cells[1][i],(0.25-i*0.125)*1.5));CHECK(equalFloat(cells[2][i],i*0.5+2.25));}
        CHECK(fpr_fn_probeFloatFilter((V)&v)==(V)&v);
        int kept=0; double sum=7;
        for(int i=0;i<n;i++) if(i+cap>3) {
            double x=(0.25-i*0.125)*1.5,y=i*0.5+2.25;
            CHECK(cells[0][kept]==i+cap && equalFloat(cells[1][kept],x) && equalFloat(cells[2][kept],y));
            kept++;sum=sum+x*2+(i+cap>4?y:0);
        }
        V pair=fpr_fn_probeFloatFold(bits(2),tag(4),bits(7),(V)&v);
        CHECK(v.len==kept && equalFloat(*(V*)((char*)pair+8),sum));
        CHECK(*(V*)((char*)pair+8+sizeof(V))==(V)&v);
    }
    CHECK(yields>1000 && fallbacks==0);
    say("TYPED_KERNEL_PASS 500 mixed Int/F64 record cases: captured map, stable filter, captured fold, empty, hostile yields\n");
    return 0;
}
