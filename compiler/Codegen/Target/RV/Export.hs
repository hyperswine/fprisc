{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Final assembly for an already checked RV64 C adapter. No source types,
-- argument-bank counting, arity admission or placement decisions live here.
module Codegen.Target.RV.Export (renderAdapter, adapterStack, adapterHeap) where
import Codegen.Export.Plan
import Codegen.Selected (Phys(..),CodeSymbol(..))
import qualified Codegen.Stack as Stack
import qualified Codegen.Heap as Heap

-- The checked plan owns both rendering and stack accounting. Conversions
-- calling the ARC runtime remain unknown; a frame size alone is not a bound.
adapterStack :: CheckedAdapter -> Stack.Frame
adapterStack checked = Stack.Frame (CodeSymbol public) bytes
  [Stack.Edge (CodeSymbol entry) bytes] unknown
  where
    plan=adapterPlan checked
    CExportSymbol public=adapterPublic plan
    FprEntrySymbol entry=adapterEntry plan
    bytes=toInteger (frameBytes (adapterFrame plan))
    unknown=concatMap (argumentCalls . argumentConversion) (adapterArguments plan)
      ++ resultCalls (adapterResult plan)
    argumentCalls conversion=case conversion of
      WordIdentity->[];TagInt->[];BoxBool->[];BoxUnit->[];F64Bits->[];F32Bits->[]
      BoxRaw kind->["runtime:"++uniformHelper "Box" kind]
    resultCalls conversion=case conversion of
      ReturnWord->[];UntagInt->[];UnboxBool->[];ReturnF64->[];ReturnF32->[]
      UnboxRaw kind rest->("runtime:"++uniformHelper "Unbox" kind):resultCalls rest

-- Conversion allocations belong to the public entry, including argument
-- boxes that the implementation later consumes. Output unboxing allocates none.
adapterHeap :: CheckedAdapter -> Heap.Equation
adapterHeap checked = Heap.Equation (Heap.Entry (CodeSymbol public)) demand
  [Heap.Entry (CodeSymbol entry)] [] []
  where
    plan=adapterPlan checked
    CExportSymbol public=adapterPublic plan
    FprEntrySymbol entry=adapterEntry plan
    demand=foldr Heap.plus (result (adapterResult plan))
      (map (argument . argumentConversion) (adapterArguments plan))
    argument conversion=case conversion of
      WordIdentity->Heap.zero;TagInt->Heap.zero;BoxBool->Heap.zero;BoxUnit->Heap.zero
      F64Bits->Heap.zero;F32Bits->Heap.zero;BoxRaw _->Heap.Demand 1 24
    result conversion=case conversion of
      ReturnWord->Heap.zero;UntagInt->Heap.zero;UnboxBool->Heap.zero
      ReturnF64->Heap.zero;ReturnF32->Heap.zero;UnboxRaw _ rest->result rest

uniformHelper :: String -> CKind -> String
uniformHelper direction kind="fpr_fn__x24arc_x2euniform"++direction++case kind of
  KWord->"Word";KAddr->"Addr";KF64->"F64";KF32->"F32"
  _->error "checked RV64 export: non-raw uniform conversion"

renderAdapter :: CheckedAdapter -> [String]
renderAdapter checked=
  [ "",
    "# export "++public++" -> "++entry++" ("++unwords (map show (signatureParams sig))++" -> "++show (signatureResult sig)++")",
    "    .section .text."++public++",\"ax\",@progbits",
    "    .balign 4", "    .globl "++public, public++":",
    "    addi sp, sp, -"++show bytes,
    "    sd ra, "++show saved++"(sp)"
  ]++(if adapterUniform plan then uniformArguments else concatMap argument (adapterArguments plan))
   ++["    call "++entry]++result (adapterResult plan)
   ++["    ld ra, "++show saved++"(sp)","    addi sp, sp, "++show bytes,"    ret"]
  where
    plan=adapterPlan checked
    CExportSymbol public=adapterPublic plan
    FprEntrySymbol entry=adapterEntry plan
    sig=adapterSignature plan
    AdapterFrame bytes saved=adapterFrame plan
    args=adapterArguments plan
    slot arg=16+8*argumentPosition arg
    -- Every C argument is saved before any allocating conversion can clobber
    -- either input bank. Every converted argument is then saved before the
    -- native register/hart-cell transfer, which runs without intervening calls.
    uniformArguments=concatMap stage args++concatMap box args++concatMap transfer args
    stage arg=(case argumentSource arg of
        FloatArgument n->["    "++(if argumentKind arg==KF32 then "fmv.x.w " else "fmv.x.d ")++"t0, fa"++show n]
        src->sourceWord "t0" src)
      ++["    sd t0, "++show (slot arg)++"(sp)"]
    box arg=["    ld a0, "++show (slot arg)++"(sp)"]
      ++convert "a0" (argumentConversion arg)
      ++["    sd a0, "++show (slot arg)++"(sp)"]
    transfer arg=case argumentDestination arg of
      NativeRegister (Phys dst)->["    ld "++dst++", "++show (slot arg)++"(sp)"]
      NativeCell j->["    ld t0, "++show (slot arg)++"(sp)","    sd t0, "++show (8*(1+j))++"(tp)"]
    argument arg=case argumentDestination arg of
      NativeCell j->sourceWord "t1" (argumentSource arg)++convert "t1" (argumentConversion arg)
        ++["    sd t1, "++show (8*(1+j))++"(tp)"]
      NativeRegister (Phys dst)->case argumentSource arg of
        FloatArgument n->["    "++floatBits (argumentConversion arg)++dst++", fa"++show n]
        src->sourceWord dst src++convert dst (argumentConversion arg)
    sourceWord dst source=case source of
      IntegerArgument n->["    mv "++dst++", a"++show n | dst/="a"++show n]
      StackWord n->["    ld "++dst++", "++show (bytes+8*n)++"(sp)"]
      FloatArgument _->error "checked RV64 export: floating source for a word load"
    floatBits F64Bits="fmv.x.d "
    floatBits F32Bits="fmv.x.w "
    floatBits _=error "checked RV64 export: non-float conversion for a floating source"
    convert reg c=case c of
      WordIdentity->[]
      TagInt->["    slli "++reg++", "++reg++", 1","    ori "++reg++", "++reg++", 1"]
      BoxBool->["    beqz "++reg++", 1f","    la "++reg++", fpr_true","    j 2f",
                "1:  la "++reg++", fpr_false","2:"]
      BoxUnit->["    la "++reg++", fpr_unit"]
      F64Bits->error "checked RV64 export: floating conversion for a word source"
      F32Bits->error "checked RV64 export: floating conversion for a word source"
      BoxRaw kind | reg=="a0"->["    call "++uniformHelper "Box" kind]
                  | otherwise->error "checked RV64 export: uniform argument was not staged"
    result c=case c of
      ReturnWord->[]
      UntagInt->["    srai a0, a0, 1"]
      UnboxBool->["    lw a0, 4(a0)"]
      ReturnF64->["    fmv.d.x fa0, a0"]
      ReturnF32->["    fmv.w.x fa0, a0"]
      UnboxRaw kind rest->["    call "++uniformHelper "Unbox" kind]++result rest
