-- A snapshot of checked callback bodies, their home identities and role
-- analysis. Build once per program view, rather than once per caller.
module Core.Typed.Callback.Catalog
  (Catalog,catalog,catalogPrograms,catalogOwners,catalogFunctions,catalogSchemas,catalogContracts,
   catalogTemplates,catalogAnalysis,catalogLibrary,catalogFirstType,catalogBinderIds,catalogNamespaces,catalogNames,catalogHomes) where
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Contract (codeContractsWith)
import Core.Typed.Callback.Model
import Core.Typed.Callback.Analysis
import Core.Typed.Walk (mapChildrenM,allBinders)
import Core.Typed.Instantiate (functionVariables)
import qualified Core.Typed.Program as P
import Core.Identity (BinderId(..),Namespace)
import Type.Syntax
import qualified Type.Substitution as U
import Control.Monad (unless)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Catalog=Catalog
  { catalogOwners :: M.Map String ClosedFunction,catalogFunctions :: [Function],
    catalogSchemas :: M.Map String Scheme,catalogContracts :: M.Map CodeId CodeContract,
    catalogTemplates :: M.Map Target Template,catalogAnalysis :: CallbackAnalysis,
    catalogLibrary :: CodeLibrary,catalogFirstType :: Int,catalogBinderIds :: S.Set BinderId,
    catalogNamespaces :: S.Set Namespace,catalogNames :: S.Set String,catalogHomes :: M.Map CodeId String }

catalog :: TypeContext -> M.Map String ClosedFunction -> Either String Catalog
catalog _ owners=makeCatalog (M.unions (map closedGlobals (M.elems owners))) owners

-- A program already owns its complete global schema map. Combining that map
-- once per program avoids unioning the same thousands of declarations once
-- for every function in it. Closed-function-only clients retain the facade.
catalogPrograms :: TypeContext -> [P.Program] -> M.Map String ClosedFunction -> Either String Catalog
catalogPrograms _ parents owners=makeCatalog (M.unions (map P.programSchemas parents)) owners

makeCatalog :: M.Map String Scheme -> M.Map String ClosedFunction -> Either String Catalog
makeCatalog globals owners=do
  library<-codeLibrary (M.elems owners)
  unless (all (\(name,p)->name==functionName (closedRoot p)) (M.toList owners))
    (Left "typed callback catalog: owner key/name mismatch")
  unless (length labels==S.size (S.fromList labels)) (Left "typed callback catalog: duplicate code identity")
  pure (Catalog owners functions schemas contracts templates (analyzeCallbacks templates) library firstType identities namespaces names homes)
  where
    codes=M.unions (map closedCode (M.elems owners))
    labels=concatMap (M.keys . closedCode) (M.elems owners)
    functions=map closedRoot (M.elems owners)++map codeAsFunction (M.elems codes)
    schemas=globals `M.union` M.unions (map (embedded . functionBody) functions)
    embedded e=(case exprNode e of Var (Global n sc)->M.singleton n sc;_->M.empty)
      <>getConst (mapChildrenM (Const . embedded) e)
    contracts=M.unions (map closedContracts (M.elems owners))
    rootTemplate owner=
      let fn=closedRoot owner
          entry=CodeFunction (CodeId (functionName fn)) EntryCode [] (functionParameters fn) (functionBody fn)
          cs=codeContractsWith (closedImports owner) globals (M.insert (codeId entry) entry (closedCode owner))
          c=cs M.! codeId entry
          rigid=maybe mempty U.schemeVariables (M.lookup (functionName fn) schemas)
          signature=c {contractQuantifiers=
            (filter (`S.notMember` fst rigid) (fst (contractQuantifiers c)),
             filter (`S.notMember` snd rigid) (snd (contractQuantifiers c)))}
      in (RootTarget (functionName fn),Template [] (functionParameters fn) (functionBody fn) signature EntryCode)
    templates=M.fromList (map rootTemplate (M.elems owners)) `M.union`
      M.mapKeys CodeTarget (M.map (\f->Template (codeCaptures f) (codeParameters f) (codeBody f) (contracts M.! codeId f) (codeKind f)) codes)
    homes=M.fromList [(key,name) | (name,p)<-M.toList owners,key<-M.keys (closedCode p)]
    binders=[b | f<-functions,b<-functionParameters f++allBinders (functionBody f)]
    identities=S.fromList (map binderId binders)
    namespaces=S.fromList [ns | BinderId ns _<-S.toList identities]
    names=S.fromList (map binderName binders++map functionName functions)
      <>S.unions (map (M.keysSet . embedded . functionBody) functions)
    allVars=mconcat (map functionVariables functions)
      <>mconcat [U.variables ty<>(S.fromList qs,S.fromList rs) | Forall qs rs ty<-M.elems schemas]
    firstType=1+maximum (0:S.toList (fst allVars)++S.toList (snd allVars))
