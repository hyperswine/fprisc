-- Host module publication is separate from source versioning: readers never
-- learn about an image until its build and atomic install have completed.
module Publish (publishMain, watchMain) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, catch)
import Control.Monad (unless, when)
import Codegen (codegenRev)
import Data.Char (isAlphaNum)
import Data.IORef (newIORef)
import qualified Data.Map.Strict as M
import Modules (loadModule, muHash)
import qualified Data.ByteString as B
import Data.List (intercalate)
import System.Directory
import System.Environment (getExecutablePath)
import System.Exit
import System.FilePath
import System.Info (os, arch)
import System.IO
import System.Process (rawSystem)

failWith :: String -> IO a
failWith s = hPutStrLn stderr s >> exitFailure

readExisting :: FilePath -> IO String
readExisting p = do
  present <- doesFileExist p
  if present then do s <- readFile p; length s `seq` pure s else pure ""

publishMain :: [String] -> IO ()
publishMain args = case args of
  [source] -> do
    let name = takeBaseName source
    when (null name || any (\c -> not (isAlphaNum c || c `elem` "_-")) name) $ failWith "publish: invalid module name"
    createDirectoryIfMissing True ".fpr"
    -- One writer for source versions, image install and journal snapshot.
    -- A crash leaves the lock for deliberate recovery, never silent stealing.
    bracket ((createDirectory ".fpr/publication.lock" `catch` lockError))
            (const $ removeDirectory ".fpr/publication.lock") $ \_ -> publish source name
  _ -> failWith "usage: fpr publish <module.fpr>"
  where
    lockError :: IOException -> IO ()
    lockError e = failWith ("publish: cannot acquire .fpr/publication.lock (another publisher or stale lock): " ++ show e)

publish :: FilePath -> String -> IO ()
publish source name = do
  exe <- getExecutablePath
  ec <- rawSystem exe ["commit", source]
  unless (ec == ExitSuccess) $ exitWith ec
  db <- readExisting ".fpr/versions.db"
  (version, hash) <- case reverse [(v,h) | l <- lines db, [n,v,h] <- [words l], n == name] of
    x : _ -> pure x
    [] -> failWith "publish: commit produced no binding"
  cache <- newIORef M.empty
  frozen <- loadModule cache [] (".fpr/store" </> (hash ++ ".fpr"))
  case frozen of
    Right unit | muHash unit == hash -> pure ()
    _ -> failWith "publish: committed source identity mismatch"
  root <- makeAbsolute ".fpr/store"
  let target = os ++ "-" ++ arch ++ "-cg" ++ show codegenRev
      image = root </> (hash ++ "." ++ target ++ if os == "darwin" then ".dylib" else ".so")
      ledger = ".fpr/publications." ++ target ++ ".tsv"
  when (any (`elem` "\t\r\n") image) $ failWith "publish: store path contains a journal delimiter"
  history <- readExisting ledger
  let rows = [fields | line <- lines history, let fields = splitTabs line, length fields == 5]
      mine = [r | r@(n:_) <- rows, n == name]
      previous = case reverse mine of (_:_:_:h:_:[]) : _ -> h; _ -> ""
  unless (length rows == length (lines history) && all validRow rows) $ failWith "publish: malformed publication journal"
  exists <- doesFileExist image
  unless exists $ do
    -- Build the frozen blob, not the mutable scratch source. Temp image lives
    -- on the same filesystem; failed builds never touch the ledger.
    bracket (openTempFile root ".module-build")
            (\(p,h) -> hClose h `catch` ignore >> removeIfPresent p) $ \(tmp,h) -> do
      hClose h
      result <- rawSystem exe ["build", root </> (hash ++ ".fpr"), "--module", "-o", tmp]
      unless (result == ExitSuccess) $ exitWith result
      renameFile tmp image
  unless (previous == hash) $ atomicWrite ledger (history ++ intercalate "\t" [name,version,previous,hash,image] ++ "\n")
  -- The host-specific journal avoids mixing incompatible target artifacts.
  putStrLn ("published " ++ name ++ "." ++ version ++ "#" ++ hash ++ " " ++ image ++ " journal=" ++ ledger)
  hFlush stdout
  where
    ignore :: IOException -> IO ()
    ignore _ = pure ()

removeIfPresent :: FilePath -> IO ()
removeIfPresent p = do b <- doesFileExist p; when b $ removeFile p

atomicWrite :: FilePath -> String -> IO ()
atomicWrite path contents = bracket (openTempFile (takeDirectory path) ".publication")
  (\(p,h) -> (hClose h `catch` ignore) >> removeIfPresent p) $ \(p,h) -> do
    hPutStr h contents
    hClose h
    renameFile p path
  where
    ignore :: IOException -> IO ()
    ignore _ = pure ()

validRow :: [String] -> Bool
validRow [n,v,_,h,p] = all (not . null) [n,v,h,p]
validRow _ = False

splitTabs :: String -> [String]
splitTabs s = case break (== '\t') s of (a,[]) -> [a]; (a,_:r) -> a : splitTabs r

watchMain :: [String] -> IO ()
watchMain args = case args of
  [source, "--once"] -> publishMain [source]
  [source] -> do
    exe <- getExecutablePath
    let loop previous = do
          current <- (Just <$> B.readFile source) `catch` unreadable
          when (current /= previous && current /= Nothing) $ do
            result <- rawSystem exe ["publish",source]
            unless (result == ExitSuccess) $ hPutStrLn stderr "watch: publication refused; previous image remains current"
          threadDelay 300000
          loop current
    loop Nothing
  _ -> failWith "usage: fpr watch <module.fpr> [--once] (publish host modules on source changes)"
  where
    unreadable :: IOException -> IO (Maybe B.ByteString)
    unreadable e = hPutStrLn stderr ("watch: " ++ show e) >> pure Nothing
