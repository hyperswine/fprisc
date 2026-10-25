import Infer
import Infer.Result
import Compiler.Trap
import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Verify
import Core.Typed.Close
import qualified Codegen.Lower as Lower
import Codegen.Policy (m2Policy)
import qualified Codegen.Eval as Eval
import Frontend.Parser (program)
import Frontend.Desugar
import Frontend.Desugar.Checked
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad (unless)
import Control.Monad.State.Strict (evalState)
import Text.Megaparsec (parse,errorBundlePretty)

check label ok=unless ok (error label)
right=either error id
failed (Left _)=True
failed _=False
source=unlines
  [ "Broken = Type (Bad Int ??)."
  , "Ordinary a = Type (Good a)."
  , "scalar n = n + ??."
  , "delayed : Int -> Int -> Int."
  , "delayed = ??."
  , "once n = delayed n."
  , "partial n = Bad n."
  , "complete n = Bad n True."
  , "ordinary n = Good n."
  , "shadow n = error message = n; ?? + 1."
  ]
inferSource src=let tops=right (either (Left . errorBundlePretty) Right (parse program "traps" src))
                in inferTopsChecked (Namespace "trap-tests") aotProf M.empty M.empty tops
main=do
  let result=inferSource source
  check ("source checking: "++show (inferenceErrors result)) (null (inferenceErrors result))
  check "constructor trap provenance distinguishes a normal polymorphic field"
    (inferenceConstructorTraps result==M.singleton "Bad" 2)
  let plans=right (prepareChecked result)
      names=S.fromList ["scalar","delayed","once","partial","complete","ordinary","shadow"]
  check ("typed trap coverage: "++show (checkedDeclines plans)) (checkedNames plans==names)
  let tops=inferenceTops result
      initial=DEnv 0 (collectCons "unit" tops) (collectShapes tops) [] []
      lowered=evalState (compileTopChecked plans tops) initial
      closed=desugaredClosed lowered
      prog=desugaredCore lowered
      -- Include the closure code emitted by the checked handoff.
      full=evalState (lowerToUntyped plans tops >>= liftFix) initial
      (ir,_)=Lower.lowerProgram m2Policy M.empty full full M.empty M.empty
      answer name args=Eval.ocResult (Eval.evalProgram ir name args)
      int=TC "Int";bool=TC "Bool"
      arrow=TFn int (TFn bool int)
  check "each source trap has a checked closed product" (names `S.isSubsetOf` M.keysSet closed)
  check "closed products verify" (all (not . failed . verifyClosed (desugaredTypeContext lowered)) (M.elems closed))
  check "anonymous function holes wait for exactly one argument"
    (trapArguments (anonymousTrap arrow)==[int] && trapResult (anonymousTrap arrow)==TFn bool int)
  check "scalar holes fail immediately" (null (trapArguments (anonymousTrap int)))
  let constructor=right (constructorTrap "Bad" 2 arrow)
  check "constructor delay follows declared fields"
    (trapArguments constructor==[int,bool] && trapResult constructor==int)
  check "wrong constructor arity refused" (failed (constructorTrap "Bad" 3 arrow))
  check "nullary constructor trap refused" (failed (constructorTrap "Bad" 0 int))
  check "scalar trap evaluator" (answer "scalar" [Eval.RInt 3]==Left (Eval.Trap (trapMessage AnonymousHole)))
  check "a curried expression hole traps after its first argument"
    (answer "once" [Eval.RInt 3]==Left (Eval.Trap (trapMessage AnonymousHole)))
  check "a partially applied constructor stays a value" (case answer "partial" [Eval.RInt 3] of Right (Eval.RPap _ _)->True; _->False)
  check "a saturated constructor traps"
    (answer "complete" [Eval.RInt 3]==Left (Eval.Trap (trapMessage (ConstructorHole "Bad"))))
  check "an ordinary polymorphic constructor does not trap" (case answer "ordinary" [Eval.RInt 3] of Right (Eval.RObj _ _ [Eval.RInt 3])->True; _->False)
  check "source error shadowing cannot redirect a generated trap"
    (answer "shadow" [Eval.RInt 3]==Left (Eval.Trap (trapMessage AnonymousHole)))
  let named=inferSource "pending : Int. pending = ?todo."
  check "named holes retain their checked name and type for refusal"
    (null (inferenceErrors named) && inferenceHoles named==[("todo","Int")])
  check "typed erasure contains the source entries" (names `S.isSubsetOf` M.keysSet prog)
  putStrLn "Typed traps: provenance, checked coverage, exact delays, partial constructors, intrinsic failures and malformed contracts passed"
