-- One inference run owns its program, reports, checked source facts and
-- elaboration decisions. Private fields keep the product's construction local;
-- public accessors do not permit record updates across checking runs.
module Infer.Result
  (InferenceResult, resultFromState, inferenceErrors, inferenceDiagnostics, inferenceNotes,
   inferenceHoles, inferenceLinearity, inferenceTops, inferenceInterfaces,
   inferenceEvidence, inferenceElaborations, inferenceSchemes, inferenceLayoutRequirements,
   inferencePatterns, inferenceConstructors, inferenceBinderNames, inferenceLayoutContracts,
   inferenceConstructorTraps, inferenceSignatures, inferenceStructures) where
import Diagnostic.Syntax (Diagnostic,renderLegacyDiagnostic)
import Core.Syntax (Name)
import Core.Identity (BinderId)
import Frontend.Syntax (STop)
import Type.Syntax (Type, Scheme)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Ownership.Shape (LShape)
import Infer.State
import Infer.Elaboration (ElaborationFact)
import Infer.Pattern (PatternSite,PatternInfo)
import qualified Infer.Evidence as E
import Compiler.VectorLayout (LayoutContract)
import Struct (Sigs,Structs)

data InferenceResult = Result
  { resultErrors :: [Diagnostic], resultNotes :: [(Name,String)], resultHoles :: [(String,String)],
    resultLinearity :: [(Name,([LShape],LShape))], resultTops :: [STop], resultInterfaces :: [(Name,Type)],
    resultEvidence :: Either String (Maybe E.Evidence), resultElaborations :: [ElaborationFact],
    resultSchemes :: M.Map Name Scheme, resultLayouts :: M.Map Name [Type],
    resultPatterns :: M.Map PatternSite PatternInfo, resultConstructors :: M.Map Name Scheme,
    resultBinderNames :: M.Map BinderId Name, resultLayoutContracts :: M.Map Name LayoutContract,
    resultConstructorTraps :: M.Map Name Int, resultSignatures :: Sigs, resultStructures :: Structs }
resultFromState :: IEnv -> [STop] -> Either String (Maybe E.Evidence)
                -> [ElaborationFact] -> M.Map Name Scheme -> M.Map Name [Type] -> Sigs -> Structs -> InferenceResult
resultFromState st tops proof sites schemes layouts sigs structs = Result
  { resultErrors=iErrs st, resultNotes=iNotes st, resultHoles=iHolesP st,
    resultLinearity=iLinSigs st, resultTops=tops, resultInterfaces=iInterfaces st,
    resultEvidence=proof, resultElaborations=sites, resultSchemes=schemes, resultLayouts=layouts,
    resultPatterns=iPatterns st, resultConstructors=iConstructorSchemes st, resultBinderNames=iBinderTargets st,
    resultLayoutContracts=iLayoutContracts st,
    resultConstructorTraps=M.fromListWith min (S.toList (iHoledCons st)), resultSignatures=sigs, resultStructures=structs }
inferenceErrors :: InferenceResult -> [String]
inferenceErrors = map renderLegacyDiagnostic . resultErrors
inferenceDiagnostics :: InferenceResult -> [Diagnostic]
inferenceDiagnostics = resultErrors
inferenceNotes :: InferenceResult -> [(Name,String)]
inferenceNotes = resultNotes
inferenceHoles :: InferenceResult -> [(String,String)]
inferenceHoles = resultHoles
inferenceLinearity :: InferenceResult -> [(Name,([LShape],LShape))]
inferenceLinearity = resultLinearity
inferenceTops :: InferenceResult -> [STop]
inferenceTops = resultTops
inferenceInterfaces :: InferenceResult -> [(Name,Type)]
inferenceInterfaces = resultInterfaces
inferenceEvidence :: InferenceResult -> Either String (Maybe E.Evidence)
inferenceEvidence = resultEvidence
inferenceElaborations :: InferenceResult -> [ElaborationFact]
inferenceElaborations = resultElaborations
inferenceSchemes :: InferenceResult -> M.Map Name Scheme
inferenceSchemes = resultSchemes
inferenceLayoutRequirements :: InferenceResult -> M.Map Name [Type]
inferenceLayoutRequirements = resultLayouts
inferencePatterns :: InferenceResult -> M.Map PatternSite PatternInfo
inferencePatterns = resultPatterns
inferenceConstructors :: InferenceResult -> M.Map Name Scheme
inferenceConstructors = resultConstructors

inferenceBinderNames :: InferenceResult -> M.Map BinderId Name
inferenceBinderNames = resultBinderNames
inferenceLayoutContracts :: InferenceResult -> M.Map Name LayoutContract
inferenceLayoutContracts = resultLayoutContracts
inferenceConstructorTraps :: InferenceResult -> M.Map Name Int
inferenceConstructorTraps = resultConstructorTraps
inferenceSignatures :: InferenceResult -> Sigs
inferenceSignatures = resultSignatures
inferenceStructures :: InferenceResult -> Structs
inferenceStructures = resultStructures
