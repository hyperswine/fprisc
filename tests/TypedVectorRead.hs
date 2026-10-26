module TypedVectorRead (checkVectorReads) where
import qualified Compiler.Native.Core as Native
import Frontend.Desugar.Typed (SourceSelection)
import Core.Typed.Pipeline
import Core.Typed.Close
import qualified Core.Typed.Syntax as T
import Core.Typed.Verify
import Core.Typed.Walk
import Core.Typed.VectorRead (planReads)
import Core.Typed.Erase
import Core.Identity
import qualified Core.VectorRead as Read
import Core.Syntax (Core(..))
import Inline (vecPeekCompatibility)
import Type.Syntax
import Ownership.TypeShape (linShapeT)
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as E
import Codegen.Policy (m2Policy)
import Control.Monad (unless,forM_)
import Control.Monad.State.Strict
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

right=either error id
check label ok=unless ok (error ("typed vector read: "++label))
failed (Left _)=True
failed _=False

checkVectorReads :: (String -> String -> S.Set String -> (SourceSelection,Native.NativeCore)) -> IO ()
checkVectorReads compile=do
  let source=unlines
        ["at i v = (x,next) = Vec.at i v; (x,next).",
         "get i v = (x,next) = Vec.get i v; (x,next).",
         "len v = (n,next) = Vec.len v; (n,next).",
         "whole i v = Vec.at i v.",
         "computed i make = (x,next) = Vec.get i (make i); (x,next).",
         "captured i v = (fn input -> (x,next) = Vec.at i input; (x,next)) v."]
      names=S.fromList ["at","get","len","whole","computed","captured"]
      (_,before)=compile "typed-vector-reads" source names
      after=right (Native.planNativeVectorReads S.empty before)
      defs=closedDefinitions (Native.nativeClosed after)
      count e=(case T.exprNode e of T.VectorReadPair {}->1;_->0)
        +sum (getConst (mapChildrenM (Const . (:[]) . count) e))
      counts n=let f=defs M.! n in count (T.functionBody (closedRoot f))
        +sum [count (T.codeBody c) | c<-M.elems (closedCode f)]
  check "checked complete closed product" (verifyClosedProgram (Native.nativeClosed after)==Right ())
  check "at/get/len and closed local code are planned" (all ((==1).counts) ["at","get","len","captured"])
  check "whole-pair uses and computed handles retain ordinary reads" (all ((==0).counts) ["whole","computed"])
  check "entries, joins and binder identities remain unchanged"
    (M.keysSet (Native.nativeProgram before)==M.keysSet (Native.nativeProgram after)
      && Native.nativeJoins before==Native.nativeJoins after
      && identities before==identities after)
  check "planning is idempotent" (Native.nativeProgram (right (Native.planNativeVectorReads S.empty after))==Native.nativeProgram after)
  let protected=M.keysSet (Native.nativeDefinitions after)
      raw=M.fromList [("checked",(["v"],CLet "p" (CApp (CVar "Vec.len") (CVar "v"))
        (CIf (CTagEq 4 0 (CVar "p")) (CProj 0 (CVar "p")) (CErr "bad"))))]
  check "erased compatibility pass cannot mutate checked owners"
    (vecPeekCompatibility (S.insert "checked" protected) raw==raw)
  -- A deliberately colliding display spelling tests physical handle reuse
  -- independently of the closure converter's usual alpha-renaming.
  let context=T.TypeContext ["Vector"] M.empty
      int=TC "Int";vec=TAp (TC "Vector") int;pair=TTupT [int,vec]
      expr ty node=T.Expr ty (linShapeT ["Vector"] ty) T.Generated Nothing node
      binder i name ty=T.Binder (BinderId (Namespace "peek-shadow") i) name (Forall [] [] ty) (linShapeT ["Vector"] ty)
      input=binder 0 "v" vec;value=binder 1 "v" int;next=binder 2 "next" vec
      ref b=expr (T.binderType b) (T.Var (T.Local (T.binderId b)))
      pat=T.Pattern pair "(v,next)" (T.TuplePattern
        [T.Pattern int "v" (T.Bind value),T.Pattern vec "next" (T.Bind next)])
      readRhs=expr pair (T.Apply
        (expr (TFn vec pair) (T.Apply
          (expr (TFn int (TFn vec pair)) (T.Var (T.Global "Vec.at" (Forall [] [] (TFn int (TFn vec pair))))))
          (expr int (T.IntValue 7)))) (ref input))
      body=expr pair (T.TupleValue [ref value,ref next])
      original=T.Function "shadow" [input] (expr pair (T.LetPattern pat readRhs body))
      planned=original {T.functionBody=planReads (T.functionBody original)}
      layout=Layout (\stem->do n<-get;put (n+1);pure (stem++show (n::Int)))
        (\name->if name=="Tup2" then Just (4,0,2) else Nothing) M.empty (\_ _ _->error "unexpected join")
      erase fn=right (evalState (eraseFunction context layout fn) 0)
      T.LetPattern _ marked _=T.exprNode (T.functionBody planned)
      bad node=planned {T.functionBody=expr pair node}
      replaced rhs=planned {T.functionBody=expr pair (T.LetPattern pat rhs body)}
  check "input and shadowing plan are checked" (all ((==Right ()).verifyFunction context) [original,planned])
  check "an unboxed physical result cannot escape its binding" (failed (verifyFunction context (bad (T.exprNode marked))))
  forM_ [expr pair (T.VectorReadPair Read.At [] (ref input)),
         expr pair (T.VectorReadPair Read.Length [] (expr int (T.IntValue 0))),
         expr pair (T.VectorReadPair Read.At [expr (TC "Bool") (T.BoolValue True)] (ref input)),
         expr (TTupT [TC "F64",vec]) (T.VectorReadPair Read.At [expr int (T.IntValue 7)] (ref input))] $ \rhs->
    check "malformed operation contracts refuse" (failed (verifyFunction context (replaced rhs)))
  let primitives=M.fromList
        [("Vec.at",(["i","v"],CMk 4 0 [CApp (CApp (CVar "+") (CVar "i")) (CVar "v"),CVar "v"])),
         ("$vec.at",(["i","v"],CApp (CApp (CVar "+") (CVar "i")) (CVar "v")))]
      evaluate fn=let p=M.insert "shadow" (erase fn) primitives
                      (ir,refused)=Lower.lowerProgram m2Policy M.empty p p M.empty M.empty
                  in if null refused then E.evalProgram ir "shadow" [E.RInt 100] else error (show refused)
      expected=Right (E.RObj 4 0 [E.RInt 107,E.RInt 100])
  check "shadowing reuses the old handle, independently evaluated"
    (all ((==expected).E.ocResult.evaluate) [original,planned])
  let allocations fn=length [() | E.EvAllocate {}<-E.ocEvents (evaluate fn)]
  check "exactly the read wrapper allocation disappears" (allocations original==allocations planned+1)
  putStrLn "Typed vector reads: scoped tuple plans, operation/type/ownership refusals, stable identities, closed code, idempotence and independently evaluated handle shadowing passed"
  where
    identities native=[T.binderId b | d<-M.elems (Native.nativeDefinitions native),
      let f=Native.checkedFunction d,b<-T.functionParameters f++allBinders (T.functionBody f)]
