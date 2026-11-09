-- Shared source-model resource analysis. CLI and editor consume the same
-- equations; size annotations enter only through independently verified facts.
module Resource.Analysis (Analysis(..), analyze, surfaceNames) where
import qualified Cost
import qualified Resource.ResultSize as ResultSize
import qualified Compiler.Native.Core as NativeCore
import qualified Core.Typed.Syntax as TCore
import Core.Syntax (Name, Prog)
import Frontend.Syntax
import Safety (Measure)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Analysis = Analysis
  { declarations :: M.Map Name Cost.Declared
  , declarationErrors :: [String]
  , sizes :: M.Map Name Cost.Cost
  , equations :: M.Map Name (Cost.CostEq, Cost.CostEq)
  } deriving Show

surfaceNames :: [STop] -> M.Map Name [Name]
surfaceNames tops = M.fromList
  [(n, [case p of PVar v -> v; PSig v _ -> v; _ -> "arg" ++ show i
       | (i,p) <- zip [1 :: Int ..] ps])
  | TBind n ps _ _ <- M.elems (M.fromListWith (\_ old -> old)
      [(n,t) | t@(TBind n _ _ _) <- tops])]

analyze :: S.Set Name -> M.Map Name Measure -> M.Map Name Integer
        -> [STop] -> NativeCore.NativeCore -> Prog -> Analysis
analyze requested measTable coefs finalTops native costProg =
  Analysis declared declErrs verifiedSizes eqs
  where
    surface = surfaceNames finalTops
    (declared0, declErrs) = Cost.declaredBounds (M.keysSet coefs) surface costProg finalTops
    -- the manifest binds the coefficients; without one a bound that
    -- uses them stays symbolic and cannot be judged
    declared = M.map (\d -> d {Cost.dWork = Cost.substCoefs coefs <$> Cost.dWork d, Cost.dAlloc = Cost.substCoefs coefs <$> Cost.dAlloc d, Cost.dLive = Cost.substCoefs coefs <$> Cost.dLive d, Cost.dSize = Cost.substCoefs coefs <$> Cost.dSize d}) declared0
    -- Implicit checks must verify every declared contract, including
    -- unused imports, but need no equations for unrelated functions.
    -- Reports and target judgements retain the whole-program view.
    contractRoots = M.keysSet (M.filter (\d -> Cost.dWork d /= Nothing || Cost.dAlloc d /= Nothing || Cost.dLive d /= Nothing) declared)
    sizeDefinitions = M.map NativeCore.checkedFunction
      (NativeCore.nativeDefinitions native)
    sizeCandidates = M.mapMaybeWithKey (\n d -> do
      bound <- Cost.dSize d
      fn <- M.lookup n sizeDefinitions
      (ps,_) <- M.lookup n costProg
      let qs = map TCore.binderName (TCore.functionParameters fn)
      if length ps /= length qs then Nothing else Just
        (Cost.substituteCost (M.fromList (zip ps (map Cost.CP qs)))
          (M.fromList (zip ps (map Cost.CLen qs))) bound)) declared
    sizeProofs = ResultSize.proveSizes measTable sizeCandidates native
    verifiedSizes = ResultSize.verifiedBounds sizeProofs
    eqs = Cost.costProgramForWithSizes verifiedSizes
      (S.union requested contractRoots)
      measTable declared costProg
