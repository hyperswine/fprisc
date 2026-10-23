/* Included after the shared kernel oracle runtime. All expected values below
   are computed independently of the generated record planner and callbacks. */
extern V fpr_fn_sampleRow(V),fpr_fn_probeRecordMap(V),fpr_fn_probeRecordCaptured(V,V);
extern V fpr_fn_probeLastFilter(V);
extern V fpr_fn_probeRecordFilter(V),fpr_fn_probeRecordFold(V,V,V,V);
static V cells[300][100], expected[300][100];
static uint8_t kinds[300];
static Col col[300];
static Col *cols[300];
/* Unread fields are opaque words, even when their kinds advertise F64/F32
   or boxed data. Preserve signed zero, NaNs, extrema and pointer-like bits. */
static V opaque_cell(int c,int i) {
    uintptr_t n=(uintptr_t)((unsigned)(c+1)*0x9e3779b9U) ^ (unsigned)(i+17);
    switch((c+i)%8) {
    case 0: return 0;
    case 1: return (V)UINTPTR_MAX;
    case 2: return (V)((uintptr_t)1 << (8*sizeof(V)-1));
    case 3: return (V)(UINT64_C(0x7ff800007fc00000) | n);
    case 4: return (V)&fpr_true;
    case 5: return (V)(UINT32_C(0x7fc00001) | (unsigned)i);
    case 6: return (V)UINT32_C(0x80000000);
    default: return (V)n;
    }
}
int main(void) {
#ifdef __riscv
    __asm__ volatile("mv tp,%0" :: "r"(hart) : "memory");
#endif
    hart[57]=0; hart[58]=(V)UINTPTR_MAX; hart[0]=1;
    V sample=fpr_fn_sampleRow(tag(2));
    uint32_t shape=((uint32_t*)sample)[0], variant=((uint32_t*)sample)[1];
    if(TRAP_CASE) {
        for(int c=0;c<9;c++) { kinds[c]=1; col[c]=(Col){100,cells[c]}; cols[c]=&col[c]; cells[c][0]=0; }
        Vec v={9006,3,1,shape,variant,9,kinds,cols};
        cells[0][0]=INTPTR_MAX/2;
        cells[1][0]=1;
        fpr_fn_probeRecordMap((V)&v);
        oracle_finish(__LINE__);
    }
    int cases=0;
    for(int width=9;width<=300;width=width==9?64:width==64?300:301)
    for(int n=0;n<100;n++) for(int cap=-2;cap<=2;cap++) {
        used=0; hart[0]=1;
        V captured=fpr_fn_sampleRow(tag(cap));
        Vec v={9006,3,n,shape,variant,width,kinds,n?cols:0};
        for(int c=0;c<width;c++) {
            kinds[c]=c<9?1:(c%3==0?0:c%3==1?3:7);
            col[c]=(Col){100,cells[c]}; cols[c]=&col[c];
            for(int i=0;i<n;i++) cells[c][i]=expected[c][i]=i+c-20;
        }
        CHECK(fpr_fn_probeRecordMap((V)&v)==(V)&v);
        for(int i=0;i<n;i++) {
            V total=0;for(int c=0;c<9;c++) total+=expected[c][i];
            for(int c=8;c>0;c--) expected[c][i]=expected[c-1][i];
            expected[0][i]=total;
        }
        for(int c=0;c<width;c++) for(int i=0;i<n;i++) CHECK(cells[c][i]==expected[c][i]);
        CHECK(fpr_fn_probeRecordCaptured(captured,(V)&v)==(V)&v);
        for(int i=0;i<n;i++) expected[0][i]=cap*expected[8][i]+cap+1;
        for(int c=0;c<width;c++) for(int i=0;i<n;i++) CHECK(cells[c][i]==expected[c][i]);
        CHECK(fpr_fn_probeRecordFilter((V)&v)==(V)&v);
        int kept=0;V sum=7;
        for(int i=0;i<n;i++) {
            V total=0;for(int c=0;c<9;c++) total+=expected[c][i];
            if(total>400) {
                for(int c=0;c<width;c++) CHECK(cells[c][kept]==expected[c][i]);
                kept++;sum+=2*total+3;
            }
        }
        CHECK(v.len==kept);
        V pair=fpr_fn_probeRecordFold(tag(2),tag(3),tag(7),(V)&v);
        CHECK(*(V*)((char*)pair+8)==tag(sum));
        CHECK(*(V*)((char*)pair+8+sizeof(V))==(V)&v);
        cases++;
    }
    /* Canonical field order is lexical: z299 is physical column 222 among
       z0..z299. Distinct unread-field payloads catch a wrong field index as
       well as corrupted copies, across a wide directory and kind offset. */
    const int predicate_col=222;
    for(int c=0;c<300;c++) {
        kinds[c]=c==predicate_col?1:(c%4==0?0:c%4==1?1:c%4==2?3:7);
        col[c]=(Col){100,cells[c]};cols[c]=&col[c];
        for(int i=0;i<5;i++) cells[c][i]=c==predicate_col?i-2:opaque_cell(c,i);
    }
    Vec wide={9006,3,5,shape,variant,300,kinds,cols};
    CHECK(fpr_fn_probeLastFilter((V)&wide)==(V)&wide && wide.len==2);
    for(int c=0;c<300;c++) CHECK(cells[c][0]==(c==predicate_col?1:opaque_cell(c,3)) && cells[c][1]==(c==predicate_col?2:opaque_cell(c,4)));
    /* Reject bad descriptors before dereferencing the absent column table. */
    for(int c=0;c<9;c++) kinds[c]=1;
    Vec bad={9006,2,5,shape,variant,9,0,0};
    CHECK(fpr_fn_probeRecordFilter((V)&bad)==123);
    bad.rep=3;bad.tidEl=shape+1;
    CHECK(fpr_fn_probeRecordMap((V)&bad)==123);
    bad.tidEl=shape;bad.varEl=variant+1;
    CHECK(fpr_fn_probeRecordMap((V)&bad)==123);
    bad.varEl=variant;bad.ncols=8;
    CHECK(fpr_fn_probeRecordFilter((V)&bad)==123);
    bad.ncols=9;bad.kinds=kinds;kinds[8]=0;
    CHECK(fpr_fn_probeRecordFilter((V)&bad)==123);
    kinds[8]=1;
    CHECK(fpr_fn_probeRecordFold((V)&fpr_unit,tag(1),tag(0),(V)&bad)==123);
    CHECK(fpr_fn_probeRecordFold(tag(1),tag(1),(V)&fpr_unit,(V)&bad)==123);
    CHECK(fallbacks==7 && yields>1000 && cases==1500);
    say("TYPED_KERNEL_PASS 1500 record cases: simultaneous/captured map, 9/64/300-column filter, captured fold, empty, guards, hostile yields\n");
    return 0;
}
