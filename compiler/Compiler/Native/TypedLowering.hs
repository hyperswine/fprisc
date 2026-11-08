-- P2 typed lowering, slice 1 (docs/2026-11-08-P2-TYPED-LOWERING-SLICE-1.md):
-- the census of a unit's checked definitions, and the agreement check at the
-- erasure boundary. For every definition in slice 1's class (S1), lower its
-- erasure with Codegen.Lower and its typed body with Codegen.LowerTyped; the
-- two native functions must be equal. Nothing the typed lowering produces is
-- emitted.
module Compiler.Native.TypedLowering (Report (..), check, reportNote, stagesNote, Lowered (..), typedFunctions, firstDifference) where

import Codegen.IR (Fn (..), Block (..))
import Codegen.Lower (Prim)
import qualified Codegen.Lower as Lower
import qualified Codegen.LowerTyped as Typed
import Codegen.Policy (Policy)
import qualified Compiler.Native.Core as Native
import Compiler.Native.TypedCensus (census, censusNote, s1Functions)
import Compiler.DataLayout (Layouts (..), wideTup)
import Core.Typed.Pipeline (closedInput, closedLayouts)
import Core.Typed.Program (programTypes)
import Core.Typed.Syntax (TypeContext (..), Function (..))
import qualified Compiler.Native.Regions.Typed as RT
import qualified Core.Region.Syntax as R
import Core.Syntax (Core (..), Prog)
import Core.Alpha (canonical)
import qualified Data.Map.Strict as M
import qualified Data.Map.Lazy as ML
import qualified Data.Set as S
import Data.List (intercalate)

data Report = Report
  { reportCensus :: String,
    reportS1 :: Int,
    reportAgreed :: Int,
    reportRefused :: [(String, String)], -- typed refused what erasure lowered
    reportBothRefused :: Int,
    reportEraseRefused :: Int,
    reportDisagreements :: [String],
    -- the agreed functions: boundary erasure and typed native function
    reportAgreedFns :: M.Map String (([String], Core), Fn) }

-- `emitted`: the names the unit emits; `ext`: the imported arities the
-- emission uses.
check :: Policy -> M.Map String Int -> M.Map String Prim -> Native.NativeCore -> S.Set String -> Report
check policy ext hal native emitted =
  Report (censusNote (census known functions)) (S.size s1) (count isAgreed)
    [(n, r) | (n, Refused r) <- outcomes] (count isBoth) (count isErase) [d | (_, Disagree d) <- outcomes]
    (M.fromList [(n, (def, fn)) | (n, AgreedWith def fn) <- outcomes])
  where
    definitions = M.restrictKeys (Native.nativeDefinitions native) emitted
    (functions, prog, known, layout) = context ext native emitted
    s1 = s1Functions known functions
    closed = Native.nativeClosed native
    outcomes = [(n, outcome n) | n <- S.toAscList s1]
    count p = length [() | (_, o) <- outcomes, p o]
    isAgreed o = case o of AgreedWith _ _ -> True; _ -> False
    isBoth o = case o of BothRefused -> True; _ -> False
    isErase o = case o of EraseRefused -> True; _ -> False
    outcome n = case (erasedOf n, M.lookup n functions) of
      (Right (Just def), Just fn) ->
        case (Lower.lowerFn policy M.empty prog ext hal n def, Typed.lowerFn policy layout prog ext hal fn) of
          (Right a, Right b)
            | a == b -> AgreedWith def b
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

-- P2 typed lowering, slice 2: the typed native function of every S1
-- definition the unit emits. Emission uses each one in place of the erased
-- lowering's function when the two agree (Codegen.nativeSelect).
data Lowered = Lowered
  { loweredCensus :: String,
    loweredS1 :: Int,
    loweredFns :: M.Map String Fn,
    loweredRefused :: [(String, String)],
    -- the S1 functions region placement rewrote that were lowered from
    -- placement's typed result
    loweredPlaced :: S.Set String,
    -- the Core each typed function's plan stands for
    loweredCores :: M.Map String ([String], Core) }

-- `regions`: placement's typed result, `placed`: the definitions placement
-- rewrote. A placed S1 function whose typed region body is an ordinary
-- expression is lowered from that body.
typedFunctions :: Policy -> M.Map String Int -> M.Map String Prim -> Native.NativeCore -> Maybe RT.Program -> S.Set String -> S.Set String -> Lowered
typedFunctions policy ext hal native regions placed emitted =
  Lowered (censusNote (census known functions)) (S.size s1)
    (M.fromList [(n, fn) | (n, Right fn) <- results]) [(n, why) | (n, Left why) <- results]
    (S.fromList [n | (n, Right _) <- results, M.member n fromRegions])
    -- lazy: read only for the few functions whose typed and erased native
    -- functions differ (a plan that lowered also plans)
    (ML.fromList [(n, either (const ([], CErr "typed lowering: no plan")) id (Typed.planCore layout fn))
                 | (n, Right _) <- results, Just fn <- [input n]])
  where
    (functions, prog, known, layout) = context ext native emitted
    s1 = s1Functions known functions
    results = [(n, Typed.lowerFn policy layout prog ext hal fn) | n <- S.toAscList s1, Just fn <- [input n]]
    -- a placed function without an ordinary region body keeps its boundary
    -- body: emission then keeps the erased function (counted as placed)
    fromRegions = M.fromList
      [ (n, (R.functionSource f) {functionBody = body})
      | n <- S.toList placed, Just f <- [M.lookup n (maybe M.empty RT.programFunctions regions)], R.Ordinary body <- [R.functionBody f] ]
    input n = maybe (M.lookup n functions) Just (M.lookup n fromRegions)

-- the checked functions the unit emits, the boundary program with the
-- constructor stubs emission adds (Compile.erasedConstructorStubs), the
-- known names, and the constructor layout
context :: M.Map String Int -> Native.NativeCore -> S.Set String -> (M.Map String Function, Prog, String -> Bool, Typed.Layout)
context ext native emitted = (functions, prog, known, layout)
  where
    definitions = M.restrictKeys (Native.nativeDefinitions native) emitted
    functions = M.map Native.checkedFunction definitions
    source = Native.nativeProgram native
    stubs = M.fromList
      [ (name, if arity == 0 then ([], CMk tid var []) else (params, CMk tid var (map CVar params)))
      | (name, (tid, var, arity)) <- M.toList (constructorLayouts layouts), M.notMember name source,
        let params = ["x" ++ show i | i <- [1 .. arity]] ]
    prog = source `M.union` stubs
    known n = M.member n prog || M.member n ext
    closed = Native.nativeClosed native
    layouts = closedLayouts closed
    TypeContext _ constructors = programTypes (closedInput closed)
    -- erasure's constructor layout: the declared ones, then the wide tuples
    layout = Typed.Layout (\n -> maybe (wideTup n) Just (M.lookup n (constructorLayouts layouts))) (M.keys constructors) (shapeLayouts layouts)

data Outcome = AgreedWith ([String], Core) Fn | Refused String | BothRefused | EraseRefused | Disagree String

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

-- P2 typed lowering, slice 2 count (FPR_TYPED_LOWER_STAGES=1): for every
-- agreed S1 function, the first stage after the boundary whose body differs
-- from the boundary erasure up to binder names, and whether the native
-- function the emission lowered is the typed one (source parameter names
-- aside). `stages` are in pipeline order. A function the optimizer gives a
-- scalar worker (`$worker.scalar.NAME`) is counted apart: its emitted body
-- is a dispatch wrapper around the worker.
stagesNote :: Report -> [(String, M.Map String ([String], Core))] -> M.Map String Fn -> String
stagesNote r stages lowered =
  "# typed stages: s1=" ++ show (M.size agreed)
    ++ " unchanged=" ++ show (length [() | (_, Nothing) <- firsts])
    ++ concat [" " ++ label ++ "=" ++ show (length here) ++ absent ++ workers
              | (label, prog) <- stages,
                let here = [(n, a) | (n, Just (l, a)) <- firsts, l == label], not (null here),
                let na = length [() | (_, True) <- here],
                let absent = if na > 0 then "(absent " ++ show na ++ ")" else "",
                let nw = length [() | (n, False) <- here, M.member ("$worker.scalar." ++ n) prog],
                let workers = if nw > 0 then "(scalar_worker " ++ show nw ++ ")" else ""]
    ++ " final_same=" ++ show (count (== Just True)) ++ " final_differs=" ++ show (count (== Just False))
    ++ " final_absent=" ++ show (count (== Nothing))
    ++ concat [" changed_at_" ++ label ++ "=" ++ intercalate "," (take 4 ns)
              | (label, prog) <- stages,
                let ns = [n | (n, Just (l, _)) <- firsts, l == label, M.notMember ("$worker.scalar." ++ n) prog],
                not (null ns)]
    ++ concat [" differs=" ++ intercalate "," (take 6 ns) | let ns = [n | (n, Just False) <- finals], not (null ns)]
  where
    agreed = reportAgreedFns r
    -- Just (stage, absent there)
    firsts = [(n, firstChange (canonical def) n) | (n, (def, _)) <- M.toList agreed]
    firstChange def n = case [(label, M.notMember n prog) | (label, prog) <- stages, (canonical <$> M.lookup n prog) /= Just def] of
      x : _ -> Just x
      [] -> Nothing
    finals = [(n, (\f -> f {fnSourceParams = []} == fn {fnSourceParams = []}) <$> M.lookup n lowered) | (n, (_, fn)) <- M.toList agreed]
    count p = length [() | (_, f) <- finals, p f]
