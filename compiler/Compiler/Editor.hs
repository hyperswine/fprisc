-- Versioned editor output from the ordinary checking pipeline. This owns no
-- inference rules. Types are published only after every checking gate passes.
module Compiler.Editor
  (Report, disabled, run, context, source, diagnostics, legacy, problem, types, resources) where
import Control.Exception (try, catch, IOException, displayException, evaluate)
import Control.Monad (forM)
import qualified Resource.Analysis as Resource
import qualified Cost as C
import Core.Syntax (Prog, Name, Core(CErr))
import qualified Precond
import System.Timeout (timeout)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)
import Data.IORef
import qualified Data.Map.Strict as M
import Data.List (intercalate)
import Data.Char (ord)
import Data.Bits (xor)
import Data.Word (Word64)
import Numeric (showHex)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Diagnostic.Render as D
import Diagnostic.Syntax
import Source.Span
import System.Directory (makeAbsolute)
import System.Exit (ExitCode(..),exitWith)
import System.IO (hPutStrLn,stderr)

data State = State D.Sources D.Anchors [(String,Diagnostic)] [(String,String)] String [(String,String)]
type Report = Maybe (IORef State)
disabled :: Report
disabled = Nothing

run :: Bool -> FilePath -> (Report -> IO ()) -> IO ()
run False _ action = action Nothing
run True root action = do
  ref <- newIORef (State M.empty M.empty [] [] "not-requested" [])
  let ioFailure :: IOException -> IO ()
      ioFailure e = do
        problem (Just ref) "io" (displayException e) Nothing
        hPutStrLn stderr (displayException e)
        exitWith (ExitFailure 1)
  result <- try (action (Just ref) `catch` ioFailure) :: IO (Either ExitCode ())
  let ok = case result of Left (ExitFailure _) -> False; _ -> True
  State sources anchors ds ts resourceStatus rs <- readIORef ref
  absRoot <- makeAbsolute root
  pairs <- forM (M.keys sources) $ \f -> do a <- makeAbsolute f; pure (f,a)
  let paths=M.fromList pairs
      file f=M.findWithDefault absRoot f paths
      pos l c=obj [("line",show (max 0 (l-1))),("character",show (max 0 (c-1)))]
      location d=case D.diagnosticLocation (D.resolveDiagnostic sources anchors d) of
        Just (AtPoint f l c) -> [("file",str (file f)),("start",pos l c),("precision",str "point")]
        Just (AtLine f l) -> [("file",str (file f)),("start",pos l 1),("precision",str "definition")]
        Nothing -> [("file",str absRoot),("start",pos 1 1),("precision",str "file")]
      diagnosticJSON (code,d)=obj ([("code",str code),("kind",str (show (diagnosticCode d))),
        ("severity",show (case diagnosticSeverity d of Error->1::Int; Warning->2; Note->3)),
        ("message",str (diagnosticBody d))] ++ location d)
      errors=if not ok && null ds then [("check-failed",diagnostic InferenceError Nothing "Compiler check failed; see compiler output for details.")] else ds
      typeJSON (n,t)=case M.lookup n anchors of
        Just (f,l) | M.member f sources -> Just (obj [("file",str (file f)),("name",str (takeWhile (/='@') n)),("type",str t),("start",pos l 1)])
        _ -> Nothing
      resourceJSON (n,value)=case M.lookup n anchors of
        Just (f,l) | M.member f sources -> Just (obj
          [("file",str (file f)),("name",str (takeWhile (/='@') n)),
           ("declaration",str n),("start",pos l 1),("precision",str "definition"),("summary",value)])
        _ -> Nothing
      payload=obj [("editorVersion","2"),("positionEncoding",str "utf-32"),("ok",if ok then "true" else "false"),
        ("root",str absRoot),("algorithm",str "fnv1a-64-utf8"),
        ("inputs",arr [obj [("file",str (file f)),("digest",str (digest body))] | (f,body)<-M.toAscList sources]),
        ("diagnostics",arr (map diagnosticJSON errors)),
        ("types",arr [v | ok, nt<-ts, Just v<-[typeJSON nt]]),
        ("resourceVersion","1"),("resourceModel",str "native-source-v1"),
        ("resourceStatus",str (if ok then resourceStatus else "check-failed")),
        ("resources",arr [v | ok, r<-rs, Just v<-[resourceJSON r]])]
  hPutStrLn stderr payload
  case result of Left code -> exitWith code; Right () -> pure ()

context :: Report -> D.Sources -> D.Anchors -> IO ()
context Nothing _ _ = pure ()
context (Just ref) ss aa=modifyIORef' ref $ \(State s a d t status rs)->State (M.union ss s) (M.union aa a) d t status rs
source :: Report -> FilePath -> String -> IO ()
source r f s=context r (M.singleton f s) M.empty
diagnostics :: Report -> String -> [Diagnostic] -> IO ()
diagnostics Nothing _ _=pure ()
diagnostics (Just ref) code ds=modifyIORef' ref $ \(State s a d t status rs)->State s a (d++map (\item -> (code,item)) ds) t status rs
legacy :: Report -> String -> [String] -> IO ()
legacy r code=diagnostics r code . map D.legacyDiagnostic
problem :: Report -> String -> String -> Maybe SourceSpan -> IO ()
problem r code message at=diagnostics r code [(diagnostic InferenceError Nothing message) {diagnosticSpan=at}]
types :: Report -> [(String,String)] -> IO ()
types Nothing _=pure ()
types (Just ref) ts=modifyIORef' ref $ \(State s a d _ status rs)->State s a d ts status rs

obj :: [(String,String)] -> String
obj xs="{"++intercalate "," [str k++":"++v | (k,v)<-xs]++"}"
arr :: [String] -> String
arr xs="["++intercalate "," xs++"]"
str :: String -> String
str s='"':concatMap escape s++"\""
  where
    escape '"'="\\\""; escape '\\'="\\\\"
    escape c | ord c<32=let h=showHex (ord c) "" in "\\u"++replicate (4-length h) '0'++h
             | otherwise=[c]
digest :: String -> String
digest s=let h=BS.foldl' (\v b->(v `xor` fromIntegral b)*1099511628211) (14695981039346656037::Word64) (TE.encodeUtf8 (T.pack s))
             hex=showHex h "" in replicate (16-length hex) '0'++hex

-- Fully force optional summaries inside the budget. Required contract checks
-- have already completed; timeout discards only resource presentation.
resources :: Report -> M.Map Name [Name] -> Prog -> Precond.PreTable -> Resource.Analysis -> IO ()
resources Nothing _ _ _ _ = pure ()
resources (Just ref) surface prog predicates analysis = do
  configured <- lookupEnv "FPR_EDITOR_RESOURCE_BUDGET_MS"
  let budget = maybe 1000 (max 0 . min 10000) (configured >>= readMaybe)
      rows = [(n, summary n derived effective) | (n,(derived,effective)) <- M.toAscList (Resource.equations analysis)]
      force = sum [sum (map ord (n ++ json)) | (n,json) <- rows]
      summary n derived effective =
        let rename = C.renameC (M.fromList (zip
              (fst (M.findWithDefault ([], CErr "") n prog))
              (M.findWithDefault [] n surface)))
            bound unit cost = let c = rename cost in obj
              [("unit",str unit),("status",str (if null (C.omegas c) && null (C.coefsIn c) then "proved" else "unknown")),
               ("display",str (C.prettyCost c)),("expression",costJSON c),
               ("unknowns",arr (map str (C.omegas c ++ map ("coefficient " ++) (C.coefsIn c))))]
            equation e = obj [("work",bound "abstract-operations" (C.ceWork e)),
                              ("allocation",bound "requested-cell-bytes" (C.ceAlloc e))]
            declared = case M.lookup n (Resource.declarations analysis) of
              Nothing -> obj []
              Just d -> obj ([("work",bound "abstract-operations" c) | Just c <- [C.dWork d]] ++
                             [("allocation",bound "requested-cell-bytes" c) | Just c <- [C.dAlloc d]])
         in obj [("scope",str "native-source"),("provenance",str "checked-source-cost-equations"),
           ("parameters",arr (map str (M.findWithDefault [] n surface))),
           ("domains",arr [str (Precond.renderP p) | Just (_,p) <- M.findWithDefault [] n predicates]),
           ("inferred",equation derived),("effective",equation effective),("declared",declared),
           ("stack",str "not-inferred"),("liveHeap",str "not-published"),("targetTime",str "unavailable")]
  done <- timeout (budget * 1000) (evaluate force)
  let (status, values) = case done of Nothing -> ("budget-limited",[]); Just _ -> ("complete",rows)
  modifyIORef' ref $ \(State s a d t _ _) -> State s a d t status values

-- JSON algebra is versioned independently of display text. Integers are
-- decimal strings so JavaScript cannot silently round large bounds.
costJSON :: C.Cost -> String
costJSON c = case c of
  C.CN n -> atom "constant" (show n)
  C.CP n -> atom "parameter" n
  C.CLen n -> atom "length" n
  C.CW n -> atom "callback-work" n
  C.CA n -> atom "callback-allocation" n
  C.CO n -> atom "unknown" n
  C.CK n -> atom "coefficient" n
  C.CV n -> atom "unknown-signed" n
  C.CAdd xs -> branch "add" xs
  C.CMul xs -> branch "multiply" xs
  C.CMax xs -> branch "max" xs
  C.CNat x -> branch "nonnegative" [x]
  C.CDivC x k -> obj [("op",str "ceil-divide"),("argument",costJSON x),("divisor",str (show k))]
  where
    atom tag value = obj [("op",str tag),("value",str value)]
    branch tag xs = obj [("op",str tag),("arguments",arr (map costJSON xs))]
