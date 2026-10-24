-- One inference run owns its program, reports, checked source facts and
-- elaboration decisions. Accessors are functions, not record-update labels.
module Infer.Result
  (InferenceResult, resultFromState, inferenceErrors, inferenceNotes,
   inferenceHoles, inferenceLinearity, inferenceTops, inferenceInterfaces,
   inferenceEvidence, inferenceElaborations, inferenceSchemes, inferenceLayoutRequirements) where
import Core.Syntax (Name)
import Frontend.Syntax (STop)
import Type.Syntax (Type, Scheme)
import qualified Data.Map.Strict as M
import Ownership.Shape (LShape)
import Infer.State
import Infer.Elaboration (ElaborationFact)
import qualified Infer.Evidence as E

data InferenceResult = Result [String] [(Name,String)] [(String,String)]
  [(Name,([LShape],LShape))] [STop] [(Name,Type)]
  (Either String (Maybe E.Evidence)) [ElaborationFact] (M.Map Name Scheme) (M.Map Name [Type])
resultFromState :: IEnv -> [STop] -> Either String (Maybe E.Evidence)
                -> [ElaborationFact] -> M.Map Name Scheme -> M.Map Name [Type] -> InferenceResult
resultFromState st tops proof sites schemes layouts = Result (iErrs st) (iNotes st) (iHolesP st)
  (iLinSigs st) tops (iInterfaces st) proof sites schemes layouts
inferenceErrors :: InferenceResult -> [String]
inferenceErrors (Result es _ _ _ _ _ _ _ _ _) = es
inferenceNotes :: InferenceResult -> [(Name,String)]
inferenceNotes (Result _ ns _ _ _ _ _ _ _ _) = ns
inferenceHoles :: InferenceResult -> [(String,String)]
inferenceHoles (Result _ _ hs _ _ _ _ _ _ _) = hs
inferenceLinearity :: InferenceResult -> [(Name,([LShape],LShape))]
inferenceLinearity (Result _ _ _ ls _ _ _ _ _ _) = ls
inferenceTops :: InferenceResult -> [STop]
inferenceTops (Result _ _ _ _ ts _ _ _ _ _) = ts
inferenceInterfaces :: InferenceResult -> [(Name,Type)]
inferenceInterfaces (Result _ _ _ _ _ ts _ _ _ _) = ts
inferenceEvidence :: InferenceResult -> Either String (Maybe E.Evidence)
inferenceEvidence (Result _ _ _ _ _ _ proof _ _ _) = proof
inferenceElaborations :: InferenceResult -> [ElaborationFact]
inferenceElaborations (Result _ _ _ _ _ _ _ sites _ _) = sites
inferenceSchemes :: InferenceResult -> M.Map Name Scheme
inferenceSchemes (Result _ _ _ _ _ _ _ _ schemes _) = schemes
inferenceLayoutRequirements :: InferenceResult -> M.Map Name [Type]
inferenceLayoutRequirements (Result _ _ _ _ _ _ _ _ _ layouts) = layouts
