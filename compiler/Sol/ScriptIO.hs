{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- Immediate, attempt-owned binary I/O. No operation in this module adds a
-- file-content snapshot or a deferred effect to the transaction.
module Sol.ScriptIO where

import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (forM_, unless, when)
import Foreign.C.Error (Errno(..), errnoToIOError)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, plusPtr)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Char (ord)
import Data.Typeable (Typeable)
import Data.Unique (Unique, newUnique)
import qualified System.Environment as Env
import System.Directory (getCurrentDirectory, removeFile, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO
import System.IO.Error (isDoesNotExistError, ioeSetFileName)
import qualified System.Posix.Files as PF
import qualified System.Posix.IO as PIO
import qualified System.Posix.Temp as PT

data ScriptExit = ScriptExit Int deriving (Show, Typeable)
instance Exception ScriptExit
data ScriptAbort = ScriptAbort Int deriving (Show, Typeable)
instance Exception ScriptAbort

-- One declaration/arity table shared by the prelude and HAL registration.
api :: [(String, Int, String)]
api =
  [ ("Bytes.empty", 1, "Unit -> Bytes")
  , ("Bytes.fromList", 1, "List Int -> Result Bytes String")
  , ("Bytes.toList", 1, "Bytes -> List Int")
  , ("Bytes.len", 1, "Bytes -> Int")
  , ("Bytes.at", 2, "Int -> Bytes -> Result Int String")
  , ("Bytes.slice", 3, "Int -> Int -> Bytes -> Result Bytes String")
  , ("Bytes.concat", 1, "List Bytes -> Bytes")
  , ("Bytes.contains", 2, "Bytes -> Bytes -> Bool")
  , ("Utf8.encode", 1, "String -> Result Bytes String")
  , ("Utf8.decode", 1, "Bytes -> Result String String")
  , ("Utf8.decodeReplace", 1, "Bytes -> String")
  , ("Utf8.decodeChunk", 3, "Bytes -> Bytes -> Bool -> Result (String, Bytes) String")
  , ("Utf8.decodeChunkReplace", 3, "Bytes -> Bytes -> Bool -> Result (String, Bytes) String")
  , ("Stream.openRead", 2, "String -> Int -> Result ByteReader String")
  , ("Stream.openWrite", 2, "String -> Int -> Result ByteWriter String")
  , ("Stream.stdin", 1, "Int -> Result ByteReader String")
  , ("Stream.stdout", 1, "Int -> Result ByteWriter String")
  , ("Stream.stderr", 1, "Int -> Result ByteWriter String")
  , ("Stream.readChunk", 1, "ByteReader -> (Result ByteRead String, ByteReader)")
  , ("Stream.readLine", 2, "Int -> ByteReader -> (Result ByteRead String, ByteReader)")
  , ("Stream.writeChunk", 2, "Bytes -> ByteWriter -> (Result Unit String, ByteWriter)")
  , ("Stream.closeRead", 1, "ByteReader -> Result Unit String")
  , ("Stream.closeWrite", 1, "ByteWriter -> Result Unit String")
  , ("Stream.foldChunks", 3, "(a -> Bytes -> a) -> a -> ByteReader -> (Result a String, ByteReader)")
  , ("Stream.foldLines", 4, "(a -> Bytes -> a) -> a -> Int -> ByteReader -> (Result a String, ByteReader)")
  , ("IO.stdout", 1, "Bytes -> Result Unit String")
  , ("IO.stderr", 1, "Bytes -> Result Unit String")
  , ("IO.stdoutText", 1, "String -> Result Unit String")
  , ("IO.stderrText", 1, "String -> Result Unit String")
  , ("IO.readLine", 1, "Int -> Result TextRead String")
  , ("IO.cwd", 1, "Unit -> Result String String")
  , ("Env.get", 1, "String -> Result EnvValue String")
  , ("Env.set", 2, "String -> String -> Result Unit String")
  , ("Env.unset", 1, "String -> Result Unit String")
  , ("Script.exit", 1, "Int -> Unit")
  , ("Script.abort", 1, "Int -> Unit")
  , ("Script.replayable", 1, "(Unit -> a) -> a")
  , ("Fs.copyNow", 3, "String -> String -> Int -> Result Int FsError")
  , ("Fs.copyPublishNow", 4, "String -> String -> Int -> Bool -> Result Int FsError")
  , ("Fs.renameNow", 3, "String -> String -> Bool -> Result Unit FsError")
  ]

-- Reader pending bytes are bounded by max(chunk cap, selected line limit).
data Resource = Reader Handle Int BS.ByteString Bool | Writer Handle Int Bool
data Runtime = Runtime
  { identity :: Unique
  , resources :: MVar (Int, IM.IntMap (MVar Resource))
  , originalEnv :: MVar (M.Map String (Maybe String))
  , inputReader :: MVar Resource
  }

newRuntime :: IO Runtime
newRuntime = do
  owner <- newUnique
  Runtime owner <$> newMVar (1, IM.empty) <*> newMVar M.empty
    <*> newMVar (Reader stdin 65536 BS.empty False)

attempt :: IO a -> IO (Either String a)
attempt action = (Right <$> action) `catch` \(e :: IOException) -> pure (Left (show e))

failIO :: String -> IO a
failIO = ioError . userError

checkCap :: Int -> IO ()
checkCap n = unless (n >= 1 && n <= 16777216) (failIO "buffer limit must be 1..16777216 bytes")

checkPath :: FilePath -> IO ()
checkPath path = do
  when ('\0' `elem` path) (failIO "path contains NUL")
  either failIO (const (pure ())) (encodeUtf8 path)

register :: Runtime -> Resource -> IO Int
register rt resource = do
  cell <- newMVar resource
  modifyMVar (resources rt) $ \(next, table) -> pure ((next + 1, IM.insert next cell table), next)

resourceHandle :: Resource -> Handle
resourceHandle (Reader h _ _ _) = h
resourceHandle (Writer h _ _) = h

owned :: Resource -> Bool
owned (Reader _ _ _ b) = b
owned (Writer _ _ b) = b

closeRuntime :: Runtime -> IO ()
closeRuntime rt = do
  cells <- modifyMVar (resources rt) $ \(next, table) -> pure ((next, IM.empty), IM.elems table)
  forM_ cells $ \cell -> do
    resource <- readMVar cell
    when (owned resource) $ do
      r <- attempt (hClose (resourceHandle resource))
      either (hPutStrLn stderr . ("[sol] stream cleanup failed: " ++)) pure r
  env <- swapMVar (originalEnv rt) M.empty
  forM_ (M.toList env) $ \(key, value) -> do
    r <- attempt (maybe (Env.unsetEnv key) (Env.setEnv key) value)
    either (hPutStrLn stderr . ("[sol] environment restore failed: " ++)) pure r

getResource :: Runtime -> Int -> IO (MVar Resource)
getResource rt key = do
  (_, table) <- readMVar (resources rt)
  maybe (failIO "closed or foreign stream") pure (IM.lookup key table)

-- O_NOFOLLOW protects the source/destination leaf, including a replacement
-- between the path check and open. Nonblocking open avoids hanging on FIFOs;
-- the fd kind check then admits regular file streams only.
openReadHandle :: FilePath -> IO Handle
openReadHandle path = mask $ \restore -> do
  checkPath path
  fd <- PIO.openFd path PIO.ReadOnly PIO.defaultFileFlags
    { PIO.nofollow = True, PIO.nonBlock = True, PIO.cloexec = True }
  st <- PF.getFdStatus fd `onException` PIO.closeFd fd
  unless (PF.isRegularFile st) $ PIO.closeFd fd >> ioError
    (ioeSetFileName (userError "file reader requires a regular file; use Stream.stdin for pipes") path)
  h <- PIO.fdToHandle fd `onException` PIO.closeFd fd
  restore (hSetBinaryMode h True >> hSetBuffering h NoBuffering >> pure h) `onException` hClose h

openWriteHandle :: FilePath -> IO Handle
openWriteHandle path = fst <$> openWriteHandleOwned path

openWriteHandleOwned :: FilePath -> IO (Handle, PF.FileStatus)
openWriteHandleOwned path = mask $ \restore -> do
  checkPath path
  fd <- PIO.openFd path PIO.WriteOnly PIO.defaultFileFlags
    { PIO.creat = Just 0o600, PIO.exclusive = True, PIO.nofollow = True, PIO.cloexec = True }
  created <- PF.getFdStatus fd `onException` PIO.closeFd fd
  h <- PIO.fdToHandle fd `onException` PIO.closeFd fd
  restore (hSetBinaryMode h True >> hSetBuffering h NoBuffering >> pure (h, created)) `onException` hClose h

openReader :: Runtime -> FilePath -> Int -> IO (Either String Int)
openReader rt path cap = attempt $ mask $ \restore -> do
  checkCap cap
  h <- restore (openReadHandle path)
  register rt (Reader h cap BS.empty True) `onException` hClose h

openWriter :: Runtime -> FilePath -> Int -> IO (Either String Int)
openWriter rt path cap = attempt $ mask $ \restore -> do
  checkCap cap
  h <- restore (openWriteHandle path)
  register rt (Writer h cap True) `onException` hClose h

standardWriter :: Runtime -> Handle -> Int -> IO (Either String Int)
standardWriter rt h cap = attempt (checkCap cap >> register rt (Writer h cap False))

standardReader :: Runtime -> Int -> IO (Either String Int)
standardReader rt cap = attempt $ do
  checkCap cap
  -- The same cell is shared with IO.readLine; read-ahead is never discarded
  -- when a caller switches between the stdin entrypoints.
  modifyMVar_ (inputReader rt) $ \r -> case r of
    Reader h _ pending b -> pure (Reader h cap pending b)
    _ -> failIO "invalid stdin reader"
  modifyMVar (resources rt) $ \(next, table) ->
    pure ((next + 1, IM.insert next (inputReader rt) table), next)

readChunkCell :: MVar Resource -> IO (Maybe BS.ByteString)
readChunkCell cell = modifyMVar cell $ \r -> case r of
  Reader h cap pending b -> do
    bytes <- if BS.null pending then BS.hGetSome h cap else pure (BS.take cap pending)
    let rest = if BS.null pending then BS.empty else BS.drop cap pending
    pure (Reader h cap rest b, if BS.null bytes then Nothing else Just bytes)
  _ -> failIO "expected a byte reader"

readChunk :: Runtime -> Int -> IO (Either String (Maybe BS.ByteString))
readChunk rt key = attempt (getResource rt key >>= readChunkCell)

-- Preserve LF in returned bytes. Blank lines and an unterminated final line
-- are distinguishable from EOF, and byte filters can reproduce exact input.
readLineCell :: Int -> MVar Resource -> IO (Maybe BS.ByteString)
readLineCell limit cell = do
  checkCap limit
  modifyMVar cell $ \r -> case r of
    Reader h cap pending b -> do
      first <- if BS.null pending then BS.hGetSome h (min cap (limit+1)) else pure pending
      (line,rest) <- case BS.elemIndex 10 first of
        Just i -> do
          when (i+1>limit) (failIO "line byte limit exceeded")
          -- A copied small result does not retain an old full input chunk.
          -- The pending view may share that one bounded chunk until consumed.
          pure (BS.copy (BS.take (i+1) first),BS.drop (i+1) first)
        Nothing -> do
          when (BS.length first>limit) (failIO "line byte limit exceeded")
          next <- if BS.null first then pure BS.empty
                  else BS.hGetSome h (min cap (limit-BS.length first+1))
          if BS.null next then pure (BS.copy first,BS.empty)
          else do
            -- Multi-chunk lines use one admitted buffer, avoiding retention of
            -- millions of fragments with a deliberately one-byte read cap.
            (bytes,remaining) <- BSI.createAndTrim' limit $ \buffer -> do
              (size,tailBytes) <- gather h cap buffer 0 (first <> next)
              pure (0,size,tailBytes)
            pure (bytes,remaining)
      pure (Reader h cap rest b, if BS.null line then Nothing else Just line)
    _ -> failIO "expected a byte reader"
  where
    appendAt buffer size bytes = BS.useAsCStringLen bytes $ \(source, n) ->
      when (n > 0) (copyBytes (buffer `plusPtr` size) (castPtr source) n)
    gather h cap buffer size pending =
      case BS.elemIndex 10 pending of
        Just i -> do
          let n = i + 1
          when (size + n > limit) (failIO "line byte limit exceeded")
          appendAt buffer size (BS.take n pending)
          pure (size + n, BS.drop n pending)
        Nothing -> do
          let size' = size + BS.length pending
          when (size' > limit) (failIO "line byte limit exceeded")
          appendAt buffer size pending
          chunk <- BS.hGetSome h (min cap (limit - size' + 1))
          if BS.null chunk
            then pure (size', BS.empty)
            else gather h cap buffer size' chunk

readLineBytes :: Runtime -> Int -> Int -> IO (Either String (Maybe BS.ByteString))
readLineBytes rt limit key = attempt (getResource rt key >>= readLineCell limit)

writeChunk :: Runtime -> BS.ByteString -> Int -> IO (Either String ())
writeChunk rt bytes key = attempt $ do
  cell <- getResource rt key
  withMVar cell $ \r -> case r of
    Writer h cap _ -> do
      when (BS.length bytes > cap) (failIO "write exceeds stream chunk limit")
      BS.hPut h bytes
      hFlush h
    _ -> failIO "expected a byte writer"

closeStream :: Runtime -> Int -> IO (Either String ())
closeStream rt key = attempt $ mask_ $ do
  cell <- modifyMVar (resources rt) $ \(next, table) -> case IM.lookup key table of
    Nothing -> failIO "closed or foreign stream"
    Just c -> pure ((next, IM.delete key table), c)
  resource <- readMVar cell
  if owned resource then hClose (resourceHandle resource)
  else case resource of Writer h _ _ -> hFlush h; _ -> pure ()

encodeUtf8 :: String -> Either String BS.ByteString
encodeUtf8 s
  | any (\c -> ord c >= 0xD800 && ord c <= 0xDFFF) s = Left "UTF-8 encode: surrogate is not a Unicode scalar"
  | otherwise = Right (TE.encodeUtf8 (T.pack s))

decodeUtf8 :: BS.ByteString -> Either String String
decodeUtf8 = either (Left . show) (Right . T.unpack) . TE.decodeUtf8'

decodeReplace :: BS.ByteString -> String
decodeReplace = T.unpack . TE.decodeUtf8With lenientDecode

-- At most three incomplete bytes carry across a boundary. Invalid partial
-- prefixes are decoded now (and rejected or replaced), never retained.
utf8Chunk :: Bool -> BS.ByteString -> BS.ByteString -> Bool -> Either String (String, BS.ByteString)
utf8Chunk replace carry chunk final
  | BS.length carry > 3 = Left "UTF-8 carry must contain at most three bytes"
  | otherwise = do
      let bytes = carry <> chunk
          (prefix, rest) = if final then (bytes, BS.empty) else splitIncomplete bytes
      text <- if replace then Right (decodeReplace prefix) else decodeUtf8 prefix
      pure (text, BS.copy rest)

splitIncomplete :: BS.ByteString -> (BS.ByteString, BS.ByteString)
splitIncomplete bytes =
  case [i | i <- [max 0 (BS.length bytes - 3)..BS.length bytes - 1], incomplete (BS.drop i bytes)] of
    i : _ -> BS.splitAt i bytes
    [] -> (bytes, BS.empty)
  where
    incomplete bs = case BS.unpack bs of
      [] -> False
      xs@(lead : tailBytes) -> let
                        width | lead >= 0xC2 && lead <= 0xDF = 2
                              | lead >= 0xE0 && lead <= 0xEF = 3
                              | lead >= 0xF0 && lead <= 0xF4 = 4
                              | otherwise = 0
                        secondOK = case tailBytes of
                          [] -> True
                          x : _ -> (lead /= 0xE0 || x >= 0xA0) && (lead /= 0xED || x < 0xA0)
                            && (lead /= 0xF0 || x >= 0x90) && (lead /= 0xF4 || x < 0x90)
                    in width > length xs && all (\x -> x >= 0x80 && x <= 0xBF) tailBytes && secondOK

writeExact :: Handle -> BS.ByteString -> IO (Either String ())
writeExact h bytes = attempt (BS.hPut h bytes >> hFlush h)

readTextLine :: Runtime -> Int -> IO (Either String (Maybe String))
readTextLine rt limit = do
  r <- attempt (readLineCell limit (inputReader rt))
  pure $ r >>= traverse (decodeUtf8 . stripLF)
  where stripLF b = if not (BS.null b) && BS.last b == 10 then BS.init b else b

environmentGet :: String -> IO (Either String (Maybe String))
environmentGet key = attempt $ do
  when (null key || any (`elem` "=\0") key) (failIO "invalid environment name")
  Env.lookupEnv key

environmentSet :: Runtime -> String -> Maybe String -> IO (Either String ())
environmentSet rt key value = attempt $ mask_ $ modifyMVar_ (originalEnv rt) $ \original -> do
  when (null key || any (`elem` "=\0") key) (failIO "invalid environment name")
  when (maybe False (elem '\0') value) (failIO "environment value contains NUL")
  old <- Env.lookupEnv key
  maybe (Env.unsetEnv key) (Env.setEnv key) value
  pure (M.insertWith (\_ earlier -> earlier) key old original)

cwd :: IO (Either String FilePath)
cwd = attempt getCurrentDirectory

requestExit :: Int -> IO a
requestExit n
  | n >= 0 && n <= 255 = throwIO (ScriptExit n)
  | otherwise = failIO "exit status must be 0..255"

requestAbort :: Int -> IO a
requestAbort n
  | n >= 1 && n <= 255 = throwIO (ScriptAbort n)
  | otherwise = failIO "abort status must be 1..255"

-- Direct copy exposes its new destination during copying, removes it on
-- failure/cancellation, and never overwrites. Publication stages beside the
-- destination and publishes only a completely flushed copy.
copyNow :: FilePath -> FilePath -> Int -> IO (Either IOException Integer)
copyNow source target cap = try $ do
  checkCap cap
  bracket (openReadHandle source) hClose $ \input -> mask $ \restore -> do
    (output, created) <- openWriteHandleOwned target
    (restore (copyHandles input output cap) `finally` hClose output)
      `onException` removeOwned target created

-- A competing publisher may have replaced the destination while the old
-- inode was still being copied. Never remove an observed foreign replacement
-- as cancellation cleanup. Non-cooperating writers retain the POSIX window
-- between this identity check and unlink, as with other path-based policies.
removeOwned :: FilePath -> PF.FileStatus -> IO ()
removeOwned path created = do
  now <- optionalStatus path
  case now of
    Nothing -> pure ()
    Just st | PF.deviceID st == PF.deviceID created && PF.fileID st == PF.fileID created -> removeFile path
    _ -> hPutStrLn stderr ("[sol] copy cleanup preserved a foreign replacement at " ++ path)

copyHandles :: Handle -> Handle -> Int -> IO Integer
copyHandles input output cap = loop 0
  where
    loop !count = do
      bytes <- BS.hGetSome input cap
      if BS.null bytes then hFlush output >> pure count
      else BS.hPut output bytes >> loop (count + fromIntegral (BS.length bytes))

copyPublishNow :: FilePath -> FilePath -> Int -> Bool -> IO (Either IOException Integer)
copyPublishNow source target cap replace = try $ do
  checkCap cap
  checkPath target
  -- Resolve the target's directory, not its leaf. Rename/link publication
  -- never writes through a destination leaf symlink.
  let parent = takeDirectory target
  bracket (openReadHandle source) hClose $ \input ->
    bracket (PT.mkstemp (parent </> ".sol-stage-")) cleanup $ \(stage, output) -> do
      total <- copyHandles input output cap
      hClose output
      if replace then do
        old <- optionalStatus target
        forM_ old $ \st -> do
          when (PF.isSymbolicLink st || not (PF.isRegularFile st)) (failIO "replacement requires a regular non-symlink destination")
          PF.setFileMode stage (PF.fileMode st `mod` 0o1000)
        renameFile stage target
      else PF.createLink stage target
      pure total
  where
    cleanup (stage, h) = hClose h `finally` (removeFile stage `catch` \e ->
      unless (isDoesNotExistError e) (throwIO (e :: IOException)))

optionalStatus :: FilePath -> IO (Maybe PF.FileStatus)
optionalStatus path = (Just <$> PF.getSymbolicLinkStatus path) `catch` \e ->
  if isDoesNotExistError e then pure Nothing else throwIO (e :: IOException)

foreign import ccall safe "sol_rename_now" cRenameNow :: CString -> CString -> CInt -> IO CInt

renameNow :: FilePath -> FilePath -> Bool -> IO (Either IOException ())
renameNow source target replace = try $ do
  checkPath source
  checkPath target
  src <- PF.getSymbolicLinkStatus source
  unless (PF.isRegularFile src || PF.isDirectory src) (failIO "rename source must be a non-symlink file or directory")
  when replace $ do
    old <- optionalStatus target
    forM_ old $ \st -> unless (PF.isRegularFile st || PF.isDirectory st)
      (failIO "rename replacement requires a non-symlink file or directory")
  -- Both paths are encoded explicitly; NUL is never silently truncated by FFI.
  when (any (elem '\0') [source, target]) (failIO "rename path contains NUL")
  a <- either failIO pure (encodeUtf8 source)
  b <- either failIO pure (encodeUtf8 target)
  code <- BS.useAsCString a $ \pa -> BS.useAsCString b $ \pb -> cRenameNow pa pb (if replace then 1 else 0)
  when (code /= 0) $ ioError (errnoToIOError "renameNow" (Errno code) Nothing (Just target))
