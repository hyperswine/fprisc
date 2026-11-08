-- P2 typed lowering, slice 1 (docs/2026-11-08-P2-TYPED-LOWERING-SLICE-1.md):
-- the census of a unit's checked definitions, and the agreement check at the
-- erasure boundary. For every definition in slice 1's class (S1), lower its
-- erasure with Codegen.Lower and its typed body with Codegen.LowerTyped; the
-- two native functions must be equal. Nothing the typed lowering produces is
-- emitted.
module Compiler.Native.TypedLowering (Report (..), check, reportNote) where

import Codegen.IR (Fn (..), Block (..))
import Codegen.Lower (Prim)
import qualified Codegen.Lower as Lower
import qualified Codegen.LowerTyped as Typed
import Codegen.Policy (Policy)
import qualified Compiler.Native.Core as Native
import Compiler.Native.TypedCensus (census, censusNote, s1Functions)
import Compiler.DataLayout (Layouts (..))
import Core.Typed.Pipeline (closedInput, closedLayouts)
import Core.Typed.Program (programTypes)
import Core.Typed.Syntax (TypeContext (..))
import Core.Syntax (Core (..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (intercalate)

data Report = Report
  { reportCensus :: String,
    reportS1 :: Int,
    reportAgreed :: Int,
    reportRefused :: [(String, String)], -- typed refused what erasure lowered
    reportBothRefused :: Int,
    reportEraseRefused :: Int,
    reportDisagreements :: [String] }

-- `emitted`: the names the unit emits; `ext`: the imported arities the
-- emission uses.
check :: Policy -> M.Map String Int -> M.Map String Prim -> Native.NativeCore -> S.Set String -> Report
check policy ext hal native emitted =
  Report (censusNote (census known functions)) (S.size s1) (count isAgreed)
    [(n, r) | (n, Refused r) <- outcomes] (count isBoth) (count isErase) [d | (_, Disagree d) <- outcomes]
  where
    definitions = M.restrictKeys (Native.nativeDefinitions native) emitted
    functions = M.map Native.checkedFunction definitions
    -- the emission adds a stub for every constructor the program lacks
    -- (Compile.erasedConstructorStubs); the boundary program gets the same
    source = Native.nativeProgram native
    stubs = M.fromList
      [ (name, if arity == 0 then ([], CMk tid var []) else (params, CMk tid var (map CVar params)))
      | (name, (tid, var, arity)) <- M.toList (constructorLayouts layouts), M.notMember name source,
        let params = ["x" ++ show i | i <- [1 .. arity]] ]
    prog = source `M.union` stubs
    known n = M.member n prog || M.member n ext
    s1 = s1Functions known functions
    closed = Native.nativeClosed native
    layouts = closedLayouts closed
    TypeContext _ constructors = programTypes (closedInput closed)
    layout = Typed.Layout (`M.lookup` constructorLayouts layouts) (M.keys constructors)
    outcomes = [(n, outcome n) | n <- S.toAscList s1]
    count p = length [() | (_, o) <- outcomes, p o]
    isAgreed o = case o of Agreed -> True; _ -> False
    isBoth o = case o of BothRefused -> True; _ -> False
    isErase o = case o of EraseRefused -> True; _ -> False
    outcome n = case (erasedOf n, M.lookup n functions) of
      (Right (Just def), Just fn) ->
        case (Lower.lowerFn policy M.empty prog ext hal n def, Typed.lowerFn policy layout prog ext hal fn) of
          (Right a, Right b)
            | a == b -> Agreed
            | otherwise -> Disagree (n ++ ": " ++ firstDifference a b)
          (Left _, Left _) -> BothRefused
          (Right _, Left why) -> Refused why
          (Left why, Right _) -> Disagree (n ++ ": the typed lowering accepted what the erased lowering refused (" ++ why ++ ")")
      _ -> EraseRefused
    -- erase each owner alone, so one owner's refusal cannot hide the rest
    erasedOf n = do
      def <- maybe (Left "absent") Right (M.lookup n definitions)
      erased <- Native.eraseDefinitions closed [Native.checkedOwner def]
      pure (M.lookup n erased)

data Outcome = Agreed | Refused String | BothRefused | EraseRefused | Disagree String

firstDifference :: Fn -> Fn -> String
firstDifference a b
  | fnResult a /= fnResult b = "result type " ++ show (fnResult a) ++ " (erased) against " ++ show (fnResult b) ++ " (typed)"
  | fnEntry a /= fnEntry b = "entry block"
  | otherwise = case [(x, y) | (x, y) <- zip (fnBlocks a) (fnBlocks b), x /= y] of
      (x, y) : _ -> "first differing block: erased " ++ show x ++ " against typed " ++ show y
      [] -> "block count " ++ show (length (fnBlocks a)) ++ " (erased) against " ++ show (length (fnBlocks b)) ++ " (typed)"

reportNote :: Report -> String
reportNote r = "# typed lowering: s1=" ++ show (reportS1 r) ++ " agreed=" ++ show (reportAgreed r)
  ++ " refused=" ++ show (length (reportRefused r)) ++ " both_refused=" ++ show (reportBothRefused r)
  ++ " erase_refused=" ++ show (reportEraseRefused r)
  ++ concat [" refused_by=" ++ intercalate ";" (take 3 [n ++ ":" ++ why | (n, why) <- reportRefused r]) | not (null (reportRefused r))]
