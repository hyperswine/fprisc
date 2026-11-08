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
layout = Typed.Layout (`M.lookup` M.fromList [("True", (1, 1, 0)), ("False", (1, 0, 0))]) ["True", "False"] M.empty

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
  check "a lambda is refused" (isLeft (snd (lowerings (Function "l" [n] (ex (TFn tInt tInt) (Lambda [binder 10 "y" tInt] (int 0)))) (CLam ["y"] (CInt 0)))))
  -- slice 3g: applying a local is erasure's curried application, which Lower dispatches
  let fb = binder 12 "f" (TFn tInt tInt)
      xb = binder 13 "x" tInt
      apply = Function "ap" [fb, xb] (ex tInt (Apply (local fb) (local xb)))
  check "applying a local agrees (slice 3g)" (agrees apply (CApp (CVar "f") (CVar "x")))
  -- slice 3e: a string literal, and a string pattern (an equality test)
  let s = Function "s" [n] (ex (TC "String") (StringValue "x"))
  check "a string literal agrees (slice 3e)" (agrees s (CStr "x"))
  let w = binder 9 "w" (TC "String")
      isOk = Function "isOk" [w] (ex tInt (Match CaseMatch [local w]
        [ Alternative [Pattern (TC "String") "\"ok\"" (StringPattern "ok")] [] (int 1),
          Alternative [Pattern (TC "String") "_" Wildcard] [] (int 0) ]))
      isOkErased = CLet "s" (CVar "w") (CIf (app "==" [CVar "s", CStr "ok"]) (CInt 1) (CInt 0))
  check "a string pattern agrees (slice 3e)" (agrees isOk isOkErased)
  -- slice 3f: a list literal is erased to its Cons chain, a builder to its body
  let listT = TAp (TC "List") tInt
      lx = binder 11 "x" tInt
      lit = Function "lit" [lx] (ex listT (ListValue [local lx, int 1]))
      litErased = app "Cons" [CVar "x", app "Cons" [CInt 1, CVar "Nil"]]
      built = Function "lit" [lx] (ex listT (ListBuilder (binderId lx) (binderId lx) (ex listT (ListValue [local lx, int 1]))))
      listProg = M.fromList [("lit", (["x"], litErased)), ("Cons", (["h", "t"], CMk 3 1 [CVar "h", CVar "t"])), ("Nil", ([], CMk 3 0 []))]
      erasedLit = Lower.lowerFn m2Policy M.empty listProg M.empty M.empty "lit" (["x"], litErased)
      typedOfList fn = Typed.lowerFn m2Policy layout listProg M.empty M.empty fn
      sameFn x y = case (x, y) of (Right x', Right y') -> x' {I.fnSourceParams = []} == y' {I.fnSourceParams = []}; _ -> False
  check ("a list literal agrees (slice 3f): " ++ show (erasedLit, typedOfList lit)) (sameFn erasedLit (typedOfList lit))
  check "a list builder agrees with its body (slice 3f)" (sameFn erasedLit (typedOfList built))
  let poly = Function "w" [binder 3 "x" (TV 0)] (int 0)
  check "a polymorphic signature agrees (slice 3b)" (agrees poly (CInt 0))
  -- slice 3a: a monomorphic signature outside Int and Bool lowers the same
  let wide = Function "w" [binder 3 "x" (TC "String")] (int 0)
  check "a String parameter agrees" (agrees wide (CInt 0))
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

  -- slice 3c: a primitive is lowered by Codegen.Lower's own dispatch; a
  -- literal let is substituted at its use, as the optimizer does before the
  -- erased lowering. band x (k + 1), k = 1: Lower untags x before it
  -- evaluates the second argument
  let x = binder 4 "x" tInt
      k = binder 5 "k" tInt
      bitHal = foreignEntries rv64 {tgtHal = M.fromList [("band", 2)]}
      maskBody = ex tInt (Let k (int 1) (call tInt "band" [local x, call tInt "+" [local k, int 1]]))
      mask = Function "mask" [x] maskBody
      maskErased = app "band" [CVar "x", app "+" [CInt 1, CInt 1]]
      maskProg = M.singleton "mask" (["x"], maskErased)
      erasedMask = Lower.lowerFn m2Policy M.empty maskProg M.empty bitHal "mask" (["x"], maskErased)
      typedMask = Typed.lowerFn m2Policy layout maskProg M.empty bitHal mask
  check ("a delegated primitive with a substituted literal agrees: " ++ show (erasedMask, typedMask))
    (case (erasedMask, typedMask) of (Right a, Right b) -> a {I.fnSourceParams = []} == b {I.fnSourceParams = []}; _ -> False)

  -- slice 3d-i: a constructor pattern with fields, and a constructor value
  -- swap p = case p of Pair a b -> Pair b a  (Pair: tid 9, variant 0, arity 2)
  let pairT = TC "Pair"
      pv = binder 6 "p" pairT
      a = binder 7 "a" tInt
      b2 = binder 8 "b" tInt
      pairLayout = Typed.Layout (`M.lookup` M.fromList [("Pair", (9, 0, 2)), ("True", (1, 1, 0)), ("False", (1, 0, 0))]) ["Pair", "True", "False"] M.empty
      swapBody = ex pairT (Match CaseMatch [local pv]
        [Alternative [Pattern pairT "Pair a b" (ConstructorPattern "Pair" [Pattern tInt "a" (Bind a), Pattern tInt "b" (Bind b2)])] []
          (ex pairT (Construct "Pair" [local b2, local a]))])
      swap = Function "swap" [pv] swapBody
      -- erasure: scrutinee let, tag test, fields bound innermost-last
      swapErased = CLet "s" (CVar "p") (CIf (CTagEq 9 0 (CVar "s"))
        (CLet "a" (CProj 0 (CVar "s")) (CLet "b" (CProj 1 (CVar "s")) (CMk 9 0 [CVar "b", CVar "a"])))
        (CErr "case: no matching pattern; arms were [Pair a b]"))
      swapProg = M.singleton "swap" (["p"], swapErased)
      erasedSwap = Lower.lowerFn m2Policy M.empty swapProg M.empty M.empty "swap" (["p"], swapErased)
      typedSwap = Typed.lowerFn m2Policy pairLayout swapProg M.empty M.empty swap
  check ("a constructor match and value agree: " ++ show (erasedSwap, typedSwap))
    (case (erasedSwap, typedSwap) of (Right x', Right y') -> x' {I.fnSourceParams = []} == y' {I.fnSourceParams = []}; _ -> False)

  -- slice 2: emission takes the typed function where the erased lowering
  -- of the same function agrees, keeps the erased one where it does not
  let mode = NativeMode PerFunction StrictOff "typed-probe" (Just (DirectRV W64 HartTp)) False noTune False True False
      target = rv64 {tgtNative = Just mode}
      prog = M.singleton "pick" (["n"], pickErased)
      typedOf fn = (either error id (Typed.lowerFn (tgtPolicy target) layout prog M.empty (foreignEntries target) fn),
                    either error id (Typed.planCore layout fn))
      emitWith typed = emitTypedProductProgramWithImports typed S.empty prog emptyProductParameters S.empty M.empty target False True []
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
