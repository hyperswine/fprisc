{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

-- A disposable compiler-result cache, never a cache of evaluated values or
-- effects. Imports are resolved before lookup. Exact encoded inputs are checked
-- after the filename hash, so hash collisions cannot select a different program.
module Sol.Cache (Prepared (..), cached) where

import Control.DeepSeq (NFData, force)
import Control.Exception (IOException, bracketOnError, catch, evaluate)
import Control.Monad (when)
import Data.Binary (Binary, decodeOrFail, encode)
import Data.Bits (xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric (showHex)
import System.Directory (XdgDirectory (XdgCache), createDirectoryIfMissing, getXdgDirectory, makeAbsolute, removeFile, renameFile)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>), takeDirectory)
import System.Info (arch, os, compilerName, compilerVersion)
import System.IO (hClose, openBinaryTempFile)
import System.Posix.Files (deviceID, fileID, fileSize, getFileStatus, modificationTimeHiRes, statusChangeTimeHiRes)
import Sol.Bytecode (BProg)
import Sol.Diagnostic (diagnostic)
import Sol.Lang (Name, Prog, STop)
import Sol.Startup (phase)

data Prepared = Prepared
  { preparedCons :: M.Map Name (Int, Int, Int),
    preparedShapes :: M.Map [Name] Int,
    preparedCore :: Prog,
    preparedCode :: BProg,
    preparedRuns :: [Name],
    preparedNotes :: [String]
  } deriving (Generic, NFData, Binary)

-- Changing the artifact format/meaning requires a new schema, even though a
-- rebuilt executable normally also invalidates all entries through its identity.
schema :: Int
schema = 1

fingerprint :: BS.ByteString -> Word64
fingerprint = BS.foldl' (\h b -> (h `xor` fromIntegral b) * 0x100000001b3) 0xcbf29ce484222325

traceCache :: String -> IO ()
traceCache msg = do
  enabled <- (== Just "1") <$> lookupEnv "SOL_CACHE_TRACE"
  when enabled (diagnostic ("[sol cache] " ++ msg))

ignoreIO :: IO () -> IO ()
ignoreIO action = action `catch` (\(_ :: IOException) -> pure ())

-- Stat identity avoids reading/hash-scanning the entire executable on every
-- tiny invocation. Replacement/rebuild changes inode, size, mtime or ctime;
-- compiler/runtime ABI and schema are also part of the exact input key.
cached :: FilePath -> String -> String -> [STop] -> IO Prepared -> IO Prepared
cached path src prelude expanded compile = do
  flag <- lookupEnv "SOL_CACHE"
  inspect <- mapM lookupEnv ["SOL_TYPES", "SOL_WIDTHS"]
  if flag == Just "0" || Just "1" `elem` inspect
    then traceCache "disabled" >> compile
    else do
      context <- cacheContext `catch` (\(_ :: IOException) -> pure Nothing)
      case context of
        Nothing -> traceCache "unavailable" >> compile
        Just (file, key) -> do
          hit <- phase "cache-read" (readEntry file key)
          case hit of
            Just prepared -> do
              traceCache "hit"
              mapM_ diagnostic (preparedNotes prepared)
              pure prepared
            Nothing -> do
              traceCache "miss"
              prepared <- compile
              phase "cache-write" (writeEntry file key prepared)
              pure prepared
  where
    cacheContext = do
      exe <- getExecutablePath >>= makeAbsolute
      st <- getFileStatus exe
      absolute <- makeAbsolute path
      options <- mapM lookupEnv ["SOL_NOTYPES", "SOL_NO_SAFETY", "FPR_HOME", "FPR_PATH"]
      let identity = show (exe, deviceID st, fileID st, fileSize st, modificationTimeHiRes st, statusChangeTimeHiRes st)
          key = BL.toStrict (encode (schema, identity, (arch, os, compilerName, show compilerVersion), absolute, path, src, prelude, expanded, options))
          slot = showHex (fingerprint (BL.toStrict (encode (identity, absolute)))) "" ++ ".cache"
      dir <- lookupEnv "SOL_CACHE_DIR" >>= maybe (getXdgDirectory XdgCache "fpr/sol") pure
      pure (Just (dir </> slot, key))

-- Entries are private local build products. This checksum detects accidental
-- corruption, not deliberate rewriting by an attacker who owns the cache.
magic :: BS.ByteString
magic = BS.pack [70,80,82,83,79,76,49,10]

maxEntryBytes :: Int
maxEntryBytes = 64 * 1024 * 1024

readEntry :: FilePath -> BS.ByteString -> IO (Maybe Prepared)
readEntry file key = readIt `catch` (\(_ :: IOException) -> pure Nothing)
  where
    readIt = do
      st <- getFileStatus file
      if fileSize st > fromIntegral maxEntryBytes then pure Nothing else do
        bytes <- BS.readFile file
        let (header, rest) = BS.splitAt 8 bytes
            (sumBytes, payload) = BS.splitAt 8 rest
        if header /= magic || BS.length sumBytes /= 8 || BS.length bytes > maxEntryBytes
          then pure Nothing
          else case decodeOrFail (BL.fromStrict sumBytes) of
            Right (_, _, checksum) | checksum == fingerprint payload ->
              case decodeOrFail (BL.fromStrict payload) of
                Right (remaining, _, (savedKey, prepared))
                  | BL.null remaining && savedKey == key -> Just <$> evaluate (force prepared)
                _ -> pure Nothing
            _ -> pure Nothing

writeEntry :: FilePath -> BS.ByteString -> Prepared -> IO ()
writeEntry file key prepared = writeIt `catch` (\(_ :: IOException) -> traceCache "write unavailable")
  where
    writeIt = do
      let payload = BL.toStrict (encode (key, prepared))
          bytes = magic <> BL.toStrict (encode (fingerprint payload)) <> payload
      if BS.length bytes > maxEntryBytes then traceCache "entry too large" else do
        let dir = takeDirectory file
        createDirectoryIfMissing True dir
        bracketOnError (openBinaryTempFile dir ".sol-cache-")
          (\(tmp, h) -> ignoreIO (hClose h) >> ignoreIO (removeFile tmp))
          (\(tmp, h) -> BS.hPut h bytes >> hClose h >> renameFile tmp file)
