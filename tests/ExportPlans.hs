module ExportPlans (checkExports) where
import qualified Representation as Representation
import qualified Representation.Types as Rep
import qualified Arc
import qualified Core.Syntax as Core
import Codegen.Export.Plan
import Codegen.Selected (Phys(..))
import qualified Compiler.Native.Exports as Exports
import Frontend.Syntax (STop(..),Ty(..))
import Control.Monad (unless,forM_)
import Data.List (isInfixOf,sortOn)
import qualified Data.Map.Strict as M

check label yes=unless yes (error ("export plans: "++label))
right=either error id
refused label needle value=case value of
  Left why->check (label++": wrong refusal "++why) (needle `isInfixOf` why)
  Right _->error ("export plans: accepted "++label)

checkExports :: IO ()
checkExports=do
  checkRepresentations
  let build abi params result=right (planAdapter abi (CExportSymbol "public") (FprEntrySymbol "fpr_fn_private") (Signature params result))
      mixed=[KF64,KInt,KF32,KBool,KWord,KUnit,KAddr,KF64]
      hard=adapterPlan (build HardFloat mixed KF32)
      ordered=sortOn argumentPosition (adapterArguments hard)
      wide=adapterPlan (build SoftFloat (take 64 (cycle [KInt,KBool,KUnit,KF32,KF64,KWord,KAddr])) KBool)
      args=adapterArguments hard
      editFirst f=case args of a:rest->hard {adapterArguments=f a:rest};_->error "empty hard fixture"
  check "lp64d has independently counted integer/FP input banks"
    (map argumentSource ordered==[FloatArgument 0,IntegerArgument 0,FloatArgument 1,IntegerArgument 1,
                                 IntegerArgument 2,IntegerArgument 3,IntegerArgument 4,FloatArgument 2])
  check "native positions preserve the full declared order"
    (map argumentDestination ordered==map (NativeRegister . Phys) ["a0","a1","a2","a3","a4","a5","a6","a7"])
  check "typed conversions distinguish Int/Bool/Unit and F32/F64"
    (map argumentConversion ordered==[F64Bits,TagInt,F32Bits,BoxBool,WordIdentity,BoxUnit,WordIdentity,F64Bits])
  let wideCells=[arg | arg<-adapterArguments wide,argumentPosition arg>=8]
  check "lp64 stack words go to all 56 hart cells, before register movement"
    (map argumentSource wideCells==map StackWord [0..55]
     && map argumentDestination wideCells==map NativeCell [0..55]
     && map argumentPosition (adapterArguments wide)==[8..63]++[7,6..0])
  forM_ [(SoftFloat,KInt,UntagInt),(HardFloat,KInt,UntagInt),(SoftFloat,KBool,UnboxBool),
         (HardFloat,KF64,ReturnF64),(HardFloat,KF32,ReturnF32),(SoftFloat,KF64,ReturnWord),
         (SoftFloat,KF32,ReturnWord),(HardFloat,KUnit,ReturnWord),(HardFloat,KAddr,ReturnWord)] $ \(abi,kind,want)->
    check "result conversion is an explicit typed operation" (adapterResult (adapterPlan (build abi [] kind))==want)
  refused "hard ABI limit" "more than 8 parameters" (planAdapter HardFloat (CExportSymbol "x") (FprEntrySymbol "f") (Signature (replicate 9 KWord) KWord))
  refused "soft ABI limit" "more than 64 parameters" (planAdapter SoftFloat (CExportSymbol "x") (FprEntrySymbol "f") (Signature (replicate 65 KWord) KWord))
  refused "missing parameter" "missing or duplicate" (checkAdapter hard {adapterArguments=drop 1 args})
  refused "duplicate parameter" "missing or duplicate" (checkAdapter hard {adapterArguments=args++take 1 args})
  refused "signature drift" "argument kind" (checkAdapter (editFirst (\a->a {argumentKind=KWord})))
  refused "C bank drift" "C location" (checkAdapter (editFirst (\a->a {argumentSource=IntegerArgument 0})))
  refused "native position drift" "native location" (checkAdapter (editFirst (\a->a {argumentDestination=NativeCell 0})))
  refused "conversion drift" "argument conversion" (checkAdapter (editFirst (\a->a {argumentConversion=WordIdentity})))
  refused "result drift" "result conversion" (checkAdapter hard {adapterResult=ReturnF64})
  refused "unaligned frame" "frame" (checkAdapter hard {adapterFrame=AdapterFrame 24 8})
  refused "return address outside frame" "frame" (checkAdapter hard {adapterFrame=AdapterFrame 16 16})
  refused "overflowing saved return offset" "frame" (checkAdapter hard {adapterFrame=AdapterFrame 16 (maxBound-7)})
  refused "frame immediate overflow" "frame" (checkAdapter hard {adapterFrame=AdapterFrame 2048 8})
  refused "incoming stack load immediate overflow" "stack word" (checkAdapter wide {adapterFrame=AdapterFrame 2032 8})
  refused "overwriting a C register before reading it" "overwritten C register" (checkAdapter hard {adapterArguments=ordered})
  let soft=adapterPlan (build SoftFloat [KInt,KBool,KWord] KWord)
  check "a safe alternative schedule is admitted by dataflow, not list equality"
    (case checkAdapter soft {adapterArguments=reverse (adapterArguments soft)} of Right _->True;_->False)
  let int=TCon "Int" [];decl=TSig "f@unit" ([int],int) []
      prepare req ds arities=Exports.prepareExports SoftFloat req ds arities (const "fpr_fn_checked")
      sourceFailure label needle answer=case answer of
        Left err->check label (Exports.exportSource err=="f" && needle `isInfixOf` Exports.exportMessage err)
        Right _->error ("accepted source export: "++label)
  sourceFailure "missing declaration has source ownership" "no declared signature" (prepare [("f","public")] [] M.empty)
  sourceFailure "ambiguous base name" "ambiguous" (prepare [("f","public")] [decl,TSig "f@other" ([int],int) []] M.empty)
  sourceFailure "missing native function" "no such function" (prepare [("f","public")] [decl] M.empty)
  sourceFailure "physical arity must match declared count" "signature has 1 parameters, the function 2" (prepare [("f","public")] [decl] (M.singleton "f@unit" 2))
  sourceFailure "managed types cannot cross this boundary" "not a C-representable type" (prepare [("f","public")] [TSig "f@unit" ([TCon "List" [int]],int) []] (M.singleton "f@unit" 1))
  sourceFailure "a function result is not an additional physical parameter" "not a C-representable type" (prepare [("f","public")] [TSig "f@unit" ([int],TArrT int int) []] (M.singleton "f@unit" 1))
  case prepare [("f","public")] [decl] (M.singleton "f@unit" 1) of
    Right [entry]->do
      check "resolved checked native target retained" (adapterEntry (adapterPlan (Exports.exportAdapter entry))==FprEntrySymbol "fpr_fn_checked")
      check "existing export diagnostic retained" (Exports.exportDescription entry=="export public : KInt -> KInt  (f@unit)")
    _->error "valid source export was refused"
  putStrLn "C export plans: checked signatures, independent C banks, wide hart cells, conversions, scheduling, frame bounds and source refusals passed"

-- Concrete checked interfaces constrain ARC before it defaults unknowns to
-- managed. This protects raw values that are used only by identity functions.
checkRepresentations :: IO ()
checkRepresentations=do
  let body=M.singleton "identity" (["x"],Core.CVar "x")
      sig kind=M.singleton "identity" (Rep.CallSignature [Just (Rep.ScalarRep kind)] (Just (Rep.ScalarRep kind)))
  forM_ [Rep.RawWord,Rep.RawAddr,Rep.RawF64,Rep.RawF32] $ \kind->do
    let (_,annotations,parameters)=right (Representation.representWith (sig kind) body)
        lowered=right (Arc.lowerArcWith (sig kind) M.empty body)
    check "checked scalar representation survives an otherwise unconstrained identity"
      (M.lookup "identity" parameters==Just [kind] && all (==kind) (M.elems annotations))
    check "raw scalar ownership never retains or releases the value"
      (not ("$arc.retain" `isInfixOf` show lowered) && not ("$arc.release" `isInfixOf` show lowered))
  let (_,_,unknown)=right (Representation.representWith
        (M.singleton "identity" (Rep.CallSignature [Nothing] Nothing)) body)
  check "unknown checked types remain constrained by uses, with the established managed default"
    (M.lookup "identity" unknown==Just [Rep.Managed])
  refused "a stale representation declaration" "has no function"
    (Representation.representWith (M.singleton "missing" (Rep.CallSignature [] Nothing)) body)
  refused "physical representation arity drift" "changed physical arity"
    (Representation.representWith (M.singleton "identity" (Rep.CallSignature [] Nothing)) body)
  let arithmetic=M.singleton "identity" (["x"],Core.CApp (Core.CApp (Core.CVar "+") (Core.CVar "x")) (Core.CInt 1))
  refused "checked evidence cannot contradict the body" "incompatible representations"
    (Representation.representWith (sig Rep.RawAddr) arithmetic)
  check "runtime constructor field-kind ABI is unchanged"
    (map Rep.kindTag [Rep.Managed,Rep.RawWord,Rep.RawAddr,Rep.RawF64,Rep.RawF32]=="twadf")
