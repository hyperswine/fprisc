-- One inference run owns its program, reports, checked source facts and
-- elaboration decisions. Private fields keep the product's construction local;
-- public accessors do not permit record updates across checking runs.
module Infer.Result
  (InferenceResult, resultFromState, inferenceErrors, inferenceDiagnostics, inferenceNotes,
   inferenceHoles, inferenceLinearity, inferenceTops, inferenceInterfaces,
   inferenceEvidence, inferenceElaborations, inferenceSchemes, inferenceLayoutRequirements,
   inferencePatterns, inferenceConstructors, inferenceBinderNames) where
import Diagnostic.Syntax (Diagnostic,renderLegacyDiagnostic)
import Core.Syntax (Name)
import Core.Identity (BinderId)
import Frontend.Syntax (STop)
import Type.Syntax (Type, Scheme)
import qualified Data.Map.Strict as M
import Ownership.Shape (LShape)
import Infer.State
import Infer.Elaboration (ElaborationFact)
import Infer.Pattern (PatternSite,PatternInfo)
import qualified Infer.Evidence as E

data InferenceResult = Result
  { resultErrors :: [Diagnostic], resultNotes :: [(Name,String)], resultHoles :: [(String,String)],
    resultLinearity :: [(Name,([LShape],LShape))], resultTops :: [STop], resultInterfaces :: [(Name,Type)],
    resultEvidence :: Either String (Maybe E.Evidence), resultElaborations :: [ElaborationFact],
    resultSchemes :: M.Map Name Scheme, resultLayouts :: M.Map Name [Type],
    resultPatterns :: M.Map PatternSite PatternInfo, resultConstructors :: M.Map Name Scheme,
    resultBinderNames :: M.Map BinderId Name }
resultFromState :: IEnv -> [STop] -> Either String (Maybe E.Evidence)
                -> [ElaborationFact] -> M.Map Name Scheme -> M.Map Name [Type] -> InferenceResult
resultFromState st tops proof sites schemes layouts = Result
  { resultErrors=iErrs st, resultNotes=iNotes st, resultHoles=iHolesP st,
    resultLinearity=iLinSigs st, resultTops=tops, resultInterfaces=iInterfaces st,
    resultEvidence=proof, resultElaborations=sites, resultSchemes=schemes, resultLayouts=layouts,
    resultPatterns=iPatterns st, resultConstructors=iConstructorSchemes st, resultBinderNames=iBinderTargets st }
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
