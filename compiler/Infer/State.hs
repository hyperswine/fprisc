-- Inference state/context ownership; no dependency on the inference engine.
module Infer.State where
import Core.Syntax (Name)
import Core.Identity (BinderId, ExprId, Namespace)
import Type.Syntax (Type, Row, Scheme)
import Ownership.Shape (LShape)
import Struct (Sigs)
import qualified Infer.Evidence as Evidence
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.Set as S
import Control.Monad.State.Strict (State)

type TEnv = M.Map Name Scheme

data IEnv = IEnv
  { iFresh :: !Int,
    iSub :: IM.IntMap Type, -- tvar solutions
    iRSub :: IM.IntMap Row, -- rowvar solutions
    iErrs :: [String],
    iNotes :: [(Name, String)], -- pretty-printed inferred schemes
    iHoles :: [(String, Type)], -- typed holes: ?name / ?? with site type
    iHolesP :: [(String, String)], -- same, pretty (zonked at end)
    iHoledCons :: S.Set (Name, Int), -- constructors with ?? fields: calls trap
    iNextSite :: !Int,
    iSites :: IM.IntMap (Name, Type), -- operator/layout sites awaiting resolution
    iSiteExpressions :: IM.IntMap ExprId,
    iSiteMarks :: IM.IntMap (Maybe Int), -- retain their diagnostic anchors
    iCarriers :: IM.IntMap (Name, Name), -- carrier var -> (param, sig)
    iHere :: Maybe Int, -- spans step 3: the innermost enclosing SMark's
                        -- source offset while inference walks under it;
                        -- report stamps it into diagnostics as "@OFF~ "
    iPairs :: IM.IntMap (Type, Type), -- operator sites whose operand types
                                     -- were NOT unified eagerly (both concrete,
                                     -- at least one user type): resolution may
                                     -- pick a two-typed operator global
    iVecPlans :: M.Map Name [Type], -- hidden layout requirements of native bindings
    iVecRefs :: IM.IntMap [Type], -- requirements instantiated at each reference
    iVecOwners :: IM.IntMap Name,
    iDefTypes :: M.Map Name Type,
    iInterfaces :: [(Name, Type)], -- zonked checked types for interface identity
    iEvidenceBuilder :: Maybe Evidence.Builder,
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
    icEvidence :: M.Map Name Name
  }

extend :: TEnv -> ICtx -> ICtx
extend e c = c {icEnv = M.union e (icEnv c), icBound = M.keysSet e `S.union` icBound c, icEvidence = foldr M.delete (icEvidence c) (M.keys e)}


initialIEnv :: Maybe Namespace -> IEnv
initialIEnv capture = IEnv
  { iFresh=0, iSub=IM.empty, iRSub=IM.empty, iErrs=[], iNotes=[],
    iHoles=[], iHolesP=[], iHoledCons=S.empty, iNextSite=0,
    iSites=IM.empty, iSiteExpressions=IM.empty, iSiteMarks=IM.empty, iCarriers=IM.empty,
    iHere=Nothing, iPairs=IM.empty, iVecPlans=M.empty,
    iVecRefs=IM.empty, iVecOwners=IM.empty, iDefTypes=M.empty,
    iInterfaces=[], iEvidenceBuilder=Evidence.emptyBuilder <$> capture,
    iLinSigs=[] }
