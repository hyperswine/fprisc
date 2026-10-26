module TypedFusion (checkFusion) where
import qualified Compiler.Native.Core as Native
import Frontend.Desugar.Typed (SourceSelection)
import Core.Typed.Pipeline
import Core.Typed.Close
import Core.Typed.Syntax
import Core.Typed.Fusion (renderNote)
import qualified Core.Typed.FusionSafety as Safety
import Core.Typed.Callback.Model (Target(..),Template(..))
import Core.Identity
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as E
import Codegen.Policy (m2Policy)
import Control.Monad (unless,forM_)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

right=either error id
check label ok=unless ok (error ("typed fusion: "++label))
checkFusion :: (String -> String -> S.Set String -> (SourceSelection,Native.NativeCore)) -> IO ()
checkFusion compile=do
  let int=TC "Int"
      expr node=Expr int (linShapeT [] int) Generated Nothing node
      parameter i=Binder (BinderId (Namespace "fusion-safety") i) ("p"++show i) (Forall [] [] int) (linShapeT [] int)
      p=parameter 0;q=parameter 1
      failure=expr (Fail "generated trap")
      match=expr (MatchTail (FunctionMatch "total") [expr (Var (Local (binderId p)))]
        [Alternative [Pattern int "x" (Bind q)] [] (expr (Var (Local (binderId q))))] failure)
      template body=let code=CodeFunction (CodeId "probe") ClosureCode [] [p] body
                    in Template [] [p] body (codeContract code) ClosureCode
      reason body=Safety.unsafeTarget (Safety.planSafety (M.singleton (CodeTarget (CodeId "probe")) (template body))) (CodeTarget (CodeId "probe"))
  check "generated traps are observable" (reason failure==Just Safety.Failure)
  check "unproved recursion cannot move divergence across failure"
    (case reason (expr (CodeCall (CodeId "probe") [] [expr (Var (Local (binderId p)))])) of
      Just (Safety.Recursive _)->True;_->False)
  check "checked match fallbacks are not executable traps" (reason match==Nothing)
  check "refutable let patterns can fail" (reason (expr (LetPattern (Pattern int "0" (IntegerPattern 0)) (expr (IntValue 1)) (expr (IntValue 2))))==Just Safety.Failure)
  let source=unlines
        ["plus x = x + 1.","twice x = x * 2.","positive x = x > 0.",
         "effect x = _ = print x; x.","crash x = 10 / x.",
         "adder k x = x + k.","scale k x = x * k.","mark k = _ = print k; k.",
         "maps v = a = Vec.map twice v; b = Vec.map plus a; b.",
         "filters v = Vec.filter positive (Vec.filter positive v).",
         "captured v k = offset x = x + k; scale x = x * k; Vec.map offset (Vec.map scale v).",
         "chain v = Vec.map plus (Vec.map twice (Vec.map plus v)).",
         "computed v = Vec.map plus (Vec.map (adder (2 + 1)) (Vec.map (scale (4 - 2)) v)).",
         "staged v = callback = adder (mark 3); Vec.map twice (Vec.map callback v).",
         "effects v = a = Vec.map effect v; Vec.map twice a.",
         "failure v = Vec.map plus (Vec.map crash v)."]
      names=S.fromList ["plus","twice","positive","effect","crash","adder","scale","mark","maps","filters","captured","chain","computed","staged","effects","failure"]
      (_,before)=compile "typed-fusion" source names
      (after,notes)=right (Native.fuseNativePrograms (M.singleton () (S.empty,before))) M.! ()
      old=closedDefinitions (Native.nativeClosed before)
      new=closedDefinitions (Native.nativeClosed after)
      added owner=M.difference (closedCode (new M.! owner)) (closedCode (old M.! owner))
      codeNames=S.fromList [n | owner<-M.elems new,CodeId n<-M.keys (closedCode owner)]
      p=M.restrictKeys (Native.nativeProgram after) (codeNames<>S.fromList ["plus","twice","positive","crash","adder","scale"])
      (ir,refused)=Lower.lowerProgram m2Policy M.empty p p M.empty M.empty
  check "complete closed graph verifies" (verifyClosedProgram (Native.nativeClosed after)==Right ())
  check ("map/filter/capture composites are created: "++show [(n,M.keys (added n)) | n<-["maps","filters","captured"]])
    (all ((==1) . M.size . added) ["maps","filters","captured"])
  check "effectful/failing maps do not fuse" (all (M.null . added) ["effects","failure"])
  check "stored effectful capture operands are not replayed" (M.null (added "staged"))
  check "long captured chains reach a fixed point" (all ((==2) . M.size . added) ["chain","computed"])
  check "original code homes survive" (and [M.keysSet (closedCode f) `S.isSubsetOf` M.keysSet (closedCode (new M.! n)) | (n,f)<-M.toList old])
  check "named effect refusal survives" (any (isInfixOf "is NOT fused: `effect` uses the primitive `print`" . renderNote) notes)
  check "division refusal survives" (any (isInfixOf "the primitive `/`" . renderNote) notes)
  check "composites lower independently" (null refused)
  forM_ ["maps","filters","captured","chain","computed"] $ \owner->forM_ (zip [0..] (M.elems (added owner))) $ \(index,code)->forM_ [-3..3] $ \n->do
    let CodeId label=codeId code
        count=length (codeCaptures code)
        args=replicate count (E.RInt 2)++[E.RInt n]
        expected=case owner of
          "maps"->E.RInt (2*n+1);"filters"->E.rvBool (n>0)
          "captured"->E.RInt (2*n+2)
          _->E.RInt (2*n+2+index)
    check ("independent composite answer "++owner) (E.ocResult (E.evalProgram ir label args)==Right expected)
  let (again,_)=right (Native.fuseNativePrograms (M.singleton () (S.empty,after))) M.! ()
  check "fusion reaches a fixed point" (Native.nativeProgram again==Native.nativeProgram after)
  putStrLn "Typed fusion: checked map/filter/captured composites, stable code homes, strict effect/division refusals, independent lane answers and fixed points passed"
