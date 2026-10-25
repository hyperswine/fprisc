import Infer
import Infer.Result
import Core.Identity
import Compiler.VectorLayout
import Frontend.Parser (program)
import Frontend.Desugar
import Frontend.Desugar.Checked
import qualified Core.Typed.Syntax as T
import Core.Typed.Verify
import Core.Typed.Close
import Ownership.Shape (LShape(..))
import Ownership.TypeShape (linShapeT)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad (unless)
import Control.Monad.State.Strict (evalState)
import Text.Megaparsec (parse,errorBundlePretty)

check label ok=unless ok (error label)
right=either error id
failed (Left _)=True
failed _=False
main=do
  source<-readFile "tests/typed_core/vector_layouts.fpr"
  let tops=right (either (Left . errorBundlePretty) Right (parse program "vector-layouts" source))
      result=inferTopsChecked (Namespace "layout-tests") aotProf M.empty M.empty tops
  check ("source checking: "++show (inferenceErrors result)) (null (inferenceErrors result))
  let plans=right (prepareChecked result)
      expected=S.fromList ["make","wrap","two","pair","from","convert","capture","capturePair","local","copies","shadow","localShadow","explicit","main"]
      contracts=inferenceLayoutContracts result
  check ("checked layout coverage: "++show (checkedDeclines plans)) (checkedNames plans==expected)
  check "independent requirements remain independent" (length (layoutBodyRequirements (contracts M.! "two"))==2)
  check "forwarded requirements remain attached to their owner" (layoutContractOwner (contracts M.! "wrap")==GlobalLayout "wrap")
  check "local requirements own a lexical identity" (any (\c->case layoutContractOwner c of LocalLayout _->True; _->False) (M.elems contracts))
  let ts=inferenceTops result
      initial=DEnv 0 (collectCons "unit" ts) (collectShapes ts) [] []
      lowered=evalState (compileTopChecked plans ts) initial
  check "layout-bearing source functions reach the closed product" (expected `S.isSubsetOf` M.keysSet (desugaredClosed lowered))
  check "all layout products verify" (all (not . failed . verifyClosed (desugaredTypeContext lowered)) (M.elems (desugaredClosed lowered)))
  let params name=map T.binderType (T.functionParameters (closedRoot (desugaredClosed lowered M.! name)))
  check "a global function's schema cannot change a same-named parameter" (params "shadow"==[TC "Int"])
  check "global layouts cannot change a nongeneric shadowing local" (params "localShadow"==[TC "Int"])
  check "layout arguments precede source arguments" (case params "two" of TLayout _:TLayout _:_->True; _->False)
  let code=concatMap (M.elems . closedCode) (M.elems (desugaredClosed lowered))
  check "layout evidence survives lexical capture" (any (any (\b->case T.binderType b of TLayout _->True; _->False) . T.codeCaptures) code)
  let int=TC "Int";float=TC "F64";string=TC "String"
      expr ty node=T.Expr ty (linShapeT [] ty) T.Generated Nothing node
      fn body=T.Function "bad-layout" [] body
      verify=verifyFunction (T.TypeContext [] M.empty) . fn
      layout ty spec=expr (TLayout ty) (T.LayoutLiteral spec)
      vector t=TAp (TC "Vector") t
  check "correct typed descriptor" (not (failed (verify (layout float "d"))))
  check "wrong descriptor refused" (failed (verify (layout float "i")))
  check "ordinary strings cannot masquerade as layout evidence" (failed (verify (expr (TLayout int) (T.StringValue ""))))
  check "layout literals require evidence type" (failed (verify (expr string (T.LayoutLiteral ""))))
  check "builder result is linked to evidence element type" (failed (verify (expr (vector float) (T.VectorBuild BuildEmpty (layout int "")))))
  let scheme=Forall [0] [] (TFn (TLayout (TV 0)) (TFn (TV 0) (vector (TV 0))))
      mismatched=expr (TFn (TLayout int) (TFn float (vector float))) (T.Var (T.Global "make" scheme))
  check "calling schema links hidden and public type arguments" (failed (verify mismatched))
  check "evidence cannot be a vector's source element" (canonicalLayout (TLayout int)==Nothing)
  check "record layout order is canonical" (validLayout (TRec (RExt "y" float (RExt "x" int RNil))) "id")
  putStrLn "Typed layouts: checked coverage, calling-schema relationships, lexical ownership/capture, wrong evidence refusals and canonical descriptors passed"
