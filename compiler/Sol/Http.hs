{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Sol.Http where

import Control.Exception
import Control.Monad (forM, forM_, unless, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.Char (isAscii, isAlphaNum, toLower, ord)
import Data.List (isPrefixOf)
import Foreign.C.String
import Foreign.C.Types
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Storable (peek, poke)
import Foreign.Ptr (Ptr, castPtr)
import Data.Word (Word64)
import System.Directory (getTemporaryDirectory, removePathForcibly)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.IO
import qualified System.Posix.Temp as T
import System.Timeout (timeout)
import Text.Read (readMaybe)
import Sol.Effects (ProcessSpec(..))
import qualified Sol.Process as P
import qualified Sol.ScriptIO as S

data Redirect = NoRedirect | HttpsRedirect Int | HttpRedirect Int deriving (Show,Read)
data Options = Options Int Integer Int Redirect FilePath [(String,Int,String)] deriving (Show,Read)
data Request = Request String String [(String,String)] B.ByteString
data Failure = Failure Int Int String deriving (Show,Read)
data Info = Info Int [(String,String)] Integer deriving (Show)
data Response = Response Info B.ByteString
data Wire = Wire String String [(String,String)] FilePath FilePath FilePath Options deriving (Show,Read)
data Report = Report Int Int Int Integer String deriving (Show,Read)

api :: [(String,Int,String)]
api = [("Http.backend",1,"Unit -> Result String HttpError")
      ,("Http.request",2,"HttpOptions -> HttpRequest -> Result HttpResponse HttpError")
      ,("Http.download",4,"HttpOptions -> HttpRequest -> String -> Bool -> Result HttpInfo HttpError")]

foreign import ccall unsafe "sol_http_available" available :: IO CInt
foreign import ccall unsafe "sol_http_version" version :: IO CString
foreign import ccall safe "sol_http_request" performRaw :: CString -> CString -> CString -> Ptr CChar -> CSize -> CLong
  -> Word64 -> Word64 -> CLong -> CInt -> CString -> CString -> CString -> CString
  -> Ptr CLong -> Ptr Word64 -> Ptr CLong -> CString -> CSize -> IO CInt

backend :: IO (Either Failure String)
backend = do
  supported <- available
  if supported==0 then pure (Left (Failure 2 0 "libcurl >= 8.4 with HTTP/HTTPS and TLS is required"))
  else Right <$> (version >>= peekCString)

invalid :: String -> Either Failure a
invalid = Left . Failure 1 0

validate :: Bool -> Options -> Request -> Either Failure ()
validate capture (Options deadline bodyLimit headers redirects ca routes) (Request url method requestHeaders body) = do
  unless (deadline>=1 && deadline<=86400000) (invalid "HTTP deadline must be 1..86400000 milliseconds")
  unless (bodyLimit>=0 && bodyLimit <= if capture then 16777216 else 1099511627776) (invalid "HTTP body limit is outside the capture/download budget")
  unless (headers>=0 && headers<=1048576) (invalid "HTTP aggregate header limit must be 0..1048576 bytes")
  unless (length url<=8192 && ("http://" `isPrefixOf` url || "https://" `isPrefixOf` url)) (invalid "HTTP URL must use explicit http:// or https:// and fit 8192 characters")
  let authority=takeWhile (`notElem` "/?#") (drop (if "https://" `isPrefixOf` url then 8 else 7) url)
  when (null authority || '@' `elem` authority) (invalid "HTTP URL needs a host and must not contain userinfo")
  unless (method `elem` ["GET","HEAD","POST","PUT","PATCH","DELETE","OPTIONS"]) (invalid "unsupported HTTP method")
  when (method `elem` ["GET","HEAD"] && not (B.null body)) (invalid "GET/HEAD request body must be empty")
  when (B.length body>16777216) (invalid "HTTP request body exceeds 16 MiB")
  let redirectsCount=case redirects of NoRedirect -> -1; HttpsRedirect n -> n; HttpRedirect n -> n
  unless (redirectsCount>= -1 && redirectsCount<=20) (invalid "HTTP redirect limit must be 0..20")
  case redirects of
    NoRedirect -> pure ()
    _ -> do
      when (redirectsCount<0) (invalid "HTTP redirect limit must be 0..20")
      unless (method `elem` ["GET","HEAD"]) (invalid "automatic redirects are restricted to GET/HEAD")
  unless (length requestHeaders<=128) (invalid "HTTP request header count exceeds 128")
  forM_ requestHeaders $ \(key,value) -> do
    when (length (take 257 key)>256 || length (take 8193 value)>8192) (invalid "HTTP request header name/value exceeds 256/8192 characters")
    unless (not (null key) && all token key) (invalid "invalid HTTP request header name")
    when (any (\c -> ord c<32 && c/='\t' || ord c==127) value) (invalid "HTTP request header value contains a control character")
    when (map toLower key `elem` ["content-length","transfer-encoding","connection","host","accept-encoding","expect"])
      (invalid "request framing/host/encoding headers are owned by the HTTP adapter")
  encoded <- either (invalid . ("HTTP request encoding: "++)) Right (S.encodeUtf8 (concatMap (\(k,v)->k++": "++v++"\n") requestHeaders))
  when (B.length encoded>65536) (invalid "HTTP request headers exceed 64 KiB")
  unless (length routes<=32) (invalid "HTTP DNS route count exceeds 32")
  forM_ routes $ \(host,port,address) -> do
    unless (not (null host) && length host<=253 && all (\c -> isAscii c && (isAlphaNum c || c `elem` ".-")) host
            && port>=1 && port<=65535 && not (null address) && length address<=64
            && all (`elem` "0123456789abcdefABCDEF.:[]") address) (invalid "invalid HTTP DNS route")
  forM_ [url,ca] $ \text -> do
    when (length text>8192) (invalid "HTTP URL/CA path exceeds 8192 characters")
    when (any (\c -> ord c<32 || ord c==127) text) (invalid "HTTP URL/CA path contains a control character")
    either (invalid . ("HTTP request encoding: "++)) (const (Right ())) (S.encodeUtf8 text)
  where token c = isAscii c && (isAlphaNum c || c `elem` "!#$%&'*+-.^_`|~")

request :: Options -> Request -> IO (Either Failure Response)
request options req = execute True options req $ \info bodyPath -> do
  bytes <- bracket (S.openReadHandle bodyPath) hClose (P.boundedRead 0 "HTTP body" 16777216)
  pure (Right (Response info bytes))

download :: Options -> Request -> FilePath -> Bool -> IO (Either Failure Info)
download options req target replace = execute False options req $ \info@(Info status _ _) bodyPath ->
  if status<200 || status>=300 then pure (Left (Failure 9 status "HTTP download was not published: response is not 2xx"))
  else do
    result <- S.copyPublishNow bodyPath target 65536 replace
    pure (either (\e -> Left (Failure 8 0 (show e))) (const (Right info)) result)

-- The outer deadline covers worker startup, transfer, result reading and file
-- publication. Unwinding Process.run kills/reaps the isolated native worker.
execute :: Bool -> Options -> Request -> (Info -> FilePath -> IO (Either Failure a)) -> IO (Either Failure a)
execute capture options@(Options deadline _ headerLimit _ _ _) req@(Request url method headers body) consume =
  case validate capture options req of
    Left why -> pure (Left why)
    Right () -> handleIO $ do
      supported <- backend
      case supported of
        Left why -> pure (Left why)
        Right _ -> do
          timed <- timeout (deadline*1000) $ do
            temporary <- getTemporaryDirectory
            bracket (T.mkdtemp (temporary </> "sol-http-")) removePathForcibly $ \scratch -> do
              let bodyInput=scratch </> "request-body"
                  bodyOutput=scratch </> "response-body"
                  headerOutput=scratch </> "response-headers"
                  metadata=scratch </> "request"
              B.writeFile bodyInput body
              writeFile metadata (show (Wire url method headers bodyInput bodyOutput headerOutput options))
              self <- getExecutablePath
              result <- P.run (P.Pipeline [ProcessSpec [self,"sol-http-worker",metadata] Nothing [] "" Nothing]
                        (P.InputBytes B.empty) (P.CaptureUtf8 4096) (P.CaptureUtf8 4096) 0 P.LastStage)
              case result of
                Left (P.Failure why _ _ _) -> pure (Left (Failure 7 0 ("HTTP worker: "++why)))
                Right (P.Result code _ out _) | code/=0 -> pure (Left (Failure 7 0 "HTTP worker failed"))
                Right (P.Result _ _ out _) -> case S.decodeUtf8 out >>= maybe (Left "invalid HTTP worker report") Right . readMaybe of
                  Left why -> pure (Left (Failure 7 0 why))
                  Right (Report reason status curlCode count message) ->
                    if reason/=0 then pure (Left (Failure reason curlCode message)) else do
                      rawHeaders <- bracket (S.openReadHandle headerOutput) hClose (P.boundedRead 0 "HTTP headers" headerLimit)
                      case parseHeaders status rawHeaders of
                        Left why -> pure (Left why)
                        Right pairs -> consume (Info status pairs count) bodyOutput
          pure (maybe (Left (Failure 4 0 (if capture then "HTTP deadline exceeded"
            else "HTTP deadline exceeded; a completed destination publication is not rolled back"))) id timed)
  where
    handleIO action = action `catches`
      [Handler (\(e :: IOException)->pure (Left (Failure 8 0 (show e)))),
       Handler (\(P.Failure why _ _ _)->pure (Left (Failure 5 0 why)))]

parseHeaders :: Int -> B.ByteString -> Either Failure [(String,String)]
parseHeaders status raw
  | status<100 || status>599 = Left (Failure 7 0 "invalid HTTP status")
  | otherwise = go 0 [] (map (dropCR . C.unpack) (C.split '\n' raw))
  where
    dropCR s = if not (null s) && last s=='\r' then init s else s
    trim = reverse . dropWhile (`elem` " \t") . reverse . dropWhile (`elem` " \t")
    go observed headers [] = if observed==status then Right (reverse headers) else Left (Failure 7 0 "HTTP status/header mismatch")
    go _ _ (line:rest) | "HTTP/" `isPrefixOf` line = case words line of
      _:code:_ | Just n <- readMaybe code -> go n [] rest
      _ -> Left (Failure 7 0 "invalid HTTP status line")
    go observed headers ("":rest) = go observed headers rest
    go observed headers (line:rest) = case break (==':') line of
      (name,':':value) | not (null name) && all (\c -> isAscii c && (isAlphaNum c || c `elem` "!#$%&'*+-.^_`|~")) name ->
        if any (\c -> ord c<32 && c/='\t' || ord c==127) value then Left (Failure 7 0 "control character in HTTP response header")
        else go observed ((map toLower name,trim value):headers) rest
      _ -> Left (Failure 7 0 "invalid HTTP response header")

-- Internal worker entry. Request/result files live in a private 0700 directory.
worker :: FilePath -> IO ()
worker metadata = do
  report <- (do
    bytes <- bracket (S.openReadHandle metadata) hClose (P.boundedRead 0 "HTTP worker request" 524288)
    text <- either S.failIO pure (S.decodeUtf8 bytes)
    Wire url method headers bodyInput bodyOutput headerOutput options@(Options deadline bodyLimit headerLimit redirects ca routes) <-
      maybe (S.failIO "invalid HTTP worker request") pure (readMaybe text)
    body <- bracket (S.openReadHandle bodyInput) hClose (P.boundedRead 0 "HTTP request body" 16777216)
    either (S.failIO . show) pure (validate False options (Request url method headers body))
    let redirs=case redirects of NoRedirect -> -1; HttpsRedirect n -> n; HttpRedirect n -> n
        allowHttp=case redirects of HttpRedirect _ -> 1; _ -> 0
        headerText=concatMap (\(k,v)->k++": "++v++"\n") headers
        routeText=concatMap (\(host,port,address)->host++":"++show port++":"++address++"\n") routes
    forStrings [url,method,headerText,ca,routeText,bodyOutput,headerOutput] $ \[u,m,hs,caPath,rs,bPath,hPath] ->
      B.useAsCStringLen body $ \(input,n) -> alloca $ \status -> alloca $ \count -> alloca $ \curlCode -> allocaBytes 1024 $ \message -> do
        poke message (0 :: CChar)
        reason <- performRaw u m hs input (fromIntegral n) (fromIntegral deadline)
                  (fromInteger bodyLimit) (fromIntegral headerLimit) (fromIntegral redirs) allowHttp
                  caPath rs bPath hPath status count curlCode message 1024
        Report (fromIntegral reason) <$> (fromIntegral <$> peek status) <*> (fromIntegral <$> peek curlCode)
          <*> (fromIntegral <$> peek count) <*> peekCString message)
    `catch` \(e :: IOException) -> pure (Report 8 0 0 0 (show e))
  putStr (show report)
  hFlush stdout
  where
    forStrings [] action = action []
    forStrings (text:rest) action = case S.encodeUtf8 text of
      Left why -> S.failIO why
      Right bytes -> B.useAsCString bytes $ \p -> forStrings rest (action . (p:))
