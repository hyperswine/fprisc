module TypedNormalize (checkNormalization) where
import qualified Compiler.Native.Core as Native
import Frontend.Desugar.Typed (SourceSelection)
import Core.Typed.Pipeline
import qualified Core.Typed.Program as Program
import Core.Typed.Close
import Core.Typed.Normalize (normalizeClosed)
import Core.Typed.Walk
import Core.Typed.Verify (sameType)
import Type.Syntax (Type(..))
import qualified Core.Typed.Syntax as T
import qualified Codegen.Lower as Lower
import qualified Codegen.Eval as E
import Codegen.Policy (m2Policy)
import Core.Identity (BinderId)
import Control.Monad (unless,forM_)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

right=either error id
check label ok=unless ok (error ("typed normalization: "++label))

checkNormalization :: (String -> String -> S.Set String -> (SourceSelection,Native.NativeCore)) -> IO ()
checkNormalization compile=do
  let source=unlines
        ["simple n = a = 5; b = a; n + b.",
         "alias n = a = n; b = a; b + 1.",
         "sink n = a = n + 1; b = a + 2; c = b + 3; c.",
         "first n = if n == 0 then 1 / 0 else n.",
         "second n = if n == 0 then 4611686018427387903 + 1 else n + 1.",
         "order n = a = first n; b = second n; a + b.",
         "dead n = unused = 10 / n; n.",
         "caf = 10 / 0.","deadCaf n = unused = caf; n.",
         "cafOK = 14 / 2.","once n = a = cafOK; a + a + n.",
         "deadAlloc n = unused = (n,n); n.",
         "captured n = a = 3; f = fn x -> a + x; f n.",
         "matched n = a = 3; case a of 0 -> n | x -> x.",
         "poly n = ident x = x; alias = ident; (alias n,ident True).",
         "escaped n = alias = n; fn x -> alias + x.",
         "shadow n = old = n; hidden = 9; (old,hidden).",
         "Token 1 = Type Int.","linear n = a = Token n; alias = a; alias.",
         "vec input = alias = input; (n,next) = Vec.len alias; (n,next).",
         "mapped input = a = Vec.map (fn x -> x + 1) input; b = Vec.map (fn x -> x * 2) a; Vec.free b."]
      names=S.fromList ["simple","alias","sink","first","second","order","dead","caf","cafOK","deadCaf","once","deadAlloc","captured","matched","poly","escaped","shadow","linear","vec","mapped"]
      (_,before)=compile "typed-normalization" source names
      after=right (Native.normalizeNative S.empty before)
      old=Native.nativeProgram before;new=Native.nativeProgram after
      beforeClosed=Native.nativeClosed before;afterClosed=Native.nativeClosed after
      definitions=closedDefinitions afterClosed
      body name=T.functionBody (closedRoot (definitions M.! name))
      lets e=(case T.exprNode e of T.Let {}->1;_->0)
        +sum (getConst (mapChildrenM (Const . (:[]) . lets) e))
  check "complete graph is checked" (verifyClosedProgram afterClosed==Right ())
  check "literal and local aliases actually disappear" (lets (body "simple")==0 && lets (body "alias")==0)
  check "strict dead expressions remain" (lets (body "dead")>0 && lets (body "deadCaf")>0)
  check "vector producers retain the late fusion boundary"
    (let vectors e=S.fromList [T.binderId b | b<-allBinders e,TAp (TC "Vector") _<-[T.binderType b]]
         original=T.functionBody (closedRoot (closedDefinitions beforeClosed M.! "mapped"))
     in S.size (vectors original)>=2 && vectors (body "mapped")==vectors original)
  check "entry/code identities stay fixed" (M.keysSet old==M.keysSet new && Native.nativeJoins before==Native.nativeJoins after)
  check "existing interface identities and types remain"
    (and [let a=closedRoot f;b=closedRoot (definitions M.! n)
          in map T.binderId (T.functionParameters a)==map T.binderId (T.functionParameters b)
            && sameType (T.functionType a) (T.functionType b)
         | (n,f)<-M.toList (closedDefinitions beforeClosed)])
  check "normalization introduces no new term identities" (ids after `S.isSubsetOf` ids before)
  check "normalization is idempotent" (Native.nativeProgram (right (Native.normalizeNative S.empty after))==new)
  let cases=[(name,[E.RInt n]) | name<-["simple","alias","sink","order","dead","deadCaf","once","deadAlloc","captured","matched","poly","escaped","shadow","linear"],n<-[-3..3]]
      evaluate full name args=
        let p=M.withoutKeys full (S.fromList ["vec","mapped"])
            (ir,refused)=Lower.lowerProgram m2Policy M.empty p p M.empty M.empty
        in if null refused then E.evalProgram ir name args else error (show refused)
      observed result=(E.ocResult result,[event e | e<-E.ocEvents result,keep e])
      keep E.EvAllocate {}=True;keep E.EvTrap {}=True;keep E.EvSafepoint {}=True;keep _=False
      event (E.EvAllocate name tid variant fields)=show ("alloc",name,show (tid,variant,fields))
      event (E.EvTrap reason)=show ("trap",reason,"")
      event (E.EvSafepoint name)=show ("tick",name,"")
      event _=error "unselected event"
  forM_ cases $ \(name,args)->do
    let a=evaluate old name args;b=evaluate new name args
    check ("independent values/traps/effect order "++name) (observed a==observed b)
    check ("independent evaluator did not get stuck "++name) (case E.ocResult b of Left (E.Stuck _)->False;_->True)
  let planned=right (Native.planNativeVectorReads S.empty before)
      normalized=right (Native.normalizeNative S.empty planned)
  check "planned vector reads retain lexical handles" (verifyClosedProgram (Native.nativeClosed normalized)==Right ())
  -- A printable source alias may refer to a local that is later shadowed.
  -- Preserve it rather than exposing that identity to the compatibility
  -- printer under the shadowing spelling.
  let original=closedDefinitions beforeClosed M.! "shadow"
      bs=allBinders (T.functionBody (closedRoot original))
      renamed=case bs of
        [target,alias,hidden]->right (mapClosed (programTypesOf before)
          (\fn->Right fn {T.functionBody=renameBinderNames (M.fromList
            [(T.binderId target,"same"),(T.binderId alias,"kept"),(T.binderId hidden,"same")]) (T.functionBody fn)}) Right original)
        _->error ("shadow fixture has wrong binder structure: "++show bs)
      changed=fst (right (normalizeClosed (programTypesOf before) renamed))
  check "display-shadowing aliases remain printable and stable"
    (length (allBinders (T.functionBody (closedRoot changed)))==length bs)
  check "display-shadowing form is idempotent"
    (show (T.functionBody (closedRoot (fst (right (normalizeClosed (programTypesOf before) changed)))))
      ==show (T.functionBody (closedRoot changed)))
  putStrLn "Typed normalization: checked types/identities, aliases/let sinking, strict CAFs/traps/fuel/allocations, captures, staged matches, vector snapshots and display-shadowing refusals passed"
  where
    ids native=S.fromList [T.binderId b | d<-M.elems (Native.nativeDefinitions native),let f=Native.checkedFunction d,
      b<-T.functionParameters f++allBinders (T.functionBody f)]
    programTypesOf=Program.programTypes . closedInput . Native.nativeClosed
