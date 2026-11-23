-- Compiler.Compile.Cost -- resource-equation checking, --cost reporting,
-- and target manifest budget judgement for the native compile driver.
module Compiler.Compile.Cost (runCostAnalysis) where

import Compiler.CommandLine (CompileArguments (..))
import qualified Compiler.Native.Regions as Regions
import Control.Monad (unless, when)
import Core.Syntax (Core (..), Prog)
import qualified Cost
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import qualified Data.Set as S
import Frontend.Syntax (SExpr (..), STop (..))
import Manifest (Manifest (..), renderNs)
import qualified Precond
import qualified Resource.Analysis as Resource
import Safety (measureCheck)
import System.Exit (exitFailure)

runCostAnalysis
  :: CompileArguments
  -> Maybe Manifest
  -> [STop] -- ^ finalTops
  -> [STop] -- ^ tops (pre-precondition, for measureCheck)
  -> Precond.PreTable
  -> S.Set String -- ^ rootBinds
  -> ([String] -> [String]) -- ^ anchored
  -> Regions.Program -- ^ costInput = compileRaw finalTops
  -> Prog -- ^ costProg = fst (turnPassWith False costInput)
  -> IO ()
runCostAnalysis opts manifest finalTops tops preTab rootBinds anchored costInput costProg = do
  let (measTable, _) = measureCheck tops
      surface = Resource.surfaceNames finalTops
      coefs = maybe M.empty mCoefs manifest
      prims = maybe M.empty mPrims manifest
      analysis = Resource.analyze
        (if oCost opts || isJust manifest then M.keysSet costProg else S.empty)
        measTable coefs finalTops (Regions.programNative costInput) costProg
      declared = Resource.declarations analysis
      declErrs = Resource.declarationErrors analysis
      verifiedSizes = Resource.sizes analysis
      eqs = Resource.equations analysis
      rootNames = [n | n <- S.toList rootBinds, M.member n costProg]
      priceW g = fst <$> M.lookup g prims
      priceA g = snd <$> M.lookup g prims
      verdicts =
        [ (n, kind, derivedC', declC, verdict)
          | (n, d) <- M.toList declared,
            Just (Cost.CostEq w a l _, _) <- [M.lookup n eqs],
            (kind, derivedC, Just declC, price) <- [("work", w, Cost.dWork d, priceW), ("alloc", a, Cost.dAlloc d, priceA), ("live", l, Cost.dLive d, priceA)],
            let derivedC' = Cost.resolvePrims price derivedC
                verdict = case Cost.coefsIn declC of
                  [] -> Cost.checkBoundsUnderWith (nonnegativeInputs n) (renamerFor n) derivedC' declC
                  ks -> Cost.Unproved ["coefficient " ++ k ++ " (bind it in a manifest: --manifest=FILE)" | k <- ks]
        ]
      nonnegativeInputs n = S.fromList
        [ p | (p, Just (v, predicate)) <- zip
                (fst (M.findWithDefault ([], CErr "") n costProg))
                (M.findWithDefault [] n preTab),
              Precond.entails (Precond.conjuncts predicate) (SBin ">=" (SVar v) (SInt 0))
        ]
      renamerFor n =
        let ren = M.fromList (zip (fst (M.findWithDefault ([], CErr "") n costProg)) (M.findWithDefault [] n surface))
            r p = M.findWithDefault p p ren
            rn c = case c of
              Cost.CP p -> Cost.CP (r p)
              Cost.CLen p -> Cost.CLen (r p)
              Cost.CW p -> Cost.CW (r p)
              Cost.CA p -> Cost.CA (r p)
              _ -> c
         in rn
      failed = [v | v@(_, _, _, _, verdict) <- verdicts, verdict /= Cost.Proven]
      renderV (n, kind, d, c, v) =
        n ++ ": declared " ++ kind ++ " <= " ++ Cost.prettyIn surface costProg n c
          ++ "   derived " ++ Cost.prettyIn surface costProg n d ++ "   " ++ Cost.renderVerdict v

  when (oCost opts) $ do
    putStrLn "cost (work in abstract ops; alloc in requested cell bytes; live where it differs; ω = opaque):"
    mapM_ putStrLn (Cost.renderReport surface costProg (M.map fst eqs) (M.keysSet (M.filter (\d -> Cost.dLive d /= Nothing) declared)) rootNames)
    unless (null verdicts) $ do
      putStrLn "declared bounds:"
      mapM_ (putStrLn . ("  " ++) . renderV) verdicts
    let sizes = [(n, sz) | (n, d) <- M.toList declared, Just sz <- [Cost.dSize d]]
    unless (null sizes) $ do
      putStrLn "result size candidates (callers use independently verified bounds only):"
      mapM_ (\(n, sz) -> putStrLn ("  " ++ n ++ ": declared size <= " ++ Cost.prettyIn surface costProg n sz
        ++ case M.lookup n verifiedSizes of
          Nothing -> "   UNPROVED (no result-size lemma; annotation is not used)"
          Just actual -> "   verified size <= " ++ Cost.prettyIn surface costProg n actual ++ "   "
            ++ Cost.renderVerdict (Cost.checkBoundsUnderWith (nonnegativeInputs n) (renamerFor n) actual sz))) sizes

  let orDash x = if null x then "-" else x
  budgetFails <- case manifest of
    Nothing -> pure []
    Just m -> do
      putStrLn ("target " ++ mName m ++ ": compiler " ++ orDash (mCompiler m) ++ ", runtime " ++ orDash (mRuntime m) ++ ", " ++ orDash (mHardware m) ++ "; " ++ show (fromRational (mNsPerOp m) :: Double) ++ " ns/op")
      unless (null (mAssume m)) $ putStrLn ("assumptions: " ++ intercalate "; " (mAssume m))
      let judge n = case M.lookup n eqs of
            Nothing -> Nothing
            Just (Cost.CostEq w _ _ _, _) ->
              let w' = Cost.resolvePrims priceW w
                  shown = Cost.prettyIn surface costProg n w'
                  budget = M.lookup n (mBudgets m)
                  line = case (Cost.evalConst w', Cost.omegas w', budget) of
                    (Just ops, _, Just b) ->
                      let ns = fromIntegral ops * mNsPerOp m
                       in (ns <= b, "work " ++ show ops ++ " ops → " ++ renderNs ns ++ (if ns <= b then "   PROVEN within budget " else "   OVER budget ") ++ renderNs b)
                    (Just ops, _, Nothing) -> (True, "work " ++ show ops ++ " ops → " ++ renderNs (fromIntegral ops * mNsPerOp m))
                    (Nothing, [], Just b) -> (False, "work <= " ++ shown ++ "   UNPROVED against budget " ++ renderNs b ++ " (parametric: bound the parameters with preconditions)")
                    (Nothing, [], Nothing) -> (True, "work <= " ++ shown ++ "   (parametric; × " ++ show (fromRational (mNsPerOp m) :: Double) ++ " ns)")
                    (Nothing, os, Just b) -> (False, "work <= " ++ shown ++ "   UNPROVED against budget " ++ renderNs b ++ " (opaque: " ++ intercalate ", " os ++ ")")
                    (Nothing, os, Nothing) -> (True, "work <= " ++ shown ++ "   UNPROVED (opaque: " ++ intercalate ", " os ++ ")")
               in Just line
          width = maximum (8 : map length rootNames)
          rows = [(n, l) | n <- rootNames, Just l <- [judge n]]
      mapM_ (\(n, (_, l)) -> putStrLn ("  " ++ n ++ replicate (width - length n) ' ' ++ "  " ++ l)) rows
      let unknownBudgets = [f | f <- M.keys (mBudgets m), f `notElem` rootNames]
      unless (null unknownBudgets) $ putStrLn ("  (budgets for names not in this program: " ++ intercalate ", " unknownBudgets ++ ")")
      pure [n ++ ": " ++ l | (n, (ok, l)) <- rows, not ok]

  unless (null declErrs && null failed && null budgetFails) $ do
    putStrLn "=== COST: ERRORS ==="
    mapM_ (putStrLn . ("  * " ++)) (anchored declErrs)
    mapM_ (putStrLn . ("  * " ++) . renderV) failed
    mapM_ (putStrLn . ("  * " ++)) budgetFails
    exitFailure
