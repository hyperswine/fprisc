-- Host module publication is separate from source versioning: readers never
-- learn about an image until its build and atomic install have completed.
module Publish (publishMain, watchMain) where

import Control.Concurrent (threadDelay, myThreadId, throwTo)
import Control.Exception (IOException, AsyncException(UserInterrupt), bracket, catch)
import Control.Monad (unless, when)
import Codegen (codegenRev)
import Data.Char (isAlphaNum)
import Data.IORef (newIORef)
import qualified Data.Map.Strict as M
import Modules (loadModule, muHash)
import qualified Data.ByteString as B
import Data.List (intercalate)
import System.Directory
import System.Environment (getExecutablePath, getEnvironment)
import System.Exit
import System.FilePath
import System.Info (os, arch)
import System.IO
import System.Process (rawSystem, proc, createProcess, CreateProcess(..), getProcessExitCode, waitForProcess, getPid, ProcessHandle)
import System.Posix.Signals (installHandler, Handler(Catch), sigTERM, signalProcessGroup)

failWith :: String -> IO a
failWith s = hPutStrLn stderr s >> exitFailure

readExisting :: FilePath -> IO String
readExisting p = do
  present <- doesFileExist p
  if present then do s <- readFile p; length s `seq` pure s else pure ""

validName :: String -> Bool
validName name = not (null name) && all (\c -> isAlphaNum c || c `elem` "_-") name

withPublisher :: IO a -> IO a
withPublisher action = do
  createDirectoryIfMissing True ".fpr"
  bracket (createDirectory ".fpr/publication.lock" `catch` lockError)
          (const $ removeDirectory ".fpr/publication.lock") (const action)
  where
    lockError :: IOException -> IO ()
    lockError e = failWith ("publish: cannot acquire .fpr/publication.lock (another publisher or stale lock): " ++ show e)

latestBinding :: String -> IO (String, String)
latestBinding name = do
  db <- readExisting ".fpr/versions.db"
  case reverse [(v,h) | l <- lines db, [n,v,h] <- [words l], n == name] of
    x : _ -> pure x
    [] -> failWith ("publish: no committed binding for " ++ name)

publishMain :: [String] -> IO ()
publishMain args = case args of
  ["--stored", name] -> do
    unless (validName name) $ failWith "publish: invalid module name"
    withPublisher $ do
      (version, hash) <- latestBinding name
      publishBinding name version hash
  [source] -> do
    let name = takeBaseName source
    unless (validName name) $ failWith "publish: invalid module name"
    withPublisher $ do
      exe <- getExecutablePath
      ec <- rawSystem exe ["commit", source]
      unless (ec == ExitSuccess) $ exitWith ec
      (version, hash) <- latestBinding name
      publishBinding name version hash
  _ -> failWith "usage: fpr publish <module.fpr> | --stored <name>"

publishBinding :: String -> String -> String -> IO ()
publishBinding name version hash = do
  exe <- getExecutablePath
  unless (length hash == 16 && all (`elem` "0123456789abcdef") hash) $ failWith "publish: invalid committed hash"
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
  source : "--module" : rest -> case moduleNames (filter (/= "--restart-on-change") rest) of
    Just names | not (null names) -> watchApp source names ("--restart-on-change" `elem` rest)
    _ -> failWith watchUsage
  _ -> failWith watchUsage
  where
    unreadable :: IOException -> IO (Maybe B.ByteString)
    unreadable e = hPutStrLn stderr ("watch: " ++ show e) >> pure Nothing

watchUsage :: String
watchUsage = "usage: fpr watch <module.fpr> [--once] | <app.fpr> --module <name> [--module <name> ...] [--restart-on-change]"

moduleNames :: [String] -> Maybe [String]
moduleNames [name] | validName name = Just [name]
moduleNames (name : "--module" : rest) | validName name = (name :) <$> moduleNames rest
moduleNames _ = Nothing

-- Explicit logical subscriptions; pinned static imports are never rewritten.
-- Commits store checked source. This supervisor turns those bindings into ready
-- host publications while the app owns notification delivery and adoption.
watchApp :: FilePath -> [String] -> Bool -> IO ()
watchApp source names restart = do
  tid <- myThreadId
  bracket (installHandler sigTERM (Catch (throwTo tid UserInterrupt)) Nothing)
          (\old -> installHandler sigTERM old Nothing >> pure ()) $
          const (watchAppBody source names restart)

-- Each compiler/app subprocess gets an owned process group so interruption
-- also stops compiler/linker descendants, including during startup.
stopChild :: ProcessHandle -> IO ()
stopChild child = do
  pid <- getPid child
  case pid of
    Just p -> signalProcessGroup sigTERM p `catch` ignore
    Nothing -> pure ()
  _ <- waitForProcess child
  pure ()
  where
    ignore :: IOException -> IO ()
    ignore _ = pure ()

runOwned :: FilePath -> [String] -> IO ExitCode
runOwned exe args = bracket (createProcess (proc exe args) {create_group = True})
  (\(_,_,_,child) -> stopChild child) (\(_,_,_,child) -> waitForProcess child)

watchAppBody :: FilePath -> [String] -> Bool -> IO ()
watchAppBody source names restart = do
  exe <- getExecutablePath
  mapM_ (\name -> do
    ec <- runOwned exe ["publish", "--stored", name]
    unless (ec == ExitSuccess) $ exitWith ec) names
  journal <- makeAbsolute (".fpr/publications." ++ os ++ "-" ++ arch ++ "-cg" ++ show codegenRev ++ ".tsv")
  root <- makeAbsolute ".fpr"
  bracket (openTempFile root ".watch-app")
          (\(path,h) -> hClose h `catch` ignore >> removeIfPresent path) $ \(path,h) -> do
    hClose h
    original <- B.readFile source
    ec <- runOwned exe ["build",source,"-o",path]
    unless (ec == ExitSuccess) $ exitWith ec
    environment <- getEnvironment
    let launch sourceBytes = do
          outcome <- bracket (createProcess (proc path []) {env = Just (("FPR_RELOAD_JOURNAL",journal) : filter ((/= "FPR_RELOAD_JOURNAL") . fst) environment), create_group = True})
            (\(_,_,_,child) -> stopChild child) $ \(_,_,_,child) -> do
              pid <- getPid child
              putStrLn ("watch: app pid=" ++ maybe "unknown" show pid)
              hFlush stdout
              let loop previous checked = getProcessExitCode child >>= \status -> case status of
                    Just code -> pure (Left code)
                    Nothing -> do
                      db <- readExisting ".fpr/versions.db"
                      next <- mapM (update exe db previous) names
                      current <- (Just <$> B.readFile source) `catch` unreadable
                      case current of
                        Just bytes | restart && bytes /= checked -> do
                          rebuilt <- rebuild exe root source path
                          if rebuilt then pure (Right bytes) else threadDelay 300000 >> loop next bytes
                        _ -> threadDelay 300000 >> loop next checked
              loop [] sourceBytes
          case outcome of
            Left code -> exitWith code
            Right bytes -> do
              putStrLn "watch: restarting app after checked root change (model resets)"
              hFlush stdout
              launch bytes
    launch original
  where
    ignore :: IOException -> IO ()
    ignore _ = pure ()
    unreadable :: IOException -> IO (Maybe B.ByteString)
    unreadable e = hPutStrLn stderr ("watch: " ++ show e) >> pure Nothing
    rebuild exe root source path = bracket (openTempFile root ".watch-restart")
      (\(tmp,h) -> hClose h `catch` ignore >> removeIfPresent tmp) $ \(tmp,h) -> do
        hClose h
        ec <- runOwned exe ["build",source,"-o",tmp]
        if ec == ExitSuccess then renameFile tmp path >> pure True else do
          hPutStrLn stderr "watch: app rebuild refused; running app remains current"
          pure False
    update exe db previous name =
      case reverse [h | l <- lines db, [n,_,h] <- [words l], n == name] of
        [] -> pure (name, maybe Nothing id (lookup name previous))
        hash : _ | lookup name previous == Just (Just hash) -> pure (name, Just hash)
        hash : _ -> do
          ec <- runOwned exe ["publish","--stored",name]
          unless (ec == ExitSuccess) $ hPutStrLn stderr ("watch: publication refused for " ++ name ++ "; retrying committed version")
          pure (name, if ec == ExitSuccess then Just hash else maybe Nothing id (lookup name previous))
