-- Rendering/linked snapshot adapter only. No mutation, layout planning or
-- optimizer authority; the reusable analysis lives in Core.Typed.Callable.
module Compiler.CallableReport (writeReport) where
import qualified Core.Typed.Callable as C
import Core.Typed.Callback.Model
import qualified Core.Typed.Callback.Catalog as Catalog
import Core.Typed.Syntax
import Core.Typed.Pipeline (closedDefinitions,closedInput)
import Core.Typed.Program (programTypes)
import qualified Compiler.Native.Linked as L
import qualified Compiler.Native.Core as N
import qualified Diagnostic.Render as D
import Source.Span (SourceOffset(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (intercalate)
import Data.Char (ord)
import Data.Bits (xor)
import Data.Word (Word64)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString as B
import Numeric (showHex)
import System.IO (hPutStrLn,stderr)

writeReport :: Bool -> D.Anchors -> L.LinkedProgram -> IO ()
writeReport detailed anchors linked=case snapshots of
  []->hPutStrLn stderr "callables: no checked native artifacts"
  first:_->case Catalog.catalogPrograms (programTypes first) snapshots owners of
    Left why->ioError (userError ("callable analysis: "++why))
    Right catalog->do
      let templates=Catalog.catalogTemplates catalog
          roots=S.map RootTarget (S.unions [L.artifactExports a | a<-artifacts,L.artifactId a==L.RootArtifact]) `S.intersection` M.keysSet templates
          analysis=C.analyze C.defaultLimits roots templates
          identity=digest (show ([(t,cs,ps,body,contract,kind) | (t,Template cs ps body contract kind)<-M.toAscList templates],roots,C.defaultLimits))
          home (RootTarget n)=n
          home (CodeTarget c)=M.findWithDefault (show c) c (Catalog.catalogHomes catalog)
          location t=case M.lookup (home t) anchors of
            Nothing->obj [("owner",str (home t)),("precision",str "unlocated")]
            Just (file,line)->obj [("owner",str (home t)),("file",str file),("line",show line),("precision",str "owner-definition")]
          member (C.Member t supplied)=obj [("target",target t),("supplied",show supplied),
            ("remaining",case M.lookup t templates of Just (Template _ ps _ _ _)->show (max 0 (length ps-supplied));_->"null")]
          value v=obj [("status",str (C.valueStatus v)),("members",arr (map member (S.toAscList (C.valueMembers v)))),
            ("unknowns",arr (map str (S.toAscList (C.valueUnknowns v)))),
            ("fields",obj [(k,value x) | (k,x)<-M.toAscList (C.valueFields v)])]
          binder b=obj [("id",str (show (binderId b))),("name",str (binderName b)),
            ("scheme",str (show (binderScheme b))),("shape",str (show (binderShape b))),
            ("ownershipEvidence",str "shape-only; callable environments require a separate multiplicity proof")]
          summary (t,s)=obj [("target",target t),("source",location t),
            ("reached",bool (C.summaryReached s)),("productFlowInvalidated",bool (C.summaryProductFlowInvalidated s)),("contract",str (show (C.summaryContract s))),
            ("captures",arr (map binder (C.summaryCaptures s))),("parameters",arr (map binder (C.summaryParameters s))),
            ("inputs",arr [obj [("slot",str (show slot)),("value",value v)] | (slot,v)<-M.toAscList (C.summaryInputs s)]),
            ("result",value (C.summaryResult s)),("dependencies",arr (map target (S.toAscList (C.summaryDependencies s))))]
          site s=obj [("owner",target (C.siteOwner s)),("source",location (C.siteOwner s)),
            ("path",arr (map show (C.sitePath s))),("origin",str (show (C.siteOrigin s))),
            ("originOffset",maybe "null" (show . offsetCharacters) (C.siteOffset s)),
            ("kind",str (show (C.siteKind s))),("type",str (show (C.siteType s))),
            ("arguments",show (C.siteArguments s)),("value",value (C.siteValue s))]
          counts=M.fromListWith (+) [(show (C.siteKind s),1::Int) | s<-C.analysisSites analysis]
          report=obj [("callableVersion","1"),("stage",str "checked-linked-before-regions"),
            ("scope",str "owned-templates; root exports are open entries; runtime bodies are not analyzed"),
            ("snapshot",str identity),("snapshotAlgorithm",str "fnv1a-64-utf8"),
            ("status",str (C.analysisStatus analysis)),("rounds",show (C.analysisRounds analysis)),
            ("limits",obj [("rounds",show (C.maxRounds C.defaultLimits)),("members",show (C.maxMembers C.defaultLimits)),("depth",show (C.maxDepth C.defaultLimits))]),
            ("roots",arr (map target (S.toAscList roots))),
            ("counts",obj [(k,show n) | (k,n)<-M.toAscList counts]),
            ("summaries",arr (map summary (M.toAscList (C.analysisSummaries analysis)))),
            ("sites",arr (map site (C.analysisSites analysis))),
            ("machinePAPCounts",str "see per-unit apply diagnostics; static emission markers, not runtime allocation counts")]
      if detailed then hPutStrLn stderr report else do
        hPutStrLn stderr ("callables v1: checked-linked-before-regions; "++C.analysisStatus analysis++
          " after "++show (C.analysisRounds analysis)++" rounds; snapshot="++identity)
        hPutStrLn stderr ("  owned templates="++show (M.size (C.analysisSummaries analysis))++
          " reached="++show (length (filter C.summaryReached (M.elems (C.analysisSummaries analysis))))++
          " (root exports are open entries)")
        hPutStrLn stderr ("  "++intercalate " " [k++"="++show n | (k,n)<-M.toAscList counts])
        hPutStrLn stderr "  Static candidates, not dynamic allocations; runtime bodies excluded. --callables=json includes typed summaries, source anchors and unknown reasons."
  where
    artifacts=M.elems (L.linkedArtifacts linked)
    programs=[(a,N.nativeClosed (L.artifactCore a)) | a<-artifacts]
    snapshots=map (closedInput . snd) programs
    owners=M.unions [M.withoutKeys (closedDefinitions p) (L.artifactElided a) | (a,p)<-programs]
target (RootTarget n)=obj [("kind",str "root"),("identity",str n)]
target (CodeTarget (CodeId n))=obj [("kind",str "code"),("identity",str n)]
bool True="true"
bool False="false"
obj xs="{"++intercalate "," [str k++":"++v | (k,v)<-xs]++"}"
arr xs="["++intercalate "," xs++"]"
str s='"':concatMap escape s++"\""
  where
    escape '"'="\\\"";escape '\\'="\\\\"
    escape c | ord c<32=let h=showHex (ord c) "" in "\\u"++replicate (4-length h) '0'++h
             | otherwise=[c]
digest s=let h=B.foldl' (\v b->(v `xor` fromIntegral b)*1099511628211) (14695981039346656037::Word64) (T.encodeUtf8 (T.pack s))
         in showHex h ""
