-- Per-caller application evidence supplements the callee's ABI declaration.
-- A retained recursive checking assumption is not a proof that this occurrence
-- has a copyable result, even when the eventual public result is copyable.
module Core.Region.CallSites (CallSites,callSites,compatibilitySites,mayCopyResult) where
import qualified Core.Typed.Syntax as T
import Core.Typed.Walk
import qualified Core.Region.Syntax as R
import qualified Core.Region.Types as Region
import Control.Monad (unless)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Caller=CheckedCalls (M.Map String Bool) | CompatibilityCalls
newtype CallSites=CallSites (M.Map String Caller)

-- Compatibility is explicit rather than inferred from an absent checked
-- occurrence. Such callers retain the established declaration-only boundary.
compatibilitySites :: S.Set String -> CallSites
compatibilitySites names=CallSites (M.fromSet (const CompatibilityCalls) names)

callSites :: Region.ValueModel -> M.Map String Int -> M.Map String (Maybe T.Function) -> Either String CallSites
callSites model arities functions=CallSites <$> M.traverseWithKey one functions
  where
    one _ Nothing=Right CompatibilityCalls
    one name (Just f)=do
      unless (name==T.functionName f && M.lookup name arities==Just (length (T.functionParameters f)))
        (Left ("region call sites: checked owner/physical arity mismatch at "++name))
      let scope=M.fromList [(T.binderId b,b) | b<-T.functionParameters f++allBinders (T.functionBody f)]
          walk e=foldl (M.unionWith (&&)) own
            (getConst (mapChildrenM (Const . (:[]) . walk) e))
            where own=case R.decodeCall scope e of
                    Just (target,args) | not (null args),M.lookup target arities==Just (length args)->
                      M.singleton target (Region.copyable model (T.exprType e))
                    _->M.empty
      pure (CheckedCalls (walk (T.functionBody f)))

-- The existing plan records target names per caller. Every saturated typed
-- occurrence of that target must therefore have a copyable result. Unknown
-- checked sites are denied; missing owners never acquire compatibility trust.
mayCopyResult :: CallSites -> String -> String -> Bool
mayCopyResult (CallSites callers) owner target=case M.lookup owner callers of
  Just CompatibilityCalls->True
  Just (CheckedCalls sites)->M.findWithDefault False target sites
  Nothing->False
