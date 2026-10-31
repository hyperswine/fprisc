-- Versioned editor output from the ordinary checking pipeline. This owns no
-- inference rules. Types are published only after every checking gate passes.
module Compiler.Editor
  (Report, disabled, run, context, source, diagnostics, legacy, problem, types) where
import Control.Exception (try, catch, IOException, displayException)
import Control.Monad (forM)
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

data State = State D.Sources D.Anchors [(String,Diagnostic)] [(String,String)]
type Report = Maybe (IORef State)
disabled :: Report
disabled = Nothing

run :: Bool -> FilePath -> (Report -> IO ()) -> IO ()
run False _ action = action Nothing
run True root action = do
  ref <- newIORef (State M.empty M.empty [] [])
  let ioFailure :: IOException -> IO ()
      ioFailure e = do
        problem (Just ref) "io" (displayException e) Nothing
        hPutStrLn stderr (displayException e)
        exitWith (ExitFailure 1)
  result <- try (action (Just ref) `catch` ioFailure) :: IO (Either ExitCode ())
  let ok = case result of Left (ExitFailure _) -> False; _ -> True
  State sources anchors ds ts <- readIORef ref
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
      payload=obj [("editorVersion","1"),("positionEncoding",str "utf-32"),("ok",if ok then "true" else "false"),
        ("root",str absRoot),("algorithm",str "fnv1a-64-utf8"),
        ("inputs",arr [obj [("file",str (file f)),("digest",str (digest body))] | (f,body)<-M.toAscList sources]),
        ("diagnostics",arr (map diagnosticJSON errors)),
        ("types",arr [v | ok, nt<-ts, Just v<-[typeJSON nt]])]
  hPutStrLn stderr payload
  case result of Left code -> exitWith code; Right () -> pure ()

context :: Report -> D.Sources -> D.Anchors -> IO ()
context Nothing _ _ = pure ()
context (Just ref) ss aa=modifyIORef' ref $ \(State s a d t)->State (M.union ss s) (M.union aa a) d t
source :: Report -> FilePath -> String -> IO ()
source r f s=context r (M.singleton f s) M.empty
diagnostics :: Report -> String -> [Diagnostic] -> IO ()
diagnostics Nothing _ _=pure ()
diagnostics (Just ref) code ds=modifyIORef' ref $ \(State s a d t)->State s a (d++map (\item -> (code,item)) ds) t
legacy :: Report -> String -> [String] -> IO ()
legacy r code=diagnostics r code . map D.legacyDiagnostic
problem :: Report -> String -> String -> Maybe SourceSpan -> IO ()
problem r code message at=diagnostics r code [(diagnostic InferenceError Nothing message) {diagnosticSpan=at}]
types :: Report -> [(String,String)] -> IO ()
types Nothing _=pure ()
types (Just ref) ts=modifyIORef' ref $ \(State s a d _)->State s a d ts

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
