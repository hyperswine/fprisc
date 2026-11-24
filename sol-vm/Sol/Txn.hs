{-# LANGUAGE TupleSections, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Txn.hs -- the commit protocol that publishes a TxnState: locks, the redo
-- journal and its recovery, the Git saga, realtime escapes, process
-- plumbing, and the commit itself (validate under lock, journal, replay,
-- unlock). The transaction's state and filesystem layer lives in
-- Sol.TxnState (one-way import, no cycles).

module Sol.Txn (module Sol.Txn, module Sol.TxnState, module Sol.Escapes, module Sol.Effects) where

import Sol.Diagnostic (diagnostic)
import Sol.Native
import qualified Sol.Digest as Digest
import Sol.Effects
import qualified Sol.ScriptIO as ScriptIO
import qualified Sol.Process as Process
import Data.Bits ((.&.))
import Data.Unique (Unique, newUnique)
import Control.Concurrent (ThreadId, myThreadId, threadDelay, forkIOWithUnmask, killThread, newEmptyMVar, putMVar, takeMVar, newChan, writeChan, readChan)
import Control.Exception (SomeException, bracket, catch, IOException, finally, mask, mask_, onException, throwIO, try)
import Control.Monad (foldM, forM_, unless, when)
import Data.IORef
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import System.Environment (getEnvironment, lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.UTF8 as BSU
import qualified Data.IntMap.Strict as IM
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Directory
  ( canonicalizePath, makeAbsolute, getCurrentDirectory,
    createDirectory,
    createDirectoryIfMissing,
    getHomeDirectory,
    doesDirectoryExist,
    doesFileExist,
    getTemporaryDirectory,
    listDirectory,
    removeDirectory,
    removeFile,
    removePathForcibly,
    renamePath,
  )
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, hasTrailingPathSeparator, dropTrailingPathSeparator, (</>))
import System.IO (readFile', openTempFile, hClose, hIsTerminalDevice, openBinaryFile, IOMode(ReadMode))
import System.IO.Error (ioeGetErrorType, isAlreadyExistsError, isDoesNotExistError, isResourceVanishedError)
import Foreign.C.Error (Errno (..), eACCES, eEXIST, eXDEV, eISDIR, eLOOP, eMLINK, eNOENT, eNOTDIR, ePERM)
import GHC.IO.Exception (IOException (..), IOErrorType (..))
import System.IO (hFlush, hGetContents', hIsEOF, hGetLine, stderr, stdin, stdout, hPutStr, hPutStrLn)
import System.Process (CreateProcess (..), StdStream (..), getPid, terminateProcess, createProcess, proc, waitForProcess)
import System.Timeout (timeout)
import qualified System.Posix.Files as PF
import qualified System.Posix.Directory.ByteString as PDB
import qualified System.Posix.Temp as PT
import System.Posix.Signals (signalProcessGroup, sigKILL, sigCONT, sigTTOU, blockSignals, getSignalMask, setSignalMask, addSignal, emptySignalSet)
import System.Posix.Terminal (getTerminalProcessGroupID, setTerminalProcessGroupID)
import System.Posix.Process (getProcessGroupID)
import System.Posix.User (getEffectiveUserID)
import System.Posix.IO (stdInput)
import System.Posix.Types (ProcessGroupID)

-- the state and filesystem layer this protocol publishes
import Sol.TxnState

import Sol.Escapes

-- ---- commit protocol ------------------------------------------------------
--
-- CRASH-ATOMIC edition. The previous protocol was atomic against script
-- errors and concurrent sol processes, but a crash (kill -9, OOM, power
-- loss) DURING commit could tear it three ways: a half-written file, a
-- half-applied effect log, and stranded .sol-lock dirs that hard-fail
-- every later run. Three mechanisms close those, in order:
--
--   1. writeAtomic: every committed file lands under a temp name, is
--      fsynced, and is renamed over the target. rename(2) is atomic on
--      POSIX, so an individual file is always entirely-old or
--      entirely-new — never torn.
--   2. the REDO JOURNAL: after validation and before any disk mutation,
--      the whole effect log is serialized to <script>.soljournal and
--      fsynced (itself via writeAtomic, so the journal is complete or
--      absent). A crash mid-replay leaves the journal as the authority:
--      the next run (of this script, or any sol that reclaims one of the
--      dead process's locks) REDOES it. File effects are idempotent
--      (absolute content, rename-applied), so redo is safe to repeat.
--      Deferred shell commands are not idempotent; each one that runs is
--      marked in <journal>.done (append + fsync) and redo skips marked
--      ones. The crash window between a command finishing and its marker
--      landing means shell redo is AT-LEAST-ONCE — stated here rather
--      than hidden, and narrower than the every-crash re-run it replaces.
--   3. PID-stamped locks: a lock dir carries an owner file (pid +
--      journal path). acquire probes a contended lock's owner with
--      kill(pid, 0); a dead owner's lock is reclaimed by atomically
--      RENAMING the lock dir (one reclaimer wins the rename, losers keep
--      spinning), finishing the dead owner's journal first if one exists.
--      No daemon, no manual cleanup, and a crashed sol no longer wedges
--      every future run on those paths.
--
-- Honest limits, so nobody reads more than is there: fsync is
-- best-effort (some filesystems lie; we do not detect that); concurrent
-- reclaimers can both redo the same journal (file effects idempotent,
-- shell effects at-least-once as above); and a redo that races a live
-- writer on an UNLOCKED path is possible only if that writer ignores
-- locks — sol processes never do.

foreign import ccall unsafe "sol_fsync_path" c_fsyncPath :: CString -> IO CInt
foreign import ccall unsafe "sol_pid_alive" c_pidAlive :: CInt -> IO CInt
foreign import ccall unsafe "sol_getpid" c_getpid :: IO CInt
foreign import ccall unsafe "sol_hard_exit" c_hardExit :: CInt -> IO ()

-- SOL_NOSYNC=1 skips every fsync: writes stay rename-atomic (no torn
-- files, and the journal still heals a killed process), but a POWER LOSS
-- can lose "committed" data. For bulk jobs on a filesystem you trust,
-- the fsync tax (~2 syncs per committed file) is the dominant cost.
{-# NOINLINE noSync #-}
noSync :: Bool
noSync = unsafePerformIO (maybe False (/= "0") <$> lookupEnv "SOL_NOSYNC")

fsyncPath :: FilePath -> IO ()
fsyncPath p = unless noSync (withCString p (fmap (const ()) . c_fsyncPath))

parentOf :: FilePath -> FilePath
parentOf p = case reverse (dropWhile (/= '/') (reverse p)) of
  "" -> "."
  q -> q

-- entirely-old or entirely-new, never torn; durable once we return
writeAtomic :: FilePath -> String -> IO ()
writeAtomic p v = do
  -- Refuse symlinks explicitly: writing through them needs referent locks
  -- and snapshots, not a rename under the link's transaction key.
  status <- (Just <$> PF.getSymbolicLinkStatus p) `catch` \e ->
    if isDoesNotExistError e then pure Nothing else throwIO (e :: IOException)
  when (maybe False PF.isSymbolicLink status) $
    ioError (userError ("writeAtomic: refusing symbolic link: " ++ p))
  let tmp = p ++ ".sol-tmp"
      clean = removeFile tmp `catch` (\(_ :: IOException) -> pure ())
  (do
    writeFile tmp v
    forM_ status (PF.setFileMode tmp . PF.fileMode)
    fsyncPath tmp
    renamePath tmp p
    fsyncPath (parentOf p)) `onException` clean

-- One compensable Git commit per attempt. The immutable commit object is
-- prepared first; the old/new reference token is durable before its CAS.
-- No relative reset or worktree/index rewrite is used for compensation.
txSetSagaJournal :: IORef TxState -> FilePath -> IO ()
txSetSagaJournal ref path = do
  absolute <- makeAbsolute path
  atomicModifyIORef' ref (\s -> (s {txSagaJournal=Just absolute},()))


txGitCommitNow :: IORef TxState -> Integer -> FilePath -> String -> String -> String -> IO (Either String String)
txGitCommitNow ref limit path name email message = do
  state <- readIORef ref
  if limit < 256 || txSealed state || not (null (txEffects state)) || txPivot state || txSaga state /= Nothing
    then pure (Left "Git.commitNow requires no pending effects/pivot and permits one compensable commit per attempt")
    else case txSagaJournal state of
      Nothing -> pure (Left "Git.commitNow has no transaction journal context")
      Just j -> do
        absolute <- canonicalizePath path
        withLocks (acquire (undoPath j)) [absolute] $ mask_ $ do
          prepared <- nativeGit (GitRequest absolute 17 message name email [] limit)
          case prepared of
            Left why -> pure (Left why)
            Right text -> case lines text of
              [branch,old,new] -> do
                let token=GitUndo absolute branch old new limit
                writeAtomic (undoPath j) (encodeUndo (UndoRecord j False token))
                atomicModifyIORef' ref (\s -> (s {txSaga=Just token},()))
                sagaCrash "prepared"
                published <- nativeGit (GitRequest absolute 18 branch "" "" [new,old] limit)
                sagaCrash "published"
                case published of
                  Right _ -> pure (Right new)
                  Left why -> do
                    undone <- nativeGit (GitRequest absolute 19 branch "" "" [old,new] limit)
                    either (ioError . userError . ("failed commit could not be compensated: " ++)) (const (pure ())) undone
                    removeFile (undoPath j)
                    fsyncPath (parentOf j)
                    atomicModifyIORef' ref (\s -> (s {txSaga=Nothing},()))
                    pure (Left why)
              _ -> pure (Left "invalid native commit preparation result")

sagaCrash :: String -> IO ()
sagaCrash phase = do
  enabled <- lookupEnv "SOL_SAGA_CRASH_AT"
  when (enabled == Just phase) (hFlush stderr >> c_hardExit 137)

-- A redo journal is the commit point. The undo marker must become committed
-- before that redo journal is cleared, so a later recovery cannot undo a
-- transaction that already finished. An existing redo bridges a crash in
-- between the two durable writes.
commitSaga :: IORef TxState -> FilePath -> IO ()
commitSaga ref j = do
  state <- readIORef ref
  absolute <- makeAbsolute j
  forM_ (txSaga state) $ \token -> writeAtomic (undoPath absolute) (encodeUndo (UndoRecord absolute True token))

rollbackSaga :: IORef TxState -> IO ()
rollbackSaga ref = do
  state <- readIORef ref
  forM_ (txSagaJournal state) $ \j -> do
    anchored <- doesFileExist j
    -- A commit failure leaves live-owner file locks fenced. Do not try to
    -- reacquire them here: startup/dead-owner recovery will finish the redo.
    unless anchored (recoverUndo True (undoPath j))

recoverUndo :: Bool -> FilePath -> IO ()
recoverUndo takeLocks path = do
  exists <- doesFileExist path
  when exists $ do
    initial <- readRecord
    let UndoRecord _ _ (GitUndo repo _ _ _ _) = initial
        decide = do
          still <- doesFileExist path
          if not still then pure Nothing else do
            UndoRecord j committed token@(GitUndo root branch old new limit) <- readRecord
            redo <- doesFileExist j
            if committed || redo then do
              when redo $ do
                txt <- readFile' j
                unless (maybe False (const True) (parseJournal txt)) $
                  ioError (userError "undo journal has a corrupt redo anchor")
              unless committed (writeAtomic path (encodeUndo (UndoRecord j True token)))
              pure (Just j)
            else do
              result <- nativeGit (GitRequest root 19 branch "" "" [old,new] limit)
              either (ioError . userError . ("Git compensation refused (reference moved; undo journal retained): " ++)) (const (pure ())) result
              diagnostic "[sol] compensated Git commit by reference compare-and-swap"
              removeUndo
              pure Nothing
    redo <- if takeLocks then do
      hold <- newIORef True
      withLocksHold hold (acquireGo False path) [repo] decide
      else decide
    -- The committed marker is durable and the repo lock is released before
    -- redo acquires its own complete path set. Never recursively lock repo.
    forM_ redo $ \j -> recoverJournal True j >> removeUndo
  where
    readRecord = do
      text <- readFile' path
      maybe (ioError (userError "corrupt Sol undo journal")) pure (decodeUndo text)
    removeUndo = do
      removeFile path `catch` \e -> if isDoesNotExistError e then pure () else throwIO (e :: IOException)
      fsyncPath (parentOf path)

-- ---- locks ----------------------------------------------------------------

lockPath :: FilePath -> FilePath
lockPath p = p ++ ".sol-lock"

ownerPath :: FilePath -> FilePath
ownerPath p = lockPath p ++ "/owner"

-- jpath: this process's journal path, recorded in the owner file so a
-- reclaimer can finish our commit if we die holding the lock.
acquire :: FilePath -> FilePath -> IO ()
acquire = acquireGo True

-- the recovery path uses acquireGo False: it must not recurse into
-- journal recovery while already performing it
acquireGo :: Bool -> FilePath -> FilePath -> IO ()
acquireGo recover jpath p = go (0 :: Int)
  where
    parent = parentOf p
    go n = do
      -- the lock lives beside the target; its parent dir may itself be a
      -- pending mkdir in this very txn, so ensure it exists before locking
      unless (parent == ".") (createDirectoryIfMissing True parent)
      r <- try (createDirectory (lockPath p)) :: IO (Either IOException ())
      case r of
        Right () -> do
          me <- c_getpid
          writeFile (ownerPath p) (show (fromIntegral me :: Int) ++ "\n" ++ jpath ++ "\n")
            `onException` removePathForcibly (lockPath p)
        Left e
          | not (isAlreadyExistsError e) -> throwIO e
          | n > 5000 -> ioError (userError ("sol: could not lock " ++ p ++ " (live " ++ lockPath p ++ ")"))
          | otherwise -> do
              when (n `mod` 250 == 249) (tryReclaim recover p)
              threadDelay 1000 >> go (n + 1)

-- a contended lock whose recorded owner is dead is stale. Exactly one
-- reclaimer wins the atomic rename of the lock dir; it finishes the dead
-- owner's journal (if any) and removes the claimed dir. Losers, and any
-- lock with a live/unreadable owner, keep waiting.
tryReclaim :: Bool -> FilePath -> IO ()
tryReclaim recover p = do
  own <- try (readFile' (ownerPath p)) :: IO (Either IOException String)
  case own of
    Left _ -> pure () -- no owner file (mid-create, or pre-upgrade lock): wait
    Right txt -> case lines txt of
      (pidL : jL : _) | Just pid <- readMaybe pidL -> do
        alive <- c_pidAlive (fromIntegral (pid :: Int))
        when (alive == 0) $ do
          me <- c_getpid
          let claim = lockPath p ++ ".reclaim." ++ show (fromIntegral me :: Int)
          won <- try (renamePath (lockPath p) claim) :: IO (Either IOException ())
          case won of
            Left _ -> pure () -- someone else got it
            Right () -> do
              hPutStrLn stderr ("[sol] reclaimed stale lock on " ++ p ++ " (owner pid " ++ show pid ++ " is dead)")
              -- a redo that fails puts the dead owner's lock back (its
              -- journal is still there), rather than dropping the fence
              r <- try (when recover (recoverJournal False jL))
              case r of
                Right () -> removePathForcibly claim
                Left (e :: SomeException) -> do
                  _ <- try (renamePath claim (lockPath p)) :: IO (Either IOException ())
                  throwIO e
      _ -> pure ()

release :: FilePath -> IO ()
release p = do
  _ <- try (removePathForcibly (lockPath p)) :: IO (Either IOException ())
  pure ()

withLocks :: (FilePath -> IO ()) -> [FilePath] -> IO a -> IO a
withLocks takeLock paths action = do
  hold <- newIORef False
  withLocksHold hold takeLock paths action

-- The locks are released when the action returns, and when it throws
-- BEFORE the commit point. Once `hold` is set (the journal is written)
-- an exception leaves them in place, owned by this about-to-die pid:
-- releasing them would expose a half-replayed state to every other
-- script. The dead-owner reclaim in tryReclaim then finishes the journal
-- for whoever contends next, so the state others see is all-old until
-- the redo and all-new after it.
withLocksHold :: IORef Bool -> (FilePath -> IO ()) -> [FilePath] -> IO a -> IO a
withLocksHold hold takeLock paths action = mask $ \restore -> do
  -- Deduplicate the actual lock names, not the caller's path spellings.
  -- A read through "file" and a write through its absolute name must not
  -- acquire the same mkdir lock twice and wait on this process itself.
  keyed <- mapM (\p -> do key <- canonicalizePath (lockPath p); pure (key,p)) paths
  acquired <- acquireAll (M.elems (M.fromList keyed))
  r <- try (restore action)
  case r of
    Right a -> forM_ (reverse acquired) release >> pure a
    Left (e :: SomeException) -> do
      held <- readIORef hold
      if held
        then
          hPutStrLn stderr
            ( "[sol] the commit failed after its journal was written: keeping the locks on "
                ++ show (length acquired)
                ++ " path(s) so no one sees a partial state; the next contender finishes it"
            )
        else forM_ (reverse acquired) release
      throwIO e
  where
    acquireAll [] = pure []
    acquireAll (p : ps) = do
      takeLock p
      rest <- acquireAll ps `onException` release p
      pure (p : rest)

-- ---- the redo journal -----------------------------------------------------

donePath :: FilePath -> FilePath
donePath j = j ++ ".done"

-- complete-or-absent by construction: writeAtomic, plus a trailing COMMIT
-- line so a torn pre-rename tmp can never be mistaken for a journal
writeJournal :: FilePath -> [Effect] -> IO ()
writeJournal j effs = writeAtomic j (encodeJournal effs)

parseJournal :: String -> Maybe [Effect]
parseJournal = decodeJournal

readDone :: FilePath -> IO Done
readDone j = do
  r <- try (bracket (openBinaryFile (donePath j) ReadMode) hClose $ \h -> do
    bytes <- Process.boundedRead 0 "completion journal" 201326592 h
      `catch` \(Process.Failure why _ _ _) -> ioError (userError ("completion journal: " ++ why))
    either (ioError . userError) pure (ScriptIO.decodeUtf8 bytes)) :: IO (Either IOException String)
  case r of
    Left e | isDoesNotExistError e -> pure IM.empty
           | otherwise -> throwIO e
    Right txt -> do
      done <- either (ioError . userError) pure (decodeDone txt)
      unless (doneBytes done <= 16777216 && IM.size done <= 4096
              && all ((<= 2097152) . completionBytes) (IM.elems done))
        (ioError (userError "completion journal exceeds receipt budget"))
      pure done

-- Inline durable captures have the same caps as live text captures. No spool
-- files escape receipt cleanup; reserve 1 MiB for failure receipts themselves.
completionBytes :: Completion -> Int
completionBytes = sum . map (BS.length . BSU.fromString) . texts
  where texts (Left s) = [s]
        texts (Right (TextCapture s)) = [s]
        texts (Right (ProcessCapture _ out err)) = [out,err]

doneBytes :: Done -> Int
doneBytes = sum . map completionBytes . IM.elems

boundCompletion :: Done -> Completion -> Completion
boundCompletion done result
  | completionBytes result > 2097152 || doneBytes done + completionBytes result > 15728640 =
      Left "deferred receipt capture budget exceeded; external work may already have occurred"
  | otherwise = result

markDone :: FilePath -> Done -> IO ()
markDone j = writeAtomic (donePath j) . encodeDone

clearJournal :: FilePath -> IO ()
clearJournal j = do
  removePathForcibly j
  removePathForcibly (donePath j)
  fsyncPath (parentOf j)

-- redo an interrupted commit. takeLocks=True is the startup path (locks
-- must be taken around the redo); False is the reclaim path (the dead
-- owner's remaining lock dirs still fence other sol processes off the
-- touched paths, and we are already inside lock acquisition).
recoverJournal :: Bool -> FilePath -> IO ()
recoverJournal takeLocks j = do
  ex <- doesFileExist j
  when ex $ do
    txt <- readFile' j
    if ".undo" `isSuffixOf` j || "SOLUNDO1" `isPrefixOf` txt
      then recoverUndo takeLocks j
      else recoverRedo txt
  where
    recoverRedo txt = case parseJournal txt of
      Nothing -> do
        hPutStrLn stderr ("[sol] discarding incomplete journal " ++ j ++ " (crash before the commit point; the transaction never took effect)")
        clearJournal j
      Just effs -> do
        let touched = sort (nub [p | e <- effs, Just p <- [effectPath e]])
            recover = do
              stillThere <- doesFileExist j -- a concurrent reclaimer may have finished it
              when stillThere $ do
                done <- readDone j
                hPutStrLn stderr ("[sol] recovering interrupted commit from " ++ j ++ " (" ++ show (length effs) ++ " effect(s), " ++ show (IM.size done) ++ " shell(s) already done)")
                _ <- replayEffs j True done Nothing (zip [0 ..] effs)
                clearJournal j -- file effects all applied even past a failed shell
        hold <- newIORef True
        if takeLocks
          then withLocksHold hold (acquireGo False j) touched recover
          else recover

-- ---- private writable recovery state ---------------------------------------
-- New journals never require writes to the source/install directory. Legacy
-- sibling journals remain readable, including absolute paths in old lock owners.
stateDirectory :: IO FilePath
stateDirectory = do
  path <- stateDirectoryPath
  unless ("/" `isPrefixOf` path) $
    ioError (userError "Sol state directory must be an absolute path")
  privateDirectory path

-- where the state directory is, without creating it (fpr doctor asks)
stateDirectoryPath :: IO FilePath
stateDirectoryPath = do
  explicit <- lookupEnv "SOL_STATE_DIR"
  xdg <- lookupEnv "XDG_STATE_HOME"
  home <- getHomeDirectory
  pure $ case explicit of
    Just value -> value
    Nothing -> maybe (home </> ".local/state/sol") (</> "sol") xdg

privateDirectory :: FilePath -> IO FilePath
privateDirectory path = do
  durableDirectory path
  st <- PF.getSymbolicLinkStatus path
  uid <- getEffectiveUserID
  unless (PF.isDirectory st && PF.fileOwner st == uid) $
    ioError (userError ("Sol state directory must be an owned directory, not a symlink: " ++ path))
  when (PF.fileMode st .&. 0o777 /= 0o700) $ do
    PF.setFileMode path 0o700
    fsyncPath path
  canonicalizePath path

-- Persist each new directory entry before a commit can depend on a journal
-- below it. Syncing only the journal's immediate directory misses newly made
-- XDG/state parents after power loss. Reuse the runtime's platform sync helper.
durableDirectory :: FilePath -> IO ()
durableDirectory path = do
  exists <- doesDirectoryExist path
  unless exists $ do
    durableDirectory (takeDirectory path)
    createDirectory path `catch` \e -> unless (isAlreadyExistsError e) (throwIO (e :: IOException))
    fsyncPath (takeDirectory path)

stateBase :: FilePath -> IO FilePath
stateBase base = do
  absolute <- makeAbsolute base
  key <- Digest.hash (BSU.fromString absolute) >>= Digest.encode False
  root <- stateDirectory
  dir <- privateDirectory (root </> key)
  -- This descriptor is for inspection only; recovery trusts the journal/locks.
  let descriptor = dir </> "script"
  exists <- doesFileExist descriptor
  unless exists $ bracket (openTempFile dir ".sol-script-")
    (\(temp,handle) -> do
      hClose handle `catch` \(_ :: IOException) -> pure ()
      removeFile temp `catch` \(_ :: IOException) -> pure ())
    (\(temp,handle) -> do
      hPutStr handle (absolute ++ "\n")
      hClose handle
      fsyncPath temp
      renamePath temp descriptor
      fsyncPath dir)
  pure (dir </> "run")

journalPrefix :: FilePath -> FilePath
journalPrefix base = base ++ ".soljournal."

runJournalPath :: FilePath -> IO FilePath
runJournalPath base = do
  stored <- stateBase base
  me <- c_getpid
  t <- getPOSIXTime
  let nonce = floor (t * 1000000000) :: Integer
  pure (journalPrefix stored ++ show (fromIntegral me :: Int) ++ "." ++ show nonce)

recoverScriptJournals :: FilePath -> IO ()
recoverScriptJournals base = do
  recoverAtBase base -- pre-installation layout, never create files beside it
  stateBase base >>= recoverAtBase

-- Only dead owners are eligible. The caller's pid cannot own a journal yet;
-- a same-pid file therefore belongs to a dead predecessor after pid reuse.
recoverAtBase :: FilePath -> IO ()
recoverAtBase base = do
  recoverJournal True (base ++ ".soljournal")
  let dir = takeDirectory base
      stem = takeFileName (journalPrefix base)
  names <- listDirectory dir
  me <- c_getpid
  forM_ (reverse (sort names)) $ \name ->
    case journalOwner stem name of
      Just pid -> do
        alive <- c_pidAlive (fromIntegral pid)
        when (alive == 0 || pid == fromIntegral me) $
          recoverJournal True (dir </> name)
      Nothing -> pure ()

journalOwner :: String -> String -> Maybe Int
journalOwner stem name
  | stem `isPrefixOf` name && not (any (`isSuffixOf` name) [".done", ".sol-tmp"]) =
      readMaybe (takeWhile (/= '.') (drop (length stem) name))
  | otherwise = Nothing

-- Explicit maintenance scans only the runtime's hash-named groups. It leaves
-- live owners alone and propagates recovery errors instead of deleting fences.
maintainState :: Bool -> IO ()
maintainState repair = do
  root <- stateDirectory
  putStrLn ("state " ++ root)
  groups <- sort <$> listDirectory root
  forM_ [name | name <- groups, length name == 64, all (`elem` "0123456789abcdef") name] $ \name -> do
    let dir = root </> name
    st <- PF.getSymbolicLinkStatus dir
    uid <- getEffectiveUserID
    unless (PF.isDirectory st && PF.fileOwner st == uid) $
      ioError (userError ("unsafe Sol state group: " ++ dir))
    when repair $ recoverAtBase (dir </> "run")
    names <- sort <$> listDirectory dir
    forM_ names $ \file -> case journalOwner "run.soljournal." file of
      Nothing -> pure ()
      Just pid -> do
        alive <- c_pidAlive (fromIntegral pid)
        regular <- doesFileExist (dir </> file)
        when regular $ putStrLn ((if alive == 0 then "dead " else "live ") ++ dir </> file)

-- ---- commit ---------------------------------------------------------------

-- Committed carries (applied file effects, deferred commands/processes
-- that ran, a deferred command failed, a file effect failed); the run
-- exits 0 only when both flags are False
data CommitResult = Committed Int Int Bool Bool | Conflict [FilePath]

effectPath :: Effect -> Maybe FilePath
effectPath (EWrite p _) = Just p
effectPath (ERemove p) = Just p
effectPath (EMkdir p) = Just p
effectPath (ERmdir p) = Just p
effectPath (EShell _) = Nothing
effectPath (EShellAt _ _) = Nothing
effectPath (EProcess _) = Nothing
effectPath (EGit (GitRequest path _ _ _ _ _ _)) = Just path
effectPath (EArchive _ target _ _) = Just target
effectPath (ELogWrite p _) = Just p
effectPath (ELater (PlannedGit (GitRequest p _ _ _ _ _ _))) = Just p
effectPath (ELater (PlannedTag p _ _ _)) = Just p
effectPath (ELater _) = Nothing

-- lock (sorted) -> validate content reads, metadata promises and dir
-- listings -> journal the effect log (fsynced; the commit point) ->
-- replay it in order -> clear the journal -> unlock. Deferred shell commands run inside the commit, after
-- validation: if the txn retried they never happened. Once released they
-- CANNOT be rolled back — a failing deferred command stops the replay and
-- reports what did not run.
commit :: IORef TxState -> FilePath -> IO CommitResult
commit ref jpath = do
  -- seal first, then read: an actor's effect racing this point either
  -- lands in the log we take, or lands sealed and is reported as lost
  s <- atomicModifyIORef' ref (\st -> (st {txSealed = True}, st {txSealed = True}))
  let effs = reverse (txEffects s)
      touched =
        M.keys
          ( M.unions
              [ M.map (const ()) (txReads s),
                M.map (const ()) (txDirReads s),
                M.map (const ()) (txMetaReads s),
                M.fromList [(p, ()) | e <- effs, Just p <- [effectPath e]],
                M.fromList [(p,()) | (p,_) <- txPathLogs s]
              ]
          )
  hold <- newIORef False
  staleMeta <- newIORef []
  -- Recheck each metadata promise under its own path lock, before taking
  -- descendant locks. Those locks are entries inside a directory and
  -- legitimately change its size/mtime; checking directory stat only after
  -- creating them would make inventories conflict with themselves forever.
  -- Paths are stable and sorted parent-before-child. Content and directory
  -- name sets still validate below after every lock has been acquired.
  let takeLock p = do
        acquire jpath p
        forM_ (M.lookup p (txMetaReads s)) $ \ms -> do
          stale <- metaStaleIO ms p
          when stale $ modifyIORef' staleMeta (p :)
  withLocksHold hold takeLock touched $ do -- sorted: global lock order
    staleC <-
      foldM
        ( \acc (p, snap) -> do
            now <- diskReadBytes p
            pure (if now == snap then acc else p : acc)
        )
        []
        (M.toList (txReadBytes s))
    staleM <- readIORef staleMeta
    staleD <-
      foldM
        ( \acc (dir, names) -> do
            r <- try (listDirectory dir) :: IO (Either IOException [String])
            now0 <- case r of
              Left e
                | isDoesNotExistError e -> pure []
                | otherwise -> throwIO e
              Right names' -> pure names'
            -- taking a lock beside a path whose parent dir does not exist
            -- yet creates that parent (acquireGo). Such a dir is a
            -- protocol artifact of THIS commit, not a foreign write: it is
            -- an ancestor of a touched path and holds nothing but lock
            -- artifacts. Without this a script that lists a dir and then
            -- writes into a subdir of it would conflict with itself and
            -- pay a retry every run.
            now1 <- filterOutProtocolDirs dir touched now0
            let now = sort (filter (not . lockArtifact) now1)
            pure (if now == names then acc else dir : acc)
        )
        []
        (M.toList (txDirReads s))
    let stale = staleC ++ staleM ++ staleD
    if null stale
      then do
        effs <- materializeLogs effs (reverse (txPathLogs s))
        either (ioError . userError) pure (validatePlan effs)
        crashAt <- (>>= readMaybe) <$> lookupEnv "SOL_CRASH_AT"
        when (not (null effs) || txSaga s /= Nothing) (writeJournal jpath effs >> writeIORef hold True)
        when (txSaga s /= Nothing) (sagaCrash "anchored")
        commitSaga ref jpath
        (n, sfail, efail) <- replayEffs jpath False IM.empty crashAt (zip [0 ..] effs)
        clearJournal jpath
        when (txSaga s /= Nothing) (sagaCrash "completed")
        forM_ (txSaga s) $ \_ -> removeFile (undoPath jpath) >> fsyncPath (parentOf jpath)
        writeIORef hold False
        -- a `run` PARENT set SOL_REPORT_COMMIT so it can learn which
        -- paths this child transaction committed (Mod.runModule reads
        -- the marker off stderr and checks them against its own sets)
        reportC <- lookupEnv "SOL_REPORT_COMMIT"
        let wrotePaths = nub [p | e <- effs, Just p <- [effectPath e]]
        when (reportC == Just "1" && not (null wrotePaths)) $
          hPutStrLn stderr (childCommitMarker ++ show wrotePaths)
        let ncmd = length [() | e <- effs, deferredEffect e]
        pure (Committed n ncmd sfail efail)
      else pure (Conflict stale)

-- Native effects have lockable paths as well as deferred-operation receipts.
deferredEffect :: Effect -> Bool
deferredEffect (ELater _) = True
deferredEffect (EGit _) = True
deferredEffect (EArchive _ _ _ _) = True
deferredEffect e = case effectPath e of Nothing -> True; Just _ -> False

-- the stderr line a child sol emits (under SOL_REPORT_COMMIT=1) naming
-- the paths its commit touched; the parent's `run` parses it
childCommitMarker :: String
childCommitMarker = "[sol-child] committed-paths: "

-- After a `run` child commits: paths it wrote that THIS transaction
-- already read, listed (their directory), or wrote can never validate —
-- every retry re-runs the child, which commits again, forever (and a
-- non-idempotent child AMPLIFIES: its effect lands once per attempt).
-- The caller refuses on overlap; disjoint paths need no repair, because
-- a later read simply snapshots the child's committed content.
txChildOverlap :: IORef TxState -> [FilePath] -> IO [FilePath]
txChildOverlap ref ps = do
  s <- readIORef ref
  files <- S.fromList <$> mapM canonicalizePath (M.keys (txReads s) ++ M.keys (txView s) ++ M.keys (txMetaReads s))
  dirs <- S.fromList <$> mapM canonicalizePath (M.keys (txDirReads s))
  paths <- mapM canonicalizePath ps
  pure [p | p <- paths, S.member p files || S.member (takeDirectory p) dirs]

-- names in a listing that exist only because this commit's lock protocol
-- created them: proper ancestors of a touched path, containing nothing
-- but lock artifacts (recursively). A foreign txn that put real content
-- there is still a conflict.
filterOutProtocolDirs :: FilePath -> [FilePath] -> [String] -> IO [String]
filterOutProtocolDirs dir touched names = do
  absolute <- mapM canonicalizePath touched
  go absolute names
  where
    go _ [] = pure []
    go touchedAbs (n : rest) = do
      let full = dir ++ "/" ++ n
      absoluteFull <- canonicalizePath full
      let ancestor = any (\t -> (absoluteFull ++ "/") `isPrefixOf` t) touchedAbs
      drop' <-
        if ancestor
          then do
            isD <- doesDirectoryExist full
            if isD then protocolOnly full else pure False
          else pure False
      rest' <- go touchedAbs rest
      pure (if drop' then rest' else n : rest')
    protocolOnly d = do
      r <- try (listDirectory d) :: IO (Either IOException [String])
      case r of
        Left _ -> pure False
        Right es -> allM (entryOk d) es
    entryOk d e
      | lockArtifact e = pure True
      | otherwise = do
          let full = d ++ "/" ++ e
              ancestor = any (\t -> (full ++ "/") `isPrefixOf` t) touched
          isD <- doesDirectoryExist full
          if ancestor && isD then protocolOnly full else pure False
    allM _ [] = pure True
    allM f (x : xs) = do
      ok <- f x
      if ok then allM f xs else pure False


-- replay the (indexed) effect log. recovery=True is the redo path: file
-- effects re-apply idempotently, shell effects in `done` are skipped and
-- the rest re-run (loudly — this is the at-least-once window). crashAt
-- is the SOL_CRASH_AT hook: die like kill -9 just before applying that
-- effect index, so the crash windows are deterministically testable.
--
-- The count that comes back is what the receipt reports, so it counts
-- FILE effects whose goal state holds afterwards — nothing else. A
-- removal whose target still exists (rm of a directory, rmdir of a
-- non-empty one) is a FAILED effect and says so; on the redo path the
-- goal check is exactly what makes re-application idempotent (a file
-- already gone is success, not a warning).
--
-- A FAILED deferred command does not tear the file transaction: file
-- effects were validated under lock, so the replay keeps applying them
-- past the failure. Only LATER SHELL commands are skipped (they may
-- have depended on the failed one), each named. A failed removal is
-- treated the same way: later commands are skipped, and the run fails.
-- What comes back is (file effects applied, a deferred command failed,
-- a file effect failed); either failure makes the run exit non-zero.
replayEffs :: FilePath -> Bool -> Done -> Maybe Int -> [(Int, Effect)] -> IO (Int, Bool, Bool)
replayEffs j recovery done crashAt effs = do
  either (ioError . userError) pure (validatePlan (map snd effs))
  results <- newIORef done
  bad <- newIORef False
  (n,sf) <- go results bad False effs
  ef <- readIORef bad
  pure (n,sf,ef)
  where
    go _ _ sf [] = pure (0,sf)
    go results bad sf ((i,e):rest) = do
      when (crashAt == Just i) $ do
        diagnostic ("[sol] SOL_CRASH_AT=" ++ show i ++ ": hard exit before effect " ++ show i)
        hFlush stderr
        c_hardExit 137
      let next failure count = do
            (n,f) <- go results bad failure rest
            pure (n+count,f)
          failed what = writeIORef bad True >> diagnostic ("[sol] effect FAILED (not counted): " ++ what) >> next True 0
          external label forward action = do
            saved <- IM.lookup i <$> readIORef results
            if sf then do
              let name = case e of EShell _ -> "command"; EShellAt {} -> "command"; EProcess _ -> "process"; _ -> "native effect"
              diagnostic ("[sol] skipping queued " ++ name ++ " (an earlier one failed): " ++ label)
              next sf 0
            else case saved of
              Just r -> do
                when recovery (diagnostic ("[sol] redo: skipping already-run " ++ label))
                when (completionFailed r) (diagnostic ("[sol] redo: recorded failure retained: " ++ label))
                next (completionFailed r) 0
              Nothing -> do
                when recovery (diagnostic ("[sol] redo: re-running " ++ label ++ " (at-least-once)"))
                raw <- action
                prior <- readIORef results
                let r = boundCompletion prior raw
                rs <- atomicModifyIORef' results (\m -> let m'=IM.insert i r m in (m',m'))
                markDone j rs
                case r of
                  Right (ProcessCapture _ out err) | forward || completionFailed r -> do
                    unless (null out) (putStr out)
                    unless (null err) (hPutStr stderr err)
                  _ -> pure ()
                when (completionFailed r) $ do
                  let why = case r of Left x -> x; Right (ProcessCapture c _ _) -> "exit " ++ show c; _ -> "failed"
                  let name = case e of EShell _ -> "deferred command"; EShellAt {} -> "deferred command"; EProcess _ -> "deferred process"; EGit _ -> "native effect"; EArchive {} -> "native effect"; _ -> label
                  diagnostic ("[sol] " ++ name ++ " FAILED (" ++ why ++ "): " ++ label)
                  diagnostic "[sol] later queued commands will be skipped; file effects still apply"
                next (completionFailed r) 0
      case e of
        EWrite p v -> writeAtomic p v >> next sf 1
        ELogWrite p v -> do
          ef <- readIORef bad
          if sf || ef then diagnostic ("[sol] transactional log withheld: " ++ p) >> next sf 0
            else writeAtomic p v >> next sf 1
        ERemove p -> do
          _ <- try (removeFile p) :: IO (Either IOException ())
          file <- doesFileExist p; dir <- doesDirectoryExist p
          if file || dir then failed ("rm " ++ p ++ " (still exists)") else next sf 1
        EMkdir p -> createDirectoryIfMissing True p >> next sf 1
        ERmdir p -> do
          _ <- try (removeDirectory p) :: IO (Either IOException ())
          still <- doesDirectoryExist p
          if still then failed ("rmdir " ++ p ++ " (still exists — not empty?)") else next sf 1
        EShell cmd -> external ("deferred command " ++ cmd) True
          (captureProcess (ProcessSpec ["/bin/sh","-c",cmd] Nothing [] "" Nothing))
        EShellAt cwd cmd -> external ("deferred command " ++ cmd) True
          (captureProcess (ProcessSpec ["/bin/sh","-c",cmd] (Just cwd) [] "" Nothing))
        EProcess spec -> external ("deferred process " ++ displayProcess spec) True (captureProcess spec)
        EGit request -> external ("native effect " ++ effectBrief e) False (fmap TextCapture <$> nativeGit request)
        EArchive source target entries bytes -> external ("native archive " ++ target) False (fmap TextCapture <$> nativeArchive source target entries bytes)
        ELater step -> external ("deferred step " ++ show i ++ ": " ++ effectBrief e) True $ do
          rs <- readIORef results
          case step of
            PlannedProcess args spec -> case traverse (resolveArg rs) args of
              Left why -> pure (Left why)
              Right argv -> captureProcess spec {psArgv=argv}
            PlannedGit request -> fmap TextCapture <$> nativeGit request
            PlannedTag path name ref limit -> case resolveDeferred rs ref of
              Left why -> pure (Left why)
              Right sha -> fmap TextCapture <$> nativeGit (GitRequest path 16 name "" "" [sha] limit)
    captureProcess spec = fmap (\(c,o,e) -> ProcessCapture c o e) <$> runProcessSpec spec
    resolveArg _ (LiteralArg s) = Right s
    resolveArg done (FromArg ref) = resolveDeferred done ref

-- Append logs become complete post-images under their path locks. Redo can
-- write these repeatedly without duplicating lines. They run only after all
-- ordinary effects succeed, including any terminal publication.
materializeLogs :: [Effect] -> [(FilePath,String)] -> IO [Effect]
materializeLogs effects logs = do
  let paths = nub (map fst logs)
      final p = foldl (\v e -> case e of
        EWrite q text | p==q -> Just (Just text)
        ERemove q | p==q -> Just Nothing
        _ -> v) Nothing effects
  appended <- mapM (\p -> do
    old <- case final p of
      Just v -> pure (maybe "" id v)
      Nothing -> do
        bytes <- diskReadBytes p
        case fmap decodeSnapshot bytes of
          Nothing -> pure ""
          Just (text,True) -> pure text
          _ -> ioError (userError ("logTo: not UTF-8: " ++ p))
    pure (ELogWrite p (old ++ concat [line ++ "\n" | (q,line) <- logs, q==p]))) paths
  pure (effects ++ appended)

