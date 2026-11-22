{-# LANGUAGE TupleSections, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Sol.Escapes -- everything a transaction run does OUTSIDE the
-- transaction: realtime escapes and their accounting, the process
-- plumbing shell and deferred commands share, and the stdin snapshot.
-- These observe or act on the world directly and never participate in
-- validation; Sol.Txn imports this layer to publish buffered effects.
module Sol.Escapes (module Sol.Escapes, module Sol.TxnState, module Sol.Effects) where
{-# LANGUAGE TupleSections, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Txn.hs -- the commit protocol that publishes a TxnState: locks, the redo
-- journal and its recovery, the Git saga, realtime escapes, process
-- plumbing, and the commit itself (validate under lock, journal, replay,
-- unlock). The transaction's state and filesystem layer lives in
-- Sol.TxnState (one-way import, no cycles).


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

import Sol.TxnState

-- ---- external commands -----------------------------------------------------

-- Immediate arbitrary commands. Output is not validated at commit; the VM
-- marks external work before calling. Repetition requires a caller assertion
-- or explicit legacy retry policy. Both channels have bounded text capture.
txSh :: String -> IO (Int, String)
txSh cmd = do
  result <- runProcessSpec (ProcessSpec ["/bin/sh", "-c", cmd] Nothing [] "" Nothing)
  either (ioError . userError) (\(c,out,err) -> pure (c,out ++ err)) result

-- the separated-channel form behind Try.sh: (code, stdout, stderr), or
-- Left when the shell itself could not be spawned.
txShFull :: String -> IO (Either String (Int, String, String))
txShFull cmd = runProcessSpec (ProcessSpec ["/bin/sh", "-c", cmd] Nothing [] "" Nothing)

-- queued: for MUTATING commands (git commit, docker rm). Runs at COMMIT,
-- after validation, interleaved in declaration order with file effects.
-- On retry the queue is discarded: the world was never touched.
txShq :: IORef TxState -> String -> IO ()
txShq ref cmd = pushEffect ref (EShell cmd)

-- Structured process execution. Unlike sh/shq, argv never crosses a shell,
-- stdout and stderr stay separate, and environment entries override rather
-- than replace the inherited environment. A non-positive timeout means none.
-- All structured children have a process group so timeout/cancellation can
-- kill descendants which inherited pipes. A deliberately detached session is
-- outside this ownership boundary. Successful children may leave background jobs.
data ProcessIO = CaptureIO | StreamIO | InheritIO deriving (Eq)

runProcessSpec :: ProcessSpec -> IO (Either String (Int, String, String))
runProcessSpec = runProcessMode CaptureIO

runProcessMode :: ProcessIO -> ProcessSpec -> IO (Either String (Int, String, String))
runProcessMode CaptureIO spec = case ScriptIO.encodeUtf8 (psStdin spec) of
  Left why -> pure (Left why)
  Right bytes -> do
    let pipeline = Process.Pipeline [spec {psStdin="", psTimeoutMs=Nothing}] (Process.InputBytes bytes)
          (Process.CaptureUtf8 1048576) (Process.CaptureUtf8 1048576) (maybe 0 id (psTimeoutMs spec)) Process.LastStage
    result <- Process.run pipeline
    pure $ case result of
      Left (Process.Failure "timeout" _ _ ms) -> Left ("timed out after " ++ show ms ++ "ms")
      Left (Process.Failure why stage channel cap) -> Left (why ++ " (stage " ++ show stage ++ ", " ++ channel ++ ", limit " ++ show cap ++ ")")
      Right (Process.Result code _ out [err]) -> do
        textOut <- ScriptIO.decodeUtf8 out
        textErr <- ScriptIO.decodeUtf8 err
        Right (code,textOut,textErr)
      Right _ -> Left "process runner returned an invalid capture shape"
runProcessMode mode spec = case psArgv spec of
  [] -> pure (Left "process argv is empty")
  _ | mode == InheritIO && not (null (psStdin spec)) ->
      pure (Left "inherited stdin cannot be combined with ProcessSpec stdin text")
  exe : args -> do
    inherited <- getEnvironment
    let mergedEnv = M.toList (M.union (M.fromList (psEnv spec)) (M.fromList inherited))
        cp = (proc exe args)
          { cwd = psCwd spec,
            env = if null (psEnv spec) then Nothing else Just mergedEnv,
            std_in = if mode == InheritIO then Inherit else CreatePipe,
            std_out = if mode == CaptureIO then CreatePipe else Inherit,
            std_err = if mode == CaptureIO then CreatePipe else Inherit,
            create_group = True }
        run = mask $ \restore -> do
          tty <- if mode == InheritIO then hIsTerminalDevice stdin else pure False
          owner <- if tty then do
            ours <- getProcessGroupID
            foreground <- getTerminalProcessGroupID stdInput
            unless (ours == foreground) $ ioError (userError "inherited terminal requires a foreground caller")
            pure (Just ours)
            else pure Nothing
          (hin, hout, herr, child) <- createProcess cp
          group <- getPid child
          let closePipes = mapM_ (maybe (pure ()) (ignoreProcessIO . hClose)) [hin, hout, herr]
              cancel = do
                -- SIGKILL makes cancellation bounded even for TERM-ignoring
                -- descendants. Save the group ID before the leader can exit.
                maybe (ignoreProcessIO (terminateProcess child))
                  (ignoreProcessIO . signalProcessGroup sigKILL) group
                ignoreProcessIO (waitForProcess child >> pure ())
              input = case hin of
                Nothing -> pure ()
                Just h -> (hPutStr h (psStdin spec) `catch` \e ->
                  if isResourceVanishedError e then pure () else throwIO e)
                  `finally` ignoreProcessIO (hClose h)
              readOutput = maybe (pure "") hGetContents'
              restoreTerminal = maybe (pure ()) (ignoreProcessIO . foregroundProcess) owner
              body = do
                case (owner, group) of
                  (Just _, Just gid) -> do
                    foregroundProcess gid
                    -- The child might have read before the handoff and stopped.
                    ignoreProcessIO (signalProcessGroup sigCONT gid)
                  _ -> pure ()
                ((out, err), (_, code)) <- processConcurrently
                  (processConcurrently (readOutput hout) (readOutput herr))
                  (processConcurrently input (waitForProcess child))
                pure (code, out, err)
          -- Cancel/reap before closing handles. Concurrent workers have already
          -- been joined by processConcurrently, so no handle locks remain.
          restore body `onException` cancel `finally` (restoreTerminal >> closePipes)
        timed = case psTimeoutMs spec of
          Just ms | ms > 0 -> timeout (fromInteger (min (toInteger (maxBound :: Int)) (toInteger ms * 1000))) run
          _ -> Just <$> run
    result <- try timed :: IO (Either IOException (Maybe (ExitCode, String, String)))
    pure $ case result of
      Left e -> Left (show e)
      Right Nothing -> Left ("timed out after " ++ show (maybe 0 id (psTimeoutMs spec)) ++ "ms")
      Right (Just (code, out, err)) ->
        Right (case code of ExitSuccess -> 0; ExitFailure n -> n, out, err)

-- Restoring the parent's foreground group runs while it is in the background.
-- Block SIGTTOU around tcsetpgrp, then restore the previous signal mask.
foregroundProcess :: ProcessGroupID -> IO ()
foregroundProcess group = bracket getSignalMask setSignalMask $ \_ -> do
  blockSignals (addSignal sigTTOU emptySignalSet)
  setTerminalProcessGroupID stdInput group

ignoreProcessIO :: IO () -> IO ()
ignoreProcessIO action = action `catch` (\(_ :: IOException) -> pure ())

-- Structured concurrency using base: either worker failure interrupts the
-- other; cancellation joins both before returning to the process owner.
processConcurrently :: IO a -> IO b -> IO (a, b)
processConcurrently left right = mask $ \restore -> do
  done <- newChan
  exitedA <- newEmptyMVar
  exitedB <- newEmptyMVar
  a <- forkIOWithUnmask $ \unmask ->
    (tryProcessAny (unmask left) >>= writeChan done . Left) `finally` putMVar exitedA ()
  b <- forkIOWithUnmask $ \unmask ->
    (tryProcessAny (unmask right) >>= writeChan done . Right) `finally` putMVar exitedB ()
  let finish = do
        first <- readChan done
        case first of
          Left (Left e) -> throwIO e
          Right (Left e) -> throwIO e
          Left (Right x) -> do
            second <- readChan done
            case second of
              Right y -> (x,) <$> either throwIO pure y
              _ -> error "process worker reported twice"
          Right (Right y) -> do
            second <- readChan done
            case second of
              Left x -> (,y) <$> either throwIO pure x
              _ -> error "process worker reported twice"
      stop = killThread a >> killThread b >> takeMVar exitedA >> takeMVar exitedB
  restore finish `finally` stop

tryProcessAny :: IO a -> IO (Either SomeException a)
tryProcessAny = try

txProcessAfterCommit :: IORef TxState -> ProcessSpec -> IO ()
txProcessAfterCommit ref spec = pushEffect ref (EProcess spec)


-- ---- REALTIME ESCAPES (outside the transaction) ---------------------------
--
-- Buffered file reads/writes snapshot and defer, respectively. Immediate
-- process/I/O calls are outside rollback. Guarded retry prevents repeating
-- immediate external work unless its caller explicitly accepts replay.
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
-- transaction later rolls back, can happen again under explicit replay/legacy,
-- and its result is not validated at commit. The counter exists so a run that
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
txForget ref raw = do
  p <- stableWorldPath raw
  atomicModifyIORef' ref $ \s ->
    ( s { txReads = M.delete p (txReads s), txReadBytes = M.delete p (txReadBytes s), txView = M.delete p (txView s), txMetaReads = M.delete p (txMetaReads s) },
      M.member p (txReads s) || M.member p (txView s) || M.member p (txMetaReads s)
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
  result <- runProcessMode InheritIO (ProcessSpec ["/bin/sh","-c",cmd] Nothing [] "" Nothing)
  either (ioError . userError) (\(code,_,_) -> pure code) result

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

