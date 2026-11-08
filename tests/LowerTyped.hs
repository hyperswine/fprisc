-- P2 typed lowering, slice 1: Codegen.LowerTyped gives the native function
-- Codegen.Lower gives for the erasure of the same checked function.
import Codegen.Policy
import Codegen (emitTypedProductProgramWithImports, Emission (..), TypedUse (..), NativeMode (..), NativeBackend (..), Granularity (..), Strict (..), Target (..), rv64, foreignEntries)
import Codegen.IR (Width (..))
import qualified Codegen.IR as I
import Codegen.Target.RV (RVHart (..))
import Codegen.Target.Common (noTune, publicSymbols)
import Core.Opt.ProductParameters (emptyProductParameters)
import qualified Data.Set as S
import qualified Codegen.Lower as Lower
import qualified Codegen.LowerTyped as Typed
import Core.Identity (BinderId (..), Namespace (..))
import Core.Syntax (Core (..))
import Core.Typed.Syntax
import Ownership.Shape (LShape (..))
import Type.Syntax (Type (..), Scheme (..))
import Control.Monad (unless)
import Data.Either (isLeft)
import qualified Data.Map.Strict as M

check :: String -> Bool -> IO ()
check label ok = unless ok (error label)

tInt, tBool :: Type
tInt = TC "Int"
tBool = TC "Bool"

ex :: Type -> Node -> Expr
ex t = Expr t LU Generated Nothing

binder :: Int -> String -> Type -> Binder
binder i n t = Binder (BinderId (Namespace "test") i) n (Forall [] [] t) LU

local :: Binder -> Expr
local b = ex (binderType b) (Var (Local (binderId b)))

global :: String -> Type -> Expr
global n t = ex t (Var (Global n (Forall [] [] t)))

call :: Type -> String -> [Expr] -> Expr
call result f args = foldl (\h a -> ex result (Apply h a)) (global f (TFn tInt result)) args

int :: Integer -> Expr
int = ex tInt . IntValue

app :: String -> [Core] -> Core
app f = foldl CApp (CVar f)

layout :: Typed.Layout
layout = Typed.Layout (`M.lookup` M.fromList [("True", (1, 1, 0)), ("False", (1, 0, 0))]) ["True", "False"]

-- lower the typed function and its erasure with the same context
lowerings :: Function -> Core -> (Either String String, Either String String)
lowerings fn erased =
  let name = functionName fn
      params = map binderName (functionParameters fn)
      prog = M.singleton name (params, erased)
      e = Lower.lowerFn m2Policy M.empty prog M.empty M.empty name (params, erased)
      t = Typed.lowerFn m2Policy layout prog M.empty M.empty fn
   in (show <$> e, show <$> t)

agrees :: Function -> Core -> Bool
agrees fn erased = case lowerings fn erased of
  (Right a, Right b) -> a == b
  _ -> False

main :: IO ()
main = do
  -- fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)
  let n = binder 0 "n" tInt
      fibBody = ex tInt (If (call tBool "<" [local n, int 2]) (local n)
        (call tInt "+" [call tInt "fib" [call tInt "-" [local n, int 1]], call tInt "fib" [call tInt "-" [local n, int 2]]]))
      fib = Function "fib" [n] fibBody
      fibErased = CIf (app "<" [CVar "n", CInt 2]) (CVar "n")
        (app "+" [app "fib" [app "-" [CVar "n", CInt 1]], app "fib" [app "-" [CVar "n", CInt 2]]])
  check "fib: typed and erased lowerings agree" (agrees fib fibErased)
  check "fib: a different erasure is told apart" (not (agrees fib (CIf (app "<" [CVar "n", CInt 3]) (CVar "n")
        (app "+" [app "fib" [app "-" [CVar "n", CInt 1]], app "fib" [app "-" [CVar "n", CInt 2]]]))))

  -- pick n = case n of 0 -> 1; m if m > 5 -> m; (fallback) 7, as a match tail
  let m = binder 1 "m" tInt
      pickBody = ex tInt (MatchTail CaseMatch [local n]
        [ Alternative [Pattern tInt "0" (IntegerPattern 0)] [] (int 1),
          Alternative [Pattern tInt "m" (Bind m)] [BoolGuard (call tBool ">" [local m, int 5])] (local m) ]
        (int 7))
      pick = Function "pick" [n] pickBody
      pickErased = CIf (app "==" [CVar "n", CInt 0]) (CInt 1)
        (CLet "m" (CVar "n") (CIf (app ">" [CVar "m", CInt 5]) (CVar "m") (CInt 7)))
  check "match tail: literal, guarded binder and fallback agree" (agrees pick pickErased)

  -- flag b = case b of True -> 1; False -> 0 (the last arm is covered: no test)
  let b = binder 2 "b" tBool
      flagBody = ex tInt (Match CaseMatch [local b]
        [ Alternative [Pattern tBool "True" (ConstructorPattern "True" [])] [] (int 1),
          Alternative [Pattern tBool "False" (ConstructorPattern "False" [])] [] (int 0) ])
      flag = Function "flag" [b] flagBody
      flagErased = CLet "s" (CVar "b") (CIf (CTagEq 1 1 (CVar "s")) (CInt 1) (CInt 0))
  check "Bool case with a covered last arm agrees" (agrees flag flagErased)

  -- outside the class: refused with a reason, never lowered differently
  let s = Function "s" [n] (ex tInt (StringValue "x"))
  check "a string literal is refused" (isLeft (snd (lowerings s (CStr "x"))))
  let wide = Function "w" [binder 3 "x" (TC "String")] (int 0)
  check "a signature outside Int and Bool is refused" (isLeft (snd (lowerings wide (CInt 0))))
  -- a call region (placement's typed result): the erased token binding
  let callerBody = ex tInt (CallRegion (call tInt "g" [local n]))
      caller = Function "caller" [n] callerBody
      callerErased = CLet "tok" (app "$callPend" [CInt 0]) (app "$callLeave" [CVar "tok", app "g" [CVar "n"]])
      regionProg = M.fromList [("caller", (["n"], callerErased)), ("g", (["n"], CVar "n"))]
      -- the hooks are HAL primitives in a compile (tgtHal), as here
      hal = foreignEntries rv64 {tgtHal = M.fromList [("$callPend", 1), ("$callLeave", 2)]}
      erasedCaller = Lower.lowerFn m2Policy M.empty regionProg M.empty hal "caller" (["n"], callerErased)
      typedCaller = Typed.lowerFn m2Policy layout regionProg M.empty hal caller
  check ("a call region agrees: " ++ show (erasedCaller, typedCaller))
    (case (erasedCaller, typedCaller) of (Right a, Right b) -> a {I.fnSourceParams = []} == b {I.fnSourceParams = []}; _ -> False)

  -- slice 2: emission takes the typed function where the erased lowering
  -- of the same function agrees, keeps the erased one where it does not
  let mode = NativeMode PerFunction StrictOff "typed-probe" (Just (DirectRV W64 HartTp)) False noTune False True False
      target = rv64 {tgtNative = Just mode}
      prog = M.singleton "pick" (["n"], pickErased)
      typedOf fn = either error id (Typed.lowerFn (tgtPolicy target) layout prog M.empty (foreignEntries target) fn)
      emitWith typed = emitTypedProductProgramWithImports typed S.empty emptyProductParameters S.empty M.empty target False True []
        M.empty (publicSymbols S.empty) S.empty prog
      good = emitWith (M.singleton "pick" (typedOf pick))
      plain = emitWith M.empty
      -- a typed function for a different body under the same name
      wrong = emitWith (M.singleton "pick" (typedOf (pick {functionBody = ex tInt (MatchTail CaseMatch [local n]
        [ Alternative [Pattern tInt "0" (IntegerPattern 0)] [] (int 1),
          Alternative [Pattern tInt "m" (Bind m)] [BoolGuard (call tBool ">" [local m, int 5])] (local m) ]
        (int 8))})))
  check "emission takes the agreeing typed function" (tuTyped (emTypedUse good) == ["pick"] && null (tuDisagree (emTypedUse good)))
  check "the typed function emits the same code" (emNative good == emNative plain)
  check "a differing typed function is a disagreement and the erased code stays"
    (map (\(f, _, _) -> f) (tuDisagree (emTypedUse wrong)) == ["pick"] && null (tuTyped (emTypedUse wrong)) && emNative wrong == emNative plain)
  putStrLn "LowerTyped: fib, a guarded match tail and a covered Bool case agree with the erased lowering; refusals hold; emission takes agreeing typed functions and reports a differing one"
