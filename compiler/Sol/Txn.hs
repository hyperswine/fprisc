{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Txn.hs — the script-session TRec.
--
-- `sol script.sol` runs the whole script inside one transaction. Every host
-- file the script touches becomes a TVar-like slot:
--
--   * first READ of a path snapshots its content (or its absence) into the
--     read set; later reads are served from the write set, then the read set
--     — the script sees a stable snapshot plus its own writes
--   * WRITES are buffered in the write set; the disk is never touched
--     mid-script
--   * at exit: lock every touched file (sorted order — no deadlock),
--     VALIDATE the read set against the disk, COMMIT the write set,
--     unlock. If validation fails, the whole script re-runs (STM retry).
--
-- Locks are atomic mkdir locks (<path>.sol-lock) so two concurrent `sol`
-- processes exclude each other portably with no daemon.
--
-- Handles: `open` registers a path and returns a handle id; the LINEARITY
-- checker (front-end, compile time) is what guarantees each handle is used
-- exactly once per operation and therefore cannot be leaked or double-closed
-- — the runtime table below just maps ids to paths.

module Sol.Txn where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, finally, mask, onException, throwIO, try)
import Control.Monad (foldM, forM_, unless, when)
import Data.IORef
import Data.Maybe (mapMaybe)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import System.Environment (getEnvironment, lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.UTF8 as BSU
import qualified Data.IntMap.Strict as IM
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Directory
  ( createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getFileSize,
    getModificationTime,
    listDirectory,
    removeDirectory,
    removeFile,
    removePathForcibly,
    renamePath,
  )
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import System.Exit (ExitCode (..))
import System.IO (readFile')
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.IO (hFlush, hGetContents', hIsEOF, hGetLine, stderr, stdin, stdout, hPutStr, hPutStrLn)
import System.Process (CreateProcess (..), createProcess, proc, readCreateProcessWithExitCode, shell, waitForProcess)
import System.Timeout (timeout)

data ProcessSpec = ProcessSpec
  { psArgv :: [String],
    psCwd :: Maybe FilePath,
    psEnv :: [(String, String)],
    psStdin :: String,
    psTimeoutMs :: Maybe Int
  }
  deriving (Show, Read)

-- The transaction's pending effect on the world, IN DECLARATION ORDER.
-- File writes, removals, mkdirs, and QUEUED external commands interleave
-- exactly as the script issued them; commit replays the log.
data Effect
  = EWrite FilePath String
  | ERemove FilePath
  | EMkdir FilePath
  | ERmdir FilePath
  | EShell String
  | EProcess ProcessSpec
  deriving (Show, Read)

data TxState = TxState
  { txReads :: M.Map FilePath (Maybe String), -- content snapshot at first read
    txDirReads :: M.Map FilePath [String], -- directory listings taken
    txEffects :: [Effect], -- REVERSED effect log
    txView :: M.Map FilePath (Maybe String), -- current in-txn file view
    txDirView :: M.Map FilePath Bool, -- dirs mkdir'd (True) / rmdir'd (False)
    txHandles :: IM.IntMap FilePath, -- open handle id -> path
    txNextH :: !Int,
    txNonText :: S.Set FilePath, -- snapshotted paths that are NOT valid UTF-8
    txSealed :: !Bool -- commit has read the effect log; later effects are lost
  }

newTx :: IO (IORef TxState)
newTx = newIORef emptyTx

emptyTx :: TxState
emptyTx = TxState M.empty M.empty [] M.empty M.empty IM.empty 1 S.empty False

resetTx :: IORef TxState -> IO ()
resetTx ref = writeIORef ref emptyTx

-- an effect issued after commit sealed the log (an actor thread that
-- outlived program order) can only be lost — name it, loudly
pushEffect :: IORef TxState -> Effect -> IO ()
pushEffect ref e = do
  sealed <- atomicModifyIORef' ref (\s -> (s {txEffects = e : txEffects s}, txSealed s))
  when sealed $
    hPutStrLn stderr ("[sol] effect AFTER COMMIT (lost): " ++ effectBrief e
                        ++ " — join actors before the script ends")

-- one-line description of a queued effect, for the diagnostics that have
-- to name what is still pending
effectBrief :: Effect -> String
effectBrief (EWrite p _) = "write " ++ p
effectBrief (ERemove p) = "rm " ++ p
effectBrief (EMkdir p) = "mkdirp " ++ p
effectBrief (ERmdir p) = "rmdir " ++ p
effectBrief (EShell c) = "shq " ++ c
effectBrief (EProcess spec) = "Proc.afterCommit " ++ displayProcess spec

-- The effects this transaction has queued but NOT yet applied, in
-- declaration order. A realtime escape runs BEFORE all of them (they
-- wait for commit), so anything that steps outside the transaction asks
-- this first and reports the inversion rather than acting on a world
-- the script has already described differently.
txPendingBrief :: IORef TxState -> IO [String]
txPendingBrief ref = do
  s <- readIORef ref
  pure (map effectBrief (reverse (txEffects s)))

-- compact form, for the escapes that can only warn (they answer a value,
-- not a Result, so they cannot refuse)
pendingOrderBrief :: String -> String -> [String] -> String
pendingOrderBrief what deferredSpelling pending =
  what
    ++ " runs before this transaction's "
    ++ show (length pending)
    ++ " queued effect(s), which land at commit — queue it too ("
    ++ deferredSpelling
    ++ "), or split the run"

-- the pending-effect refusal message shared by the realtime escapes:
-- what was asked for, what is still queued, and the two ways out
pendingOrderMsg :: String -> String -> [String] -> String
pendingOrderMsg what deferredSpelling pending =
  what
    ++ " runs NOW, but this transaction has "
    ++ show (length pending)
    ++ " queued effect(s) that only happen at commit:\n"
    ++ unlines ["      " ++ b | b <- take 5 pending]
    ++ (if length pending > 5 then "      ... and " ++ show (length pending - 5) ++ " more\n" else "")
    ++ "    Running now would act on the world BEFORE those land."
    ++ " Queue it too ("
    ++ deferredSpelling
    ++ "), or move it to a separate script run."

-- Files are read as BYTES and decoded here, so a non-UTF-8 file is a
-- fact we can report — it used to throw inside the locale decoder, get
-- caught as an IOException, and read as ABSENT, which made
-- read-modify-write silently clobber binaries. The Bool is UTF-8
-- validity; the String is the lossy decode (invalid bytes become
-- U+FFFD), which is what validation compares — consistent on both
-- sides of the comparison. (Two binary files differing only in invalid
-- bytes that decode alike could alias in validation; text never does.)
diskReadT :: FilePath -> IO (Maybe (String, Bool))
diskReadT p = do
  r <- try (BS.readFile p) :: IO (Either IOException BS.ByteString)
  case r of
    Left e
      | isDoesNotExistError e -> pure Nothing
      | otherwise -> throwIO e
    Right bs -> let t = BSU.toString bs in pure (Just (t, BSU.fromString t == bs))

diskRead :: FilePath -> IO (Maybe String)
diskRead p = fmap fst <$> diskReadT p

-- open: register the path, hand back a handle id. Reading is NOT done here;
-- the snapshot happens lazily at first txHRead so a write-only open doesn't
-- inflate the read set (and therefore can't cause a spurious conflict).
txOpen :: IORef TxState -> FilePath -> IO Int
txOpen ref p = atomicModifyIORef' ref $ \s ->
  let h = txNextH s
   in (s {txHandles = IM.insert h p (txHandles s), txNextH = h + 1}, h)

txPathOf :: IORef TxState -> Int -> IO FilePath
txPathOf ref h = do
  s <- readIORef ref
  case IM.lookup h (txHandles s) of
    Just p -> pure p
    Nothing -> ioError (userError ("sol: stale handle " ++ show h ++ " (should be impossible: linearity)"))

txClose :: IORef TxState -> Int -> IO ()
txClose ref h = atomicModifyIORef' ref $ \s ->
  (s {txHandles = IM.delete h (txHandles s)}, ())

-- snapshot a path into the read set (for validation) if not already there;
-- a non-UTF-8 file snapshots its lossy decode and is remembered as
-- non-text so the read surface can refuse it while exists/stat still work
snapshot :: IORef TxState -> FilePath -> IO (Maybe String)
snapshot ref p = do
  s <- readIORef ref
  case M.lookup p (txReads s) of
    Just snap -> pure snap
    Nothing -> do
      d <- diskReadT p
      let txt = fmap fst d
          nonText = maybe False (not . snd) d
      atomicModifyIORef' ref
        ( \st ->
            ( st
                { txReads = M.insert p txt (txReads st),
                  txNonText = if nonText then S.insert p (txNonText st) else txNonText st
                },
              ()
            )
        )
      pure txt

-- transactional read, absence and binariness observable: in-txn view >
-- read snapshot > disk (snapshotting). The Ok/Err surface (Try.readPath)
-- reports the failure cases; the plain surface (readPath/readAll) treats
-- them as panics.
data TxRead = TxText String | TxMissing | TxNonText | TxReadError String

txTryRead :: IORef TxState -> FilePath -> IO TxRead
txTryRead ref p = do
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just (Just w) -> pure (TxText w) -- this txn's own write: always text
    Just Nothing -> pure TxMissing -- removed earlier in this txn
    Nothing -> do
      result <- try (snapshot ref p) :: IO (Either IOException (Maybe String))
      case result of
        Left e -> pure (TxReadError (show e))
        Right r -> do
          s2 <- readIORef ref
          pure $ case r of
            Nothing -> TxMissing
            Just w | S.member p (txNonText s2) -> TxNonText
            Just w -> TxText w

-- ABSENCE IS NOT EMPTY: a missing file used to read as "", which made
-- read-modify-write silently fabricate empty state (and a binary file
-- used to read as MISSING). The plain read now refuses both; existence
-- questions go through exists/stat/Try.readPath.
txHRead :: IORef TxState -> Int -> IO String
txHRead ref h = do
  p <- txPathOf ref h
  r <- txTryRead ref p
  case r of
    TxText w -> pure w
    TxMissing ->
      ioError (userError ("*** SOL PANIC: read: no such file: " ++ p
                            ++ " — guard with `exists`, or use Try.readPath ***"))
    TxNonText ->
      ioError (userError ("*** SOL PANIC: read: not a UTF-8 text file: " ++ p
                            ++ " — sol reads text; drive binary tools with sh/shq ***"))
    TxReadError e ->
      ioError (userError ("*** SOL PANIC: read: " ++ p ++ ": " ++ e ++ " ***"))

txHWrite :: IORef TxState -> Int -> String -> IO ()
txHWrite ref h v = do
  p <- txPathOf ref h
  pushEffect ref (EWrite p v)
  atomicModifyIORef' ref (\s -> (s {txView = M.insert p (Just v) (txView s)}, ()))

-- ---- path-level transactional ops ----------------------------------------

-- remove: snapshot current state (so a concurrent write aborts us), mark
-- deleted in the view, queue the removal
txRm :: IORef TxState -> FilePath -> IO ()
txRm ref p = do
  _ <- snapshot ref p
  pushEffect ref (ERemove p)
  atomicModifyIORef' ref (\s -> (s {txView = M.insert p Nothing (txView s)}, ()))

txMkdirp :: IORef TxState -> FilePath -> IO ()
txMkdirp ref p = do
  pushEffect ref (EMkdir p)
  atomicModifyIORef' ref (\s -> (s {txDirView = M.insert p True (txDirView s)}, ()))

txRmdir :: IORef TxState -> FilePath -> IO ()
txRmdir ref p = do
  pushEffect ref (ERmdir p)
  atomicModifyIORef' ref (\s -> (s {txDirView = M.insert p False (txDirView s)}, ()))

-- list a directory: disk listing (validated at commit) composed with this
-- txn's own additions and removals in that directory. sol-lock artifacts
-- are invisible.
txLs :: IORef TxState -> FilePath -> IO [String]
txLs ref dir = do
  s <- readIORef ref
  base <- case M.lookup dir (txDirReads s) of
    Just names -> pure names
    Nothing -> do
      r <- try (listDirectory dir) :: IO (Either IOException [String])
      names0 <- case r of
        Left e
          | isDoesNotExistError e -> pure []
          | otherwise -> throwIO e
        Right names -> pure names
      let names = sort (filter (not . lockArtifact) names0)
      atomicModifyIORef' ref (\st -> (st {txDirReads = M.insert dir names (txDirReads st)}, ()))
      pure names
  s2 <- readIORef ref
  let inDir p = takeDir p == dir
      takeDir p = let q = reverse (dropWhile (/= '/') (reverse p)) in if null q then "." else init q
      baseName p = reverse (takeWhile (/= '/') (reverse p))
      added = [baseName p | (p, Just _) <- M.toList (txView s2), inDir p, baseName p `notElem` base]
      removed = [baseName p | (p, Nothing) <- M.toList (txView s2), inDir p]
      addedDirs = [baseName p | (p, True) <- M.toList (txDirView s2), inDir p, baseName p `notElem` base]
  pure (sort ((base ++ added ++ addedDirs) `without` removed))
  where
    without xs ys = [x | x <- xs, x `notElem` ys]

txExists :: IORef TxState -> FilePath -> IO Bool
txExists ref p = do
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just (Just _) -> pure True
    Just Nothing -> pure False
    Nothing -> case M.lookup p (txDirView s) of
      Just b -> pure b
      Nothing -> do
        snap <- snapshot ref p
        case snap of
          Just _ -> pure True
          Nothing -> doesDirectoryExist p -- dirs have no content snapshot

txIsDir :: IORef TxState -> FilePath -> IO Bool
txIsDir ref p = do
  s <- readIORef ref
  case M.lookup p (txDirView s) of
    Just b -> pure b
    Nothing -> doesDirectoryExist p

-- (exists, size, mtime-seconds). The transaction's own view answers
-- first — a file this txn wrote EXISTS, sized by its pending content
-- (UTF-8 bytes, matching what commit will put on disk), mtime = now
-- (it has no disk mtime yet). Only a view miss consults the snapshot
-- (content joins the read set for validation) and the disk metadata.
txStat :: IORef TxState -> FilePath -> IO (Bool, Integer, Integer)
txStat ref p = do
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just Nothing -> pure (False, 0, 0) -- removed earlier in this txn
    Just (Just w) -> do
      now <- getPOSIXTime
      pure (True, fromIntegral (utf8Len w), floor now)
    Nothing -> do
      snap <- snapshot ref p
      case snap of
        Nothing -> pure (False, 0, 0)
        Just _ -> do
          sz <- getFileSize p
          mt <- getModificationTime p
          pure (True, sz, floor (utcTimeToPOSIXSeconds mt))

-- byte length of the string as commit will encode it
utf8Len :: String -> Int
utf8Len = sum . map w
  where
    w c
      | fromEnum c < 0x80 = 1
      | fromEnum c < 0x800 = 2
      | fromEnum c < 0x10000 = 3
      | otherwise = 4

-- ---- external commands -----------------------------------------------------

-- immediate: for READ-ONLY commands (git status, docker ps). The read-only
-- claim is the caller's assertion — it cannot be enforced, and its output
-- cannot be validated at commit. Reruns on retry.
txSh :: String -> IO (Int, String)
txSh cmd = do
  (code, out, err) <- readCreateProcessWithExitCode (shell cmd) ""
  let c = case code of ExitSuccess -> 0; ExitFailure n -> n
  pure (c, out ++ err)

-- queued: for MUTATING commands (git commit, docker rm). Runs at COMMIT,
-- after validation, interleaved in declaration order with file effects.
-- On retry the queue is discarded: the world was never touched.
txShq :: IORef TxState -> String -> IO ()
txShq ref cmd = pushEffect ref (EShell cmd)

-- Structured process execution. Unlike sh/shq, argv never crosses a shell,
-- stdout and stderr stay separate, and environment entries override rather
-- than replace the inherited environment. A non-positive timeout means none.
runProcessSpec :: ProcessSpec -> IO (Either String (Int, String, String))
runProcessSpec spec = case psArgv spec of
  [] -> pure (Left "process argv is empty")
  exe : args -> do
    inherited <- getEnvironment
    let overrides = M.fromList (psEnv spec)
        mergedEnv = M.toList (M.union overrides (M.fromList inherited))
        cp =
          (proc exe args)
            { cwd = psCwd spec,
              env = if null (psEnv spec) then Nothing else Just mergedEnv
            }
        run = readCreateProcessWithExitCode cp (psStdin spec)
        timed = case psTimeoutMs spec of
          Just ms | ms > 0 -> timeout (ms * 1000) run
          _ -> Just <$> run
    result <- try timed :: IO (Either IOException (Maybe (ExitCode, String, String)))
    pure $ case result of
      Left e -> Left (show e)
      Right Nothing -> Left ("timed out after " ++ show (maybe 0 id (psTimeoutMs spec)) ++ "ms")
      Right (Just (code, out, err)) ->
        Right (case code of ExitSuccess -> 0; ExitFailure n -> n, out, err)

txProcessAfterCommit :: IORef TxState -> ProcessSpec -> IO ()
txProcessAfterCommit ref spec = pushEffect ref (EProcess spec)

displayProcess :: ProcessSpec -> String
displayProcess spec = unwords (map show (psArgv spec))

-- ---- REALTIME ESCAPES (outside the transaction) ---------------------------
--
-- Everything above this line is transactional: reads snapshot, writes buffer,
-- and a validation failure re-runs the script with the world untouched. That
-- is the default and it is what you want almost always.
--
-- These are the deliberate holes in it. They exist because three things are
-- genuinely impossible inside a transaction:
--
--   * OBSERVING CHANGE. A transactional read is idempotent by construction —
--     the second `read p` returns the first read's snapshot. A poll/watch/tail
--     loop can therefore never see a file change. rtRead re-reads the disk.
--   * STREAMING OUTPUT. `sh` captures a command's output and hands it back
--     when the command is done, so a four-minute build shows nothing until
--     it finishes. rtShell inherits stdio so the output arrives live.
--   * PROMPTING. `input` slurps all of stdin at once; a prompt loop needs a
--     line at a time, now.
--
-- What you give up, in every case: the operation happens even if the
-- transaction later rolls back, it happens AGAIN on every retry, and its
-- result is not validated at commit. The counter below exists so a run that
-- uses these says so out loud.

-- per-kind use counts, for the warning summary; survives retries
type RtCounts = IORef (M.Map String Int)

newRtCounts :: IO RtCounts
newRtCounts = newIORef M.empty

-- bump, and on FIRST use of a kind explain what was given up
noteEscape :: RtCounts -> String -> String -> IO ()
noteEscape ref kind why = do
  m <- readIORef ref
  when (not (M.member kind m)) $
    hPutStrLn stderr ("[sol] REALTIME: " ++ kind ++ " — " ++ why)
  atomicModifyIORef' ref (\mm -> (M.insertWith (+) kind 1 mm, ()))

rtTotal :: RtCounts -> IO Int
rtTotal ref = sum . M.elems <$> readIORef ref

rtReport :: RtCounts -> IO [String]
rtReport ref = do
  m <- readIORef ref
  pure [k ++ " x" ++ show n | (k, n) <- M.toList m]

-- A realtime write steps outside the transaction for that path, so the
-- transaction must stop making claims about it: drop any snapshot we took.
-- Without this, `s = readPath p; u = appendNow p line` would invalidate its
-- own read set and retry forever. Returns True if a claim was actually
-- dropped, so the caller can say so.
txForget :: IORef TxState -> FilePath -> IO Bool
txForget ref p = atomicModifyIORef' ref $ \s ->
  ( s { txReads = M.delete p (txReads s), txView = M.delete p (txView s) },
    M.member p (txReads s) || M.member p (txView s)
  )

-- read the disk NOW, with no snapshot: repeated calls can differ
rtRead :: FilePath -> IO (Maybe String)
rtRead = diskRead

rtWrite :: IORef TxState -> FilePath -> String -> IO Bool
rtWrite ref p v = do
  dropped <- txForget ref p
  writeFile p v
  pure dropped

rtAppend :: IORef TxState -> FilePath -> String -> IO Bool
rtAppend ref p v = do
  dropped <- txForget ref p
  appendFile p v
  pure dropped

-- inherit stdio so output streams to the terminal as it is produced;
-- only the exit code comes back
rtShell :: String -> IO Int
rtShell cmd = do
  hFlush stdout
  (_, _, _, ph) <- createProcess (shell cmd)
  code <- waitForProcess ph
  pure (case code of ExitSuccess -> 0; ExitFailure n -> n)

-- one line from stdin, now; "" at end of input
rtLine :: IO String
rtLine = do
  hFlush stdout
  eof <- hIsEOF stdin
  if eof then pure "" else hGetLine stdin

-- ---- the stdin snapshot ----------------------------------------------------
--
-- `input` is transactional the same way a file read is: the FIRST call
-- slurps stdin into a process-wide snapshot and every later call — and
-- every RETRY — answers from it. (Before this, a retry re-slurped a
-- consumed handle and died with a raw hGetContents' error: stdin was the
-- one read the transaction forgot to snapshot.) The cache survives
-- resetTx on purpose: the retried script must see the same input.

{-# NOINLINE stdinSnap #-}
stdinSnap :: IORef (Maybe String)
stdinSnap = unsafePerformIO (newIORef Nothing)

txInput :: IO String
txInput = do
  c <- readIORef stdinSnap
  case c of
    Just s -> pure s
    Nothing -> do
      s <- hGetContents' stdin
      writeIORef stdinSnap (Just s)
      pure s

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
  let tmp = p ++ ".sol-tmp"
  writeFile tmp v
  fsyncPath tmp
  renamePath tmp p
  fsyncPath (parentOf p)

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
              when recover (recoverJournal False jL) `finally` removePathForcibly claim
      _ -> pure ()

release :: FilePath -> IO ()
release p = do
  _ <- try (removePathForcibly (lockPath p)) :: IO (Either IOException ())
  pure ()

withLocks :: (FilePath -> IO ()) -> [FilePath] -> IO a -> IO a
withLocks takeLock paths action = mask $ \restore -> do
  acquired <- acquireAll paths
  restore action `finally` forM_ (reverse acquired) release
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
writeJournal j effs = writeAtomic j (unlines ["SOLJ1", show effs, "COMMIT"])

parseJournal :: String -> Maybe [Effect]
parseJournal txt = case lines txt of
  ("SOLJ1" : effsL : "COMMIT" : _) -> case reads effsL of
    [(es, rest)] | all (`elem` " \t") rest -> Just es
    _ -> Nothing
  _ -> Nothing

readDone :: FilePath -> IO [Int]
readDone j = do
  r <- try (readFile' (donePath j)) :: IO (Either IOException String)
  case r of
    Left e
      | isDoesNotExistError e -> pure []
      | otherwise -> throwIO e
    Right txt -> pure (mapMaybe readMaybe (lines txt))

markDone :: FilePath -> Int -> IO ()
markDone j i = do
  appendFile (donePath j) (show i ++ "\n")
  fsyncPath (donePath j)

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
    case parseJournal txt of
      Nothing -> do
        hPutStrLn stderr ("[sol] discarding incomplete journal " ++ j ++ " (crash before the commit point; the transaction never took effect)")
        clearJournal j
      Just effs -> do
        let touched = sort (nub [p | e <- effs, Just p <- [effectPath e]])
            recover = do
              stillThere <- doesFileExist j -- a concurrent reclaimer may have finished it
              when stillThere $ do
                done <- readDone j
                hPutStrLn stderr ("[sol] recovering interrupted commit from " ++ j ++ " (" ++ show (length effs) ++ " effect(s), " ++ show (length done) ++ " shell(s) already done)")
                _ <- replayEffs j True done Nothing (zip [0 ..] effs)
                clearJournal j -- file effects all applied even past a failed shell
        if takeLocks
          then withLocks (acquireGo False j) touched recover
          else recover

-- ---- commit ---------------------------------------------------------------

-- Committed carries (applied file effects, deferred commands/processes
-- that ran, a deferred command failed); the receipt only says
-- "atomically" when the last is False
data CommitResult = Committed Int Int Bool | Conflict [FilePath]

effectPath :: Effect -> Maybe FilePath
effectPath (EWrite p _) = Just p
effectPath (ERemove p) = Just p
effectPath (EMkdir p) = Just p
effectPath (ERmdir p) = Just p
effectPath (EShell _) = Nothing
effectPath (EProcess _) = Nothing

-- lock (sorted) -> validate reads AND dir listings -> journal the effect
-- log (fsynced; the commit point) -> replay it in order -> clear the
-- journal -> unlock. Deferred shell commands run inside the commit, after
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
                M.fromList [(p, ()) | e <- effs, Just p <- [effectPath e]]
              ]
          )
  withLocks (acquire jpath) touched $ do -- sorted: global lock order
    staleC <-
      foldM
        ( \acc (p, snap) -> do
            now <- diskRead p
            pure (if now == snap then acc else p : acc)
        )
        []
        (M.toList (txReads s))
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
    let stale = staleC ++ staleD
    if null stale
      then do
        crashAt <- (>>= readMaybe) <$> lookupEnv "SOL_CRASH_AT"
        when (not (null effs)) (writeJournal jpath effs)
        (n, sfail) <- replayEffs jpath False [] crashAt (zip [0 ..] effs)
        clearJournal jpath
        -- a `run` PARENT set SOL_REPORT_COMMIT so it can learn which
        -- paths this child transaction committed (Mod.runModule reads
        -- the marker off stderr and checks them against its own sets)
        reportC <- lookupEnv "SOL_REPORT_COMMIT"
        let wrotePaths = nub [p | e <- effs, Just p <- [effectPath e]]
        when (reportC == Just "1" && not (null wrotePaths)) $
          hPutStrLn stderr (childCommitMarker ++ show wrotePaths)
        let ncmd = length [() | e <- effs, Nothing <- [effectPath e]]
        pure (Committed n ncmd sfail)
      else pure (Conflict stale)

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
  let dirOf p = case dropWhileEnd (/= '/') p of
        "" -> "."
        "/" -> "/"
        d -> init d -- drop the trailing '/': ls keys are written bare
      hit p =
        M.member p (txReads s)
          || M.member p (txView s)
          || M.member (dirOf p) (txDirReads s)
  pure (filter hit ps)

-- names in a listing that exist only because this commit's lock protocol
-- created them: proper ancestors of a touched path, containing nothing
-- but lock artifacts (recursively). A foreign txn that put real content
-- there is still a conflict.
filterOutProtocolDirs :: FilePath -> [FilePath] -> [String] -> IO [String]
filterOutProtocolDirs dir touched = go
  where
    go [] = pure []
    go (n : rest) = do
      let full = dir ++ "/" ++ n
          ancestor = any (\t -> (full ++ "/") `isPrefixOf` t) touched
      drop' <-
        if ancestor
          then do
            isD <- doesDirectoryExist full
            if isD then protocolOnly full else pure False
          else pure False
      rest' <- go rest
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

-- .sol-lock dirs, reclaim renames, and .sol-tmp staging files are
-- commit-protocol artifacts: invisible to validation and to txLs
lockArtifact :: FilePath -> Bool
lockArtifact n =
  ".sol-lock" `isSuffixOf` n
    || ".sol-tmp" `isSuffixOf` n
    || ".sol-lock.reclaim." `isInfixOf` n

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
-- have depended on the failed one), each named. The Bool that comes
-- back says a command failed, so the receipt can refuse the word
-- "atomically".
replayEffs :: FilePath -> Bool -> [Int] -> Maybe Int -> [(Int, Effect)] -> IO (Int, Bool)
replayEffs j0 recovery0 done0 crashAt0 effs0 = go False effs0
  where
    go shellFailed [] = pure (0, shellFailed)
    go shellFailed ((i, e) : rest) = do
      case crashAt0 of
        Just k | k == i -> do
          hPutStrLn stderr ("[sol] SOL_CRASH_AT=" ++ show k ++ ": hard exit before effect " ++ show k)
          hFlush stderr
          c_hardExit 137
        _ -> pure ()
      case e of
        EWrite p v -> writeAtomic p v >> rec' shellFailed 1 rest
        ERemove p -> do
          _ <- try (removeFile p) :: IO (Either IOException ())
          still <- doesFileExist p
          if still
            then failedEff ("rm " ++ p ++ " (still exists)") >> rec' shellFailed 0 rest
            else rec' shellFailed 1 rest
        EMkdir p -> createDirectoryIfMissing True p >> rec' shellFailed 1 rest
        ERmdir p -> do
          _ <- try (removeDirectory p) :: IO (Either IOException ())
          still <- doesDirectoryExist p
          if still
            then failedEff ("rmdir " ++ p ++ " (still exists — not empty?)") >> rec' shellFailed 0 rest
            else rec' shellFailed 1 rest
        EShell cmd
          | shellFailed -> do
              putStrLn ("[sol] skipping queued command (an earlier one failed): " ++ cmd)
              rec' shellFailed 0 rest
          | recovery0 && i `elem` done0 -> do
              hPutStrLn stderr ("[sol] redo: skipping already-run command: " ++ cmd)
              rec' shellFailed 0 rest
          | otherwise -> do
              when recovery0 $ hPutStrLn stderr ("[sol] redo: re-running deferred command (at-least-once): " ++ cmd)
              (code, out) <- txSh cmd
              markDone j0 i
              unless (null out) (putStr ("[sol] $ " ++ cmd ++ "\n" ++ out))
              if code == 0
                then rec' shellFailed 0 rest
                else do
                  putStrLn ("[sol] deferred command FAILED (exit " ++ show code ++ "): " ++ cmd)
                  putStrLn ("[sol] later queued commands will be skipped; file effects still apply")
                  rec' True 0 rest
        EProcess spec
          | shellFailed -> do
              putStrLn ("[sol] skipping queued process (an earlier one failed): " ++ displayProcess spec)
              rec' shellFailed 0 rest
          | recovery0 && i `elem` done0 -> do
              hPutStrLn stderr ("[sol] redo: skipping already-run process: " ++ displayProcess spec)
              rec' shellFailed 0 rest
          | otherwise -> do
              when recovery0 $ hPutStrLn stderr ("[sol] redo: re-running deferred process (at-least-once): " ++ displayProcess spec)
              result <- runProcessSpec spec
              markDone j0 i
              case result of
                Left err -> do
                  putStrLn ("[sol] deferred process FAILED: " ++ displayProcess spec ++ ": " ++ err)
                  putStrLn "[sol] later queued commands will be skipped; file effects still apply"
                  rec' True 0 rest
                Right (code, out, err) -> do
                  unless (null out) (putStr out)
                  unless (null err) (hPutStr stderr err)
                  if code == 0
                    then rec' shellFailed 0 rest
                    else do
                      putStrLn ("[sol] deferred process FAILED (exit " ++ show code ++ "): " ++ displayProcess spec)
                      putStrLn "[sol] later queued commands will be skipped; file effects still apply"
                      rec' True 0 rest
    failedEff what = putStrLn ("[sol] effect FAILED (not counted): " ++ what)
    rec' sf k rest = do
      (n, sf') <- go sf rest
      pure (k + n, sf')
