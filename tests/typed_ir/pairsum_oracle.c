/* Included after the shared kernel oracle runtime: the pair-sum fold offers
   the GPU hook first; this hook takes exactly one length and declines the
   rest, so both the hook's answer and the CPU path are checked. */
extern V fpr_fn_samplePair(V),fpr_fn_probePairSum(V,V);
static unsigned hooked;
V fpr_gpu_vec_fold_pair_sum_tagged(void *col0,void *col1,uintptr_t len,intptr_t seed) {
    (void)col0; (void)col1;
    if(len!=77) return 0;
    hooked++;
    return tag(seed+4242);
}
int main(void) {
#ifdef __riscv
    __asm__ volatile("mv tp,%0" :: "r"(hart) : "memory");
#endif
    hart[57]=0; hart[58]=(V)UINTPTR_MAX; hart[0]=1;
    V sample=fpr_fn_samplePair(tag(1));
    uint32_t shape=((uint32_t*)sample)[0], variant=((uint32_t*)sample)[1];
    static V cells[2][100]; uint8_t kinds[2]={1,1};
    Col col[2]={{100,cells[0]},{100,cells[1]}}; Col *cols[2]={&col[0],&col[1]};
    int cases=0;
    for(int n=0;n<100;n++) {
        used=0; hart[0]=1;
        Vec v={9006,3,n,shape,variant,2,kinds,n?cols:0};
        V sum=5;
        for(int i=0;i<n;i++) { cells[0][i]=i-30; cells[1][i]=3*i; sum+=(i-30)+3*i; }
        if(n==77) sum=5+4242;
        V pair=fpr_fn_probePairSum(tag(5),(V)&v);
        CHECK(*(V*)((char*)pair+8)==tag(sum));
        CHECK(*(V*)((char*)pair+8+sizeof(V))==(V)&v);
        cases++;
    }
    Vec bad={9006,1,5,shape,variant,2,kinds,cols};
    CHECK(fpr_fn_probePairSum(tag(5),(V)&bad)==123);
    CHECK(hooked==1 && fallbacks==1 && cases==100);
    say("TYPED_KERNEL_PASS 100 pair-sum folds: the GPU hook's answer once, the CPU strip otherwise, guard fallback\n");
    return 0;
}
