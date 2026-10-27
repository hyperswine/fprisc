-- Advisory optimization facts, independent of optimizer data structures.
-- Version 1 deliberately uses definition locations, not guessed call sites.
module Diagnostic.Remark
  (Mode(..),parseMode,Heat(..),EffectCause(..),Reason(..),Remark(..),kind,
   selected,toDiagnostic,renderText,renderJSON,renderInputs) where
import qualified Core.Typed.Decision as D
import Diagnostic.Syntax
import qualified Diagnostic.Render as D
import Source.Span
import Data.Char (ord)
import Data.Bits (xor)
import Data.Word (Word64)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Map.Strict as M
import Data.List (intercalate)
import Numeric (showHex)

data Mode=Off | Hot | All | JSON deriving (Eq,Show)
parseMode :: Maybe String -> Either String Mode
parseMode Nothing=Right Off
parseMode (Just s)=case s of
  "hot"->Right Hot;"all"->Right All;"json"->Right JSON
  _->Left "--remarks expects hot, all or json"
data Heat=Cold | RecursiveGroup | ReceiveLoop deriving (Eq,Ord,Show)
data EffectCause=UnknownFunction | Primitive | Partial | UnknownCall
  | FunctionValue | Recursive | Failure | Unsupported deriving (Eq,Ord,Show)
data Reason=InlineAttempt String D.InlineReason | CallbackAttempt String D.CallbackReason
  | CompatibilityLowering String
  | CallbackEffect String EffectCause String | CaptureEffect | CaptureBudget
  | LoopRegionPlaced | ReceiveRegionPlaced | ReceiveTrampolinePlaced
  deriving (Eq,Ord,Show)
data Remark=Remark {owner :: String,heat :: Heat,reason :: Reason} deriving (Eq,Ord,Show)
kind :: Remark -> RemarkKind
kind r=case reason r of
  InlineAttempt {}->InlineRemark;CallbackAttempt {}->CallbackRemark
  CompatibilityLowering _->PathRemark
  CallbackEffect {}->FusionRemark;CaptureEffect->FusionRemark;CaptureBudget->FusionRemark
  _->RegionRemark
kindName PathRemark="path"
kindName FusionRemark="not-fused"
kindName RegionRemark="region"
kindName InlineRemark="inline"
kindName CallbackRemark="generic-call"
pass r=case kind r of PathRemark->"typed-lowering";FusionRemark->"typed-fusion";RegionRemark->"regions";InlineRemark->"typed-inline-attempt";CallbackRemark->"typed-callback-attempt"
applied r=case reason r of
  InlineAttempt _ D.Inlined->True
  CallbackAttempt _ D.Specialized->True
  _->kind r==RegionRemark
selected :: Mode -> Remark -> Bool
selected Off _=False
selected Hot r=not (applied r) && heat r/=Cold
selected _ _=True
message r=case reason r of
  InlineAttempt target why->"inline attempt for `"++target++"`: "++inlineMessage why
  CallbackAttempt target why->"callback specialization attempt for `"++target++"`: "++callbackMessage why
  CompatibilityLowering detail->"compatibility lowering: "++detail
  CallbackEffect callback _ detail->"callback `"++callback++"` prevents fusion: "++detail
  CaptureEffect->"passes not fused: capture evaluation can have effects or fail"
  CaptureBudget->"passes not fused: combined capture budget exceeded"
  LoopRegionPlaced->"loop region selected; cycles per slab"
  ReceiveRegionPlaced->"receive-loop region selected; cycles per slab and before parking with previous roots"
  ReceiveTrampolinePlaced->"receive-turn trampoline selected"
toDiagnostic :: Remark -> Diagnostic
toDiagnostic r=(inDefinition (owner r) (diagnostic (OptimizationRemark (kind r)) Nothing (message r)))
  {diagnosticSeverity=Note}
-- Empty message disables the legacy renderer's token-search fallback. Only
-- the known definition anchor supplies a location for this first slice.
location sources anchors r=D.resolveDiagnostic sources anchors (toDiagnostic r) {diagnosticMessage=""}
renderText :: D.Sources -> D.Anchors -> Remark -> String
renderText sources anchors r=D.renderLocated (location sources anchors r)
  ++"remark["++kindName (kind r)++"] "++message r
renderJSON :: D.Sources -> D.Anchors -> Remark -> String
renderJSON sources anchors r=object
  [("remarkVersion","1"),("positionEncoding",string "utf-32"),("kind",string (kindName (kind r))),
   ("outcome",string (if applied r then "applied" else "declined")),("reason",reasonJSON (reason r)),
   ("owner",string (owner r)),("file",file),("start",start),("end","null"),
   ("precision",string "definition"),("heat",string (show (heat r))),("pass",string (pass r)),
   ("message",string (message r)),("fix","null")]
  where
    (file,start)=case D.diagnosticLocation (location sources anchors r) of
      Just (AtLine f l)->(string f,point l 1)
      Just (AtPoint f l c)->(string f,point l c)
      Nothing->("null","null")
    point l c=object [("line",show (l-1)),("character",show (c-1))]
reasonJSON r=object $ ("tag",string tag):fields
  where
    (tag,fields)=case r of
      InlineAttempt target why->let (tag,fields)=inlineReason why in (tag,("callee",string target):fields)
      CallbackAttempt target why->let (tag,fields)=callbackReason why in (tag,("callee",string target):fields)
      CompatibilityLowering detail->("CompatibilityLowering",[("detail",string detail)])
      CallbackEffect name cause detail->("CallbackEffect",[("callback",string name),
        ("cause",object [("tag",string (show cause)),("detail",string detail)])])
      CaptureEffect->("CaptureEffect",[]);CaptureBudget->("CaptureBudget",[])
      LoopRegionPlaced->("LoopRegionPlaced",[]);ReceiveRegionPlaced->("ReceiveRegionPlaced",[])
      ReceiveTrampolinePlaced->("ReceiveTrampolinePlaced",[])
object fields="{"++intercalate "," [string k++":"++v | (k,v)<-fields]++"}"
-- Bind editor results to exactly the decoded source snapshots this compile
-- consumed. This is provenance, not an assembly cache key or security hash.
renderInputs :: D.Sources -> String
renderInputs sources=object [("remarkInputsVersion","1"),("kind",string "inputs"),
  ("algorithm",string "fnv1a-64-utf8"),("files","["++intercalate ","
    [object [("file",string file),("digest",string (digest source))] | (file,source)<-M.toAscList sources]++"]")]
  where
    digest source=let value=BS.foldl' (\h byte->(h `xor` fromIntegral byte)*1099511628211)
                       (14695981039346656037::Word64) (TE.encodeUtf8 (T.pack source))
                      in let hex=showHex value "" in replicate (16-length hex) '0'++hex
string s='"':concatMap escape s++"\""
  where
    escape '"'="\\\"";escape '\\'="\\\\"
    escape c | ord c<32=let h=showHex (ord c) "" in "\\u"++replicate (4-length h) '0'++h
             | otherwise=[c]

inlineMessage why=case why of
  D.Inlined->"applied"
  D.RecursiveCallee->"recursive callee kept as a call"
  D.NullaryCallee->"nullary entry is not an inline candidate"
  D.OverWeight n limit->"weight at least "++show n++" exceeds limit "++show limit
  D.UsesForbiddenGlobal names->"requires linker-private globals: "++intercalate ", " names
  D.ArityMismatch {}->"capture or argument arity does not match the template"
  D.ContractInstantiation->"checked contract could not be instantiated at this call"
callbackMessage why=case why of
  D.Specialized->"applied"
  D.OverArity n limit->"minimum arity "++show n++" exceeds "++show limit
  D.TooDeep n limit->"clone depth "++show n++" reached limit "++show limit
  D.TooManyClones n limit->"clone count "++show n++" reached limit "++show limit
  D.OverNodeBudget n limit->"node budget "++show n++" exceeds "++show limit
  D.Unification->"callback types could not be unified"
  D.EscapingType->"specialization would expose a private quantified type"
  D.RetainedArityOverflow->"clone restored to the original call: retained callback objects exceed the 64-field entry limit"
  D.NoKnownArgument->"no known callback argument"
  D.Unstable->"callback role changes within the recursive group"
  D.UnsafeArgument->"callback capture or argument is not safe to substitute"
  D.UnknownTarget->"computed callback target is not safely known"
inlineReason why=case why of
  D.Inlined->("Inlined",[]);D.RecursiveCallee->("RecursiveCallee",[]);D.NullaryCallee->("NullaryCallee",[])
  D.OverWeight n limit->("OverWeight",[("weightLowerBound",show n),("limit",show limit)])
  D.UsesForbiddenGlobal names->("UsesForbiddenGlobal",[("globals","["++intercalate "," (map string names)++"]")])
  D.ArityMismatch ec ac ep ap->("ArityMismatch",[("expectedCaptures",show ec),("actualCaptures",show ac),("expectedArguments",show ep),("actualArguments",show ap)])
  D.ContractInstantiation->("ContractInstantiation",[])
callbackReason why=case why of
  D.Specialized->("Specialized",[])
  D.OverArity n limit->budget "OverArity" n limit
  D.TooDeep n limit->budget "TooDeep" n limit
  D.TooManyClones n limit->budget "TooManyClones" n limit
  D.OverNodeBudget n limit->budget "OverNodeBudget" n limit
  D.Unification->("Unification",[]);D.EscapingType->("EscapingType",[])
  D.RetainedArityOverflow->("RetainedArityOverflow",[("limit","64")])
  D.NoKnownArgument->("NoKnownArgument",[]);D.Unstable->("Unstable",[])
  D.UnsafeArgument->("UnsafeArgument",[]);D.UnknownTarget->("UnknownTarget",[])
  where budget tag n limit=(tag,[("observed",show n),("limit",show limit)])
