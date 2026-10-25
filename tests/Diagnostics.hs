module Main where
import qualified Diagnostic.Syntax as D
import qualified Diagnostic.Render as R
import Source.Span
import Frontend.Parser (program)
import Frontend.Diagnostics (bindAnchors,anchorMsg)
import Infer
import qualified Sol.Infer as Sol
import Struct (sigTable,structTable)
import qualified Safety
import Frontend.Linearity
import Frontend.Syntax
import Ownership.Finding
import Ownership.Shape (LShape(..),demandOwnership)
import qualified Data.Set as S
import Text.Megaparsec (parse,errorBundlePretty)
import qualified Data.Map.Strict as M
import Control.Monad (unless,forM_)
import Data.List (isInfixOf)

check :: String -> Bool -> IO ()
check message ok=unless ok (error message)
main :: IO ()
main=do
  let src="helper =\n  value = \"λ🙂\";\n  value.\n"
      offset=SourceOffset (length "helper =\n  value = ")
      sources=M.singleton "unicode.fpr" src
      anchors=M.singleton "helper" ("unicode.fpr",1)
      d=D.inDefinition "helper" (D.diagnostic D.TypeMismatch (Just offset) "checked failure")
      located=R.resolveDiagnostic sources anchors d
  check "decoded-character offset resolves" (R.diagnosticLocation located==Just (AtPoint "unicode.fpr" 2 11))
  check "resolved point span retains exact offset" (R.locatedSpan located==Just (pointSpan "unicode.fpr" offset))
  check "structured renderer preserves the old CLI spelling"
    (R.renderLocated located==anchorMsg sources anchors (D.renderLegacyDiagnostic d))
  let literal=D.inDefinition "helper" (D.diagnostic D.InferenceError Nothing "@999~ in other: literal text")
  check "prose cannot forge an owner or offset" (R.renderSourceDiagnostic sources anchors literal=="unicode.fpr:1: in helper: @999~ in other: literal text")
  check "unknown owners do not expose coordinate machinery"
    (R.renderSourceDiagnostic M.empty M.empty d=="in helper: checked failure")
  check "invalid offsets are not resolved beyond the source"
    (offsetPosition src (SourceOffset (-1))==Nothing && offsetPosition src (SourceOffset (length src+1))==Nothing)
  check "Unicode counts characters" (offsetPosition "λ🙂x\n" (SourceOffset 2)==Just (1,3))
  let explicit=literal {D.diagnosticSpan=Just (SourceSpan "unicode.fpr" offset (SourceOffset (offsetCharacters offset+4)))}
  check "an explicit range owns its source location" (R.diagnosticLocation (R.resolveDiagnostic sources M.empty explicit)==Just (AtPoint "unicode.fpr" 2 11))
  let safetyTops=[TBind "self" [PVar "x"] [] (SApp (SVar "self") (SVar "x"))]
      safety=Safety.checkSafety S.empty safetyTops []
      safetyErrors=Safety.safetyDiagnostics safety
      (legacySafety,_)=Safety.safetyCheck S.empty safetyTops []
  check "safety producer retains code and owner"
    (not (null safetyErrors) && all (\x -> D.diagnosticCode x==D.SafetyError && D.diagnosticOwner x==Just "self") safetyErrors)
  check "safety compatibility text is preserved"
    (legacySafety==["self is unsafe (recursive) but has no explicit `self : unsafe ...` signature"])
  let measureSource="loop : (n : Int | measure n) -> Int.\nloop n = loop n.\n"
      measureTops=either (error . errorBundlePretty) id (parse program "measure.fpr" measureSource)
      measures=Safety.safetyDiagnostics (Safety.checkSafety S.empty measureTops [])
  check "measure refusals are structured at their producer"
    (any (\x -> D.diagnosticCode x==D.MeasureError && D.diagnosticOwner x==Just "loop") measures)
  check "ownership constraints are not string markers"
    (demandOwnership (LVar "a") "unused"==[RequireUnrestricted "a"]
     && demandOwnership LL "\1literal"==[Violation Nothing "\1literal"])
  let ownedRecord=LRecS [("keep",LU),("owned",LL)] False
      projectionInfo=(buildLinInfo []) {liSigs=M.singleton "project" ([ownedRecord],LU)}
      projection=[TBind "project" [PVar "r"] [] (SMark 7 (SProj (SVar "r") ["keep"]))]
      projectionErrors=linearityDiagnostics (checkLinearity projectionInfo projection)
  check "linearity diagnostics retain nested statement points"
    (any (\x -> D.diagnosticCode x==D.LinearityError && D.diagnosticOwner x==Just "project" && D.diagnosticOffset x==Just (SourceOffset 7)) projectionErrors)
  let genericInfo=(buildLinInfo []) {liSigs=M.fromList [("dup",([LVar "a"],LTupS [LVar "a",LVar "a"])),("wrap",([LVar "b"],LU))]}
      generic=[TBind "dup" [PVar "x"] [] (STup [SVar "x",SVar "x"]),
               TBind "wrap" [PVar "y"] [] (SApp (SVar "dup") (SVar "y"))]
      checkedGeneric=checkLinearity genericInfo generic
  check "typed unrestricted obligations propagate through the fixpoint"
    (null (linearityDiagnostics checkedGeneric) && M.lookup "dup" (linearityConstraints checkedGeneric)==Just ["a"] && M.lookup "wrap" (linearityConstraints checkedGeneric)==Just ["b"])
  let names=["chain"++show i | i<-[0::Int ..90]]
      signatures=M.fromList [(name,([LVar "a"],LTupS [LVar "a",LVar "a"])) | name<-names]
      chain=TBind (head names) [PVar "x"] [] (STup [SVar "x",SVar "x"])
        :[TBind next [PVar "x"] [] (SApp (SVar previous) (SVar "x")) | (previous,next)<-zip names (tail names)]
      chainInfo=(buildLinInfo []) {liSigs=M.insert "owned" ([LL],LTupS [LL,LL]) signatures}
      chainResult=checkLinearity chainInfo (chain++[TBind "owned" [PVar "t"] [] (SApp (SVar (last names)) (SVar "t"))])
  check "long chains cannot return incomplete ownership evidence"
    (all (\name -> M.lookup name (linearityConstraints chainResult)==Just ["a"]) names
     && any ((==Just "owned").D.diagnosticOwner) (linearityDiagnostics chainResult))
  let source="unsafe base.\nlate =\n  value = \"a\" % \"b\";\n  value.\nbad = neverBound Unit.\n"
      tops=either (error . errorBundlePretty) id (parse program "contract.fpr" source)
      sigs=sigTable tops; structs=structTable tops
      native=inferTopsResult Nothing aotProf sigs structs tops
      sol=Sol.inferResult sigs structs tops
  forM_ [native,sol] $ \result -> do
    let ds=inferenceDiagnostics result
        late=[x | x<-ds,D.diagnosticOwner x==Just "late"]
        names=[x | x<-ds,D.diagnosticCode x==D.UnboundName]
    check "delayed operator refusal owns its function" (any (isInfixOf "not defined for String" . D.diagnosticMessage) late)
    check "delayed operator refusal owns its statement point" (all ((==Just (SourceOffset (length "unsafe base.\nlate =\n  value = "))).D.diagnosticOffset) late)
    check "unbound errors have a stable semantic code" (any ((==Just "bad").D.diagnosticOwner) names)
    check "inference stores prose without marker metadata"
      (all (\x -> not ("in late:" `isInfixOf` D.diagnosticMessage x) && not ("~ " `isInfixOf` D.diagnosticMessage x)) ds)
    check "compatibility projection is explicit" (inferenceErrors result==map D.renderLegacyDiagnostic ds)
    let rendered=map (R.renderSourceDiagnostic (M.singleton "contract.fpr" source) (bindAnchors "contract.fpr" source tops)) late
    check "late diagnostic is anchored at its actual statement"
      (any (isInfixOf "contract.fpr:3:11: in late:") rendered)
  putStrLn "Structured diagnostics: producer ownership/codes, late source points, Unicode, explicit ranges, literal metadata refusal and compatibility rendering passed"
