#include "fpr.h"
extern V fpr_fn_calc(V,V,V);
extern V fpr_fn_pairSum(V,V);
extern V fpr_fn_calcRef(V,V,V);
extern V fpr_fn_boolEq(V,V,V);
static V boolean(V unit) {
    (void)unit;
    static const uint64_t foreign_true = ((uint64_t)1<<32)|1;
    return fpr_fn_boolEq(TAG(5),(V)&foreign_true,(V)&fpr_true);
}
static V badInt(V unit) {
    (void)unit;
    V result = fpr_fn_calc(TAG(0),(V)&fpr_unit,TAG(1));
    return BOOL(result == fpr_fn_calcRef(TAG(0),(V)&fpr_unit,TAG(1)));
}
static V badPair(V unit) {
    (void)unit;
    return fpr_fn_pairSum(TAG(0),TAG(9));
}
static V arithmetic(V unit) {
    (void)unit;
    const intptr_t xs[] = {0,1,-1,7,-7,2147483647,-2147483648,
                          1099511627776,-1099511627776,
                          4611686018427387903LL,-4611686018427387903LL-1};
    unsigned count = 0;
    for (unsigned i=0;i<sizeof(xs)/sizeof(xs[0]);i++)
      for (unsigned j=0;j<sizeof(xs)/sizeof(xs[0]);j++)
        for (int op=0;op<4;op++) {
            if (op==3 && xs[j]==0) continue;
            __int128 a=xs[i], b=xs[j];
            __int128 want=op==0?a+b:op==1?a-b:op==2?a*b:a/b;
            if (want < -((__int128)1<<62) || want >= ((__int128)1<<62)) continue;
            if (fpr_fn_calc(TAG(op),TAG(xs[i]),TAG(xs[j])) != TAG((intptr_t)want))
                return BOOL(0);
            count++;
        }
    return BOOL(count>300);
}
FPR_FN(fpr_g_WorkerProbe_x2ebadInt,badInt,1);
FPR_FN(fpr_g_WorkerProbe_x2ebadPair,badPair,1);
FPR_FN(fpr_g_WorkerProbe_x2earithmetic,arithmetic,1);
FPR_FN(fpr_g_WorkerProbe_x2eboolean,boolean,1);
