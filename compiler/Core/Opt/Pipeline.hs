-- Ordered Core transformations and their ABI metadata. A result can only be
-- obtained through the checked driver; consumers cannot pair a program with
-- signatures from another stage. This is a structural check, not Core typing.
module Core.Opt.Pipeline
  (OptimizationOptions(..), CorePass(..), PassReport(..), OptimizedCore,
   optimizeCore,optimizeCoreWithImports,optimizeCoreWithCheckedImports,optimizeCoreWithProducts, optimizedProgram, optimizedSignatures, optimizationNotes,
   optimizationReports, verifyPassResult) where
import Core.Syntax
import Core.Opt.Fusion (fuseCompatibilityWithImports)
import Core.Opt.Normalize (normIn)
import Core.Opt.PairReturns (productReturnProgramWithVariants)
import Workers (ScalarSignatures, workerizeWithProducts, internalWorker)
import Core.Opt.StoredLists (storeLists)
import Core.Opt.ProductParameters
import Reuse (reuseProgramWithImports, poolResetters)
import Control.Monad (foldM, unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Compiler.DataLayout (tupWideBase)

data OptimizationOptions = OptimizationOptions
  { optFusion :: Bool, optWorkers :: Bool, optFieldWorkers :: Bool, optTupleScalars :: Bool,
    optScalarWorkers :: Bool, optPairReturns :: Bool, optProductWidth :: Int, optNormalize :: Bool, optReuse :: Bool,
    -- known pool resetters beyond this program and its imports (the linked
    -- program's, Reuse.poolResetters): reuse never spans a call to one
    optPoolResetters :: S.Set Name, optSpineBuilders :: M.Map Name (Int,Int),
    -- std/map's balance and node, from the linked program: the owned-map
    -- walker inlines them to rebuild a rebalanced node in place (Reuse)
    optMapBodies :: Prog }
  deriving (Eq, Show)

data CorePass = FuseVectors | MakeWorkers | NormalizeForReuse | ReuseConstructors | BuildStrings | PairReturns
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
optimizeCoreWithImports=optimizeCoreWithCheckedImports S.empty
optimizeCoreWithCheckedImports :: S.Set Name -> Prog -> OptimizationOptions -> S.Set Name -> Prog -> Either String OptimizedCore
optimizeCoreWithCheckedImports=optimizeCoreWithProducts emptyProductParameters
optimizeCoreWithProducts :: ProductParameters -> S.Set Name -> Prog -> OptimizationOptions -> S.Set Name -> Prog -> Either String OptimizedCore
optimizeCoreWithProducts products checked imports opts elide input = do
  verifyPassResult input input M.empty
  foldM run (OptimizedCore input M.empty [])
    [FuseVectors, MakeWorkers, NormalizeForReuse, ReuseConstructors, BuildStrings, PairReturns]
  where
    run state pass = do
      let before = optimizedProgram state
          (after,sigs,notes,enabled) = case pass of
            FuseVectors -> let (p,ns) = if optFusion opts then fuseCompatibilityWithImports (checkedKinds (M.union before imports) products) checked imports before else (before,[])
                           in (p,optimizedSignatures state,ns,optFusion opts)
            MakeWorkers -> let fields = optWorkers opts && optFieldWorkers opts
                               scalars = optWorkers opts && optScalarWorkers opts
                               (p,ns,ss) = workerizeWithProducts products fields (optTupleScalars opts) scalars before
                           in (p,ss,ns,fields || scalars)
            NormalizeForReuse ->
              let enabled = optReuse opts && optNormalize opts
                  p = if enabled then M.map (\(ps,b)->(ps,normIn (S.fromList ps) b)) before else before
              in (p,optimizedSignatures state,[],enabled)
            ReuseConstructors -> let (p,ns) = if optReuse opts then reuseProgramWithImports (optSpineBuilders opts) (optMapBodies opts) imports (optPoolResetters opts `S.union` poolResetters (M.union before imports)) elide before else (before,[])
                                 in (p,optimizedSignatures state,ns,optReuse opts)
            -- strcat chains into one call over a tuple of the pieces; on
            -- where reuse is (64-bit, fuelled, no ARC: the runtime has it)
            BuildStrings -> let p=if optReuse opts then buildStrings before else before
                            in (p,optimizedSignatures state,["string pieces: "++n | (n,b)<-M.toList p, M.lookup n before /= Just b],optReuse opts)
            -- after every pass that reads call results: the twins are the last functions made
            PairReturns
              | optPairReturns opts ->
                  let width=optProductWidth opts
                      (stored,notes)=storeLists products width before
                      (out,ss,ns)=productReturnProgramWithVariants (variantResults before products) width stored (optimizedSignatures state)
                  in (out,ss,notes++ns,True)
              | otherwise -> (before,optimizedSignatures state,[],False)
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

-- An interpolation (a strcat chain of three or more pieces) becomes one
-- runtime call over a tuple of its pieces: one String and one copy, where
-- the chain made a String per piece and copied the front again at every
-- step. str comes off each piece: the runtime renders a non-String piece as
-- str would (a float piece is already its String: Infer's str! sites).
-- The tuple keeps the pieces in order, so they evaluate as before.
buildStrings :: Prog -> Prog
buildStrings=M.map (\(ps,b)->(ps,go b))
  where
    go e=case e of
      CApp (CApp (CVar "strcat") _) _ | leaves@(_:_:_:_)<-chain e ->
        CApp (CVar "$strcatT") (CMk (tupleTid (length leaves)) 0 (map (go . unstr) leaves))
      CApp f a -> CApp (go f) (go a)
      CLet k a b -> CLet k (go a) (go b)
      CIf c a b -> CIf (go c) (go a) (go b)
      CMk t v fs -> CMk t v (map go fs)
      CProj k a -> CProj k (go a)
      CTagEq t v a -> CTagEq t v (go a)
      CLam qs b -> CLam qs (go b)
      _ -> e
    chain (CApp (CApp (CVar "strcat") a) b)=chain a++chain b
    chain x=[x]
    unstr (CApp (CVar "str") x)=x
    unstr x=x
    -- runtime/fpr.h: Tup2 4, Tup3 5, Tup4..Tup8 10..14, wider T_TUPN + n
    tupleTid n | n==2=4 | n==3=5 | n<=8=n+6 | otherwise=tupWideBase+n
