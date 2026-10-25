-- Inference state/context ownership; no dependency on the inference engine.
module Infer.State where
import Core.Syntax (Name)
import Core.Identity (BinderId, ExprId, Namespace)
import Type.Syntax (Type, Row, Scheme)
import Ownership.Shape (LShape)
import Struct (Sigs)
import Diagnostic.Syntax (Diagnostic)
import Source.Span (SourceOffset)
import Infer.Pattern (PatternSite, PatternInfo)
import Compiler.VectorLayout (LayoutContract)
import qualified Infer.Evidence as Evidence
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.Set as S
import Control.Monad.State.Strict (State)

data Carrier = Carrier {carrierParameter :: Name, carrierSignature :: Name, carrierRecord :: !Type}
data OperatorScope = OperatorScope (Maybe Name) (M.Map Name Type)

type TEnv = M.Map Name Scheme

data IEnv = IEnv
  { iFresh :: !Int,
    iSub :: IM.IntMap Type, -- tvar solutions
    iRSub :: IM.IntMap Row, -- rowvar solutions
    iErrs :: [Diagnostic],
    iNotes :: [(Name, String)], -- pretty-printed inferred schemes
    iDeferredDeclarations :: [(Name,Scheme,Type)],
    iHoles :: [(String, Type)], -- typed holes: ?name / ?? with site type
    iHolesP :: [(String, String)], -- same, pretty (zonked at end)
    iHoledCons :: S.Set (Name, Int), -- constructors with ?? fields: calls trap
    iNextSite :: !Int,
    iSites :: IM.IntMap (Name, Type), -- operator/layout sites awaiting resolution
    iSiteExpressions :: IM.IntMap ExprId,
    iSiteMarks :: IM.IntMap (Maybe SourceOffset), -- retain their diagnostic anchors
    iSiteOwners :: IM.IntMap (Maybe Name),
    iCarriers :: IM.IntMap Carrier, -- carrier var -> (param, sig)
    iOperatorScopes :: IM.IntMap OperatorScope,
    iCarrierChoices :: IM.IntMap Carrier,
    iHere :: Maybe SourceOffset, -- innermost parser point, retained as data
    iCurrentOwner :: Maybe Name,
    iPairs :: IM.IntMap (Type, Type), -- operator sites whose operand types
                                     -- were NOT unified eagerly (both concrete,
                                     -- at least one user type): resolution may
                                     -- pick a two-typed operator global
    iVecPlans :: M.Map Name [Type], -- hidden layout requirements of native bindings
    iLocalLayoutSchemes :: M.Map Name Scheme,
    iLocalLayoutBindings :: M.Map Name BinderId,
    iLayoutContracts :: M.Map Name LayoutContract,
    iVecRefs :: IM.IntMap [Type], -- requirements instantiated at each reference
    iVecOwners :: IM.IntMap Name,
    iDefTypes :: M.Map Name Type,
    iInterfaces :: [(Name, Type)], -- zonked checked types for interface identity
    iEvidenceBuilder :: Maybe Evidence.Builder,
    iPatterns :: M.Map PatternSite PatternInfo,
    iBinderTargets :: M.Map BinderId Name,
    iConstructorSchemes :: M.Map Name Scheme,
    iLinSigs :: [(Name, ([LShape], LShape))] -- INFERRED linearity shapes
      -- per user bind (zonked types -> LShape): the linearity checker
      -- consumes these for functions WITHOUT an explicit sig, closing
      -- the audited hole where an unannotated function (main included)
      -- could double-use a Vec because liSigs only knew declared TSigs
  }

type I = State IEnv

data IProf = IProf
  { ipBuiltins :: TEnv, -- the profile's primitive surface
    ipTopEvals :: Bool, -- infer + rewrite `> expr.` tops (HostedBytecode;
                        -- the AOT driver handles TEval itself)
    ipPathStr :: Bool, -- @Path literals type as String (HostedBytecode;
                       -- AOT expands them structurally before inference)
    ipVectorLayouts :: Bool, -- raw-bit native elements need static output layouts
    ipMat4 :: Bool -- Mat4/Vec4 `*` elaboration -- only where the prelude
                   -- defines mulMM/mulMV (the AOT tiers)
  }

data ICtx = ICtx
  { icEnv :: TEnv, -- values in scope
    icCons :: TEnv, -- constructor schemes (for patterns)
    icSigs :: Sigs,
    icProf :: IProf,
    icBound :: S.Set Name,
    icLocalIds :: M.Map Name BinderId,
    icOwner :: Maybe Name,
    icEvidence :: M.Map Name Name,
    icRecursiveSignatures :: TEnv -- published interfaces behind this SCC's provisional calls
  }

extend :: TEnv -> ICtx -> ICtx
extend e c = c {icEnv = M.union e (icEnv c), icBound = M.keysSet e `S.union` icBound c, icEvidence = foldr M.delete (icEvidence c) (M.keys e)}


initialIEnv :: Maybe Namespace -> IEnv
initialIEnv capture = IEnv
  { iFresh=0, iSub=IM.empty, iRSub=IM.empty, iErrs=[], iNotes=[],
    iHoles=[], iHolesP=[], iHoledCons=S.empty, iNextSite=0,
    iSites=IM.empty, iSiteExpressions=IM.empty, iSiteMarks=IM.empty, iCarriers=IM.empty,
    iHere=Nothing, iCurrentOwner=Nothing, iSiteOwners=IM.empty, iPairs=IM.empty, iVecPlans=M.empty,
    iVecRefs=IM.empty, iVecOwners=IM.empty, iDefTypes=M.empty,
    iLocalLayoutSchemes=M.empty, iLocalLayoutBindings=M.empty, iLayoutContracts=M.empty,
    iOperatorScopes=IM.empty, iCarrierChoices=IM.empty,
    iInterfaces=[], iEvidenceBuilder=Evidence.emptyBuilder <$> capture,
    iDeferredDeclarations=[], iLinSigs=[], iPatterns=M.empty, iBinderTargets=M.empty, iConstructorSchemes=M.empty }
