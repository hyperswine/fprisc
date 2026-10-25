{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- Final assembly for an already checked RV64 C adapter. No source types,
-- argument-bank counting, arity admission or placement decisions live here.
module Codegen.Target.RV.Export (renderAdapter) where
import Codegen.Export.Plan
import Codegen.Selected (Phys(..))

renderAdapter :: CheckedAdapter -> [String]
renderAdapter checked=
  [ "",
    "# export "++public++" -> "++entry++" ("++unwords (map show (signatureParams sig))++" -> "++show (signatureResult sig)++")",
    "    .section .text."++public++",\"ax\",@progbits",
    "    .balign 4", "    .globl "++public, public++":",
    "    addi sp, sp, -"++show bytes,
    "    sd ra, "++show saved++"(sp)"
  ]++concatMap argument (adapterArguments plan)
   ++["    call "++entry]++result (adapterResult plan)
   ++["    ld ra, "++show saved++"(sp)","    addi sp, sp, "++show bytes,"    ret"]
  where
    plan=adapterPlan checked
    CExportSymbol public=adapterPublic plan
    FprEntrySymbol entry=adapterEntry plan
    sig=adapterSignature plan
    AdapterFrame bytes saved=adapterFrame plan
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
    result c=case c of
      ReturnWord->[]
      UntagInt->["    srai a0, a0, 1"]
      UnboxBool->["    lw a0, 4(a0)"]
      ReturnF64->["    fmv.d.x fa0, a0"]
      ReturnF32->["    fmv.w.x fa0, a0"]
