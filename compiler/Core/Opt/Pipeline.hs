-- Ordered Core transformations and their ABI metadata. A result can only be
-- obtained through the checked driver; consumers cannot pair a program with
-- signatures from another stage. This is a structural check, not Core typing.
module Core.Opt.Pipeline
  (OptimizationOptions(..), CorePass(..), PassReport(..), OptimizedCore,
   optimizeCore,optimizeCoreWithImports, optimizedProgram, optimizedSignatures, optimizationNotes,
   optimizationReports, verifyPassResult) where
import Core.Syntax
import Core.Opt.Fusion (fuseVecFixWithImports)
import Core.Opt.Normalize (normIn)
import Workers (ScalarSignatures, workerizeWithSignatures, internalWorker)
import Reuse (reuseProgram)
import Control.Monad (foldM, unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data OptimizationOptions = OptimizationOptions
  { optFusion :: Bool, optWorkers :: Bool, optFieldWorkers :: Bool,
    optScalarWorkers :: Bool, optNormalize :: Bool, optReuse :: Bool }
  deriving (Eq, Show)

data CorePass = FuseVectors | MakeWorkers | NormalizeForReuse | ReuseConstructors
  deriving (Eq, Show)

data PassReport = PassReport
  { passName :: CorePass, passEnabled :: Bool, passNotes :: [String] }
  deriving (Eq, Show)

-- Use ordinary accessors rather than exported record fields: record updates
-- would otherwise let clients combine a program with unrelated signatures.
data OptimizedCore = OptimizedCore Prog ScalarSignatures [PassReport]

optimizedProgram :: OptimizedCore -> Prog
optimizedProgram (OptimizedCore p _ _) = p

optimizedSignatures :: OptimizedCore -> ScalarSignatures
optimizedSignatures (OptimizedCore _ sigs _) = sigs

optimizationReports :: OptimizedCore -> [PassReport]
optimizationReports (OptimizedCore _ _ reports) = reports

optimizationNotes :: OptimizedCore -> [String]
optimizationNotes = concatMap passNotes . optimizationReports

optimizeCore :: OptimizationOptions -> S.Set Name -> Prog -> Either String OptimizedCore
optimizeCore=optimizeCoreWithImports M.empty
optimizeCoreWithImports :: Prog -> OptimizationOptions -> S.Set Name -> Prog -> Either String OptimizedCore
optimizeCoreWithImports imports opts elide input = do
  verifyPassResult input input M.empty
  foldM run (OptimizedCore input M.empty [])
    [FuseVectors, MakeWorkers, NormalizeForReuse, ReuseConstructors]
  where
    run state pass = do
      let before = optimizedProgram state
          (after,sigs,notes,enabled) = case pass of
            FuseVectors -> let (p,ns) = if optFusion opts then fuseVecFixWithImports imports before else (before,[])
                           in (p,optimizedSignatures state,ns,optFusion opts)
            MakeWorkers -> let fields = optWorkers opts && optFieldWorkers opts
                               scalars = optWorkers opts && optScalarWorkers opts
                               (p,ns,ss) = workerizeWithSignatures fields scalars before
                           in (p,ss,ns,fields || scalars)
            NormalizeForReuse ->
              let enabled = optReuse opts && optNormalize opts
                  p = if enabled then M.map (\(ps,b)->(ps,normIn (S.fromList ps) b)) before else before
              in (p,optimizedSignatures state,[],enabled)
            ReuseConstructors -> let (p,ns) = if optReuse opts then reuseProgram elide before else (before,[])
                                 in (p,optimizedSignatures state,ns,optReuse opts)
      case verifyPassResult before after sigs of
        Left err -> Left (show pass ++ ": " ++ err)
        Right () -> Right (OptimizedCore after sigs
          (optimizationReports state ++ [PassReport pass enabled notes]))

-- Passes may add private functions, but must retain existing entry arities.
-- Workers record representations at creation time: check their names and
-- parameter counts instead of guessing those representations after rewriting.
verifyPassResult :: Prog -> Prog -> ScalarSignatures -> Either String ()
verifyPassResult before after sigs = do
  mapM_ retained (M.toList before)
  mapM_ parameters (M.toList after)
  mapM_ worker (M.toList sigs)
  where
    retained (n,(ps,_)) = case M.lookup n after of
      Nothing -> Left ("removed function " ++ n)
      Just (qs,_) -> unless (length ps == length qs) (Left ("changed entry arity of " ++ n))
    parameters (n,(ps,_)) = unless (length ps == S.size (S.fromList ps))
      (Left ("duplicate parameters in " ++ n))
    worker (n,(ks,_)) = do
      unless (internalWorker n) (Left ("scalar signature on non-worker " ++ n))
      case M.lookup n after of
        Nothing -> Left ("signature without worker " ++ n)
        Just (ps,_) -> unless (length ps == length ks) (Left ("worker signature arity for " ++ n))
