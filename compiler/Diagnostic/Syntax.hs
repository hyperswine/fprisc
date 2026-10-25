{-# LANGUAGE DeriveGeneric #-}
-- Semantic source diagnostics. Text never encodes ownership of a source
-- location or definition. Legacy marker formatting exists only for old APIs.
module Diagnostic.Syntax
  (Diagnostic(..), Severity(..), DiagnosticCode(..), DefinitionStyle(..), diagnostic, inDefinition, aboutDefinition,
   renderLegacyDiagnostic, diagnosticBody) where
import GHC.Generics (Generic)
import Control.DeepSeq (NFData)
import Source.Span
data Severity = Error | Warning | Note deriving (Eq,Ord,Show,Generic)
data DiagnosticCode = InferenceError | TypeMismatch | UnboundName | CoverageError
  | SignatureGenerality | SafetyError | MeasureError | LinearityError deriving (Eq,Ord,Show,Generic)
data DefinitionStyle = ContextPrefix | MentionedInMessage deriving (Eq,Ord,Show,Generic)
data Diagnostic = Diagnostic
  { diagnosticSeverity :: Severity, diagnosticCode :: DiagnosticCode,
    diagnosticOwner :: Maybe String, diagnosticOffset :: Maybe SourceOffset,
    diagnosticSpan :: Maybe SourceSpan, diagnosticMessage :: String,
    diagnosticDefinitionStyle :: DefinitionStyle }
  deriving (Eq,Show,Generic)
diagnostic :: DiagnosticCode -> Maybe SourceOffset -> String -> Diagnostic
diagnostic code offset message=Diagnostic
  { diagnosticSeverity=Error, diagnosticCode=code, diagnosticOwner=Nothing,
    diagnosticOffset=offset, diagnosticSpan=Nothing, diagnosticMessage=message,
    diagnosticDefinitionStyle=ContextPrefix }
inDefinition :: String -> Diagnostic -> Diagnostic
inDefinition owner d=case diagnosticOwner d of Nothing->d {diagnosticOwner=Just owner}; _->d
aboutDefinition :: String -> Diagnostic -> Diagnostic
aboutDefinition owner d=d {diagnosticOwner=Just owner,diagnosticDefinitionStyle=MentionedInMessage}
diagnosticBody :: Diagnostic -> String
diagnosticBody d=definitionPrefix d++diagnosticMessage d
renderLegacyDiagnostic :: Diagnostic -> String
renderLegacyDiagnostic d=definitionPrefix d
  ++ maybe "" (\(SourceOffset o) -> "@"++show o++"~ ") (diagnosticOffset d)
  ++ diagnosticMessage d
definitionPrefix :: Diagnostic -> String
definitionPrefix d=case diagnosticDefinitionStyle d of
  ContextPrefix->maybe "" (\n -> "in "++n++": ") (diagnosticOwner d)
  MentionedInMessage->""

instance NFData Severity
instance NFData DiagnosticCode
instance NFData Diagnostic
instance NFData DefinitionStyle
