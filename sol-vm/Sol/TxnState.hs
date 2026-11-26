{-# LANGUAGE TupleSections, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Sol.TxnState -- the transaction's state and filesystem layer.
--
-- TxState and its in-transaction views, the exact-byte content
-- snapshots, the metadata-promise store, the filesystem operations and
-- their typed error model, temp-dir ownership, and the effect log.
-- Everything here is the part of a transaction that OBSERVES and
-- BUFFERS; the commit protocol that publishes the buffered effects
-- (locks, journal, replay, saga, realtime escapes) lives in Sol.Txn,
-- which imports this module -- one-way, no cycles.
module Sol.TxnState (module Sol.TxnState, module Sol.Effects) where

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

-- a metadata promise: what a metadata query (exists/isDir/stat/statKind/
-- lstat) recorded about a path it did NOT read. Every field is promised
-- in a MODALITY: followed presence/kind/size/mtime from stat-style
-- queries, no-follow presence/kind from lstat. Commit rechecks exactly
-- the promised fields in their own modality — an lstat promise never
-- conflicts over what the link points at. Nothing here claims content
-- equality from size/mtime: content reads keep exact-byte validation
-- (txReadBytes).
data MetaSnap = MetaSnap
  { msPresentF :: Maybe Bool, -- followed presence; exists/stat/statKind/isDir
    msPresentL :: Maybe Bool, -- no-follow presence; lstat
    msKind :: Maybe Int, -- followed kind (0 file, 1 dir, 3 other)
    msKindL :: Maybe Int, -- no-follow kind (2 link, ...)
    msIsDir :: Maybe Bool, -- isDir promises a predicate, not an exact kind
    msSize :: Maybe Integer, -- promised by stat only
    msMtime :: Maybe Integer, -- promised by stat only
    msFollowTarget :: Maybe FilePath, -- directory stat resolves to this lock identity
    msChanged :: Bool -- incompatible observations in one attempt must retry
  }

-- the nothing-promised promise, so every query records with record-update
-- syntax and no field is accidentally left as a runtime bottom
noMeta :: MetaSnap
noMeta = MetaSnap Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing False

-- kind codes shared by FsKind (prelude) and the walker; 2 = link is only
-- observable without following
kindFile, kindDir, kindLink, kindOther :: Int
kindFile = 0
kindDir = 1
kindLink = 2
kindOther = 3

data RetryPolicy = GuardedRetry | LegacyRetry deriving (Eq, Show)

parseRetryPolicy :: String -> Either String RetryPolicy
parseRetryPolicy "guarded" = Right GuardedRetry
parseRetryPolicy "legacy" = Right LegacyRetry
parseRetryPolicy value = Left ("invalid retry policy " ++ show value ++ "; use guarded or legacy")

retryPolicyName :: RetryPolicy -> String
retryPolicyName GuardedRetry = "guarded"
retryPolicyName LegacyRetry = "legacy"

data TxState = TxState
  { txReads :: M.Map FilePath (Maybe String), -- decoded snapshot for repeat reads
    txReadBytes :: M.Map FilePath (Maybe BS.ByteString), -- exact validation snapshot
    txMetaReads :: M.Map FilePath MetaSnap, -- metadata promises (never a content read)
    txDirReads :: M.Map FilePath [String], -- directory listings taken
    txEffects :: [Effect], -- REVERSED effect log
    txView :: M.Map FilePath (Maybe String), -- current in-txn file view
    txDirView :: M.Map FilePath Bool, -- dirs mkdir'd (True) / rmdir'd (False)
    txHandles :: IM.IntMap FilePath, -- open handle id -> path
    txNextH :: !Int,
    txNonText :: S.Set FilePath, -- snapshotted paths that are NOT valid UTF-8
    txSealed :: !Bool, -- commit has read the effect log; later effects are lost
    txIdentity :: Maybe Unique,
    txNextStep :: !Int,
    txTerminal :: !Bool,
    txPathLogs :: [(FilePath,String)],
    txSagaJournal :: Maybe FilePath,
    txTemps :: [FilePath], -- owned scratch paths; swept on discard/exit
    txIO :: Maybe ScriptIO.Runtime,
    txProcesses :: Maybe Process.Runtime,
    txRetryPolicy :: RetryPolicy,
    txExternal :: S.Set String,
    txReplayableThreads :: M.Map ThreadId Int,
    txSaga :: Maybe GitUndo,
    txPivot :: !Bool,
    txLogs :: [String], -- REVERSED `log` lines: emitted only after a clean commit
    txBytesView :: M.Map FilePath BS.ByteString -- this txn's own writeBytes, exact
  }

newTx :: IO (IORef TxState)
newTx = do
  identity <- newUnique
  runtime <- ScriptIO.newRuntime
  processes <- Process.newRuntime
  newIORef emptyTx {txIdentity = Just identity, txIO = Just runtime, txProcesses=Just processes}

emptyTx :: TxState
emptyTx = TxState
  { txReads=M.empty, txReadBytes=M.empty, txMetaReads=M.empty, txDirReads=M.empty
  , txEffects=[], txView=M.empty, txDirView=M.empty
  , txHandles=IM.empty, txNextH=1, txNonText=S.empty, txSealed=False
  , txIdentity=Nothing, txNextStep=0, txTerminal=False, txPathLogs=[]
  , txSagaJournal=Nothing, txTemps=[], txIO=Nothing, txProcesses=Nothing, txRetryPolicy=GuardedRetry
  , txExternal=S.empty, txReplayableThreads=M.empty, txSaga=Nothing, txPivot=False, txLogs=[], txBytesView=M.empty
  }

txRuntime :: IORef TxState -> IO ScriptIO.Runtime
txRuntime ref = readIORef ref >>= maybe (ioError (userError "missing script I/O runtime")) pure . txIO

txProcessRuntime :: IORef TxState -> IO Process.Runtime
txProcessRuntime ref = readIORef ref >>= maybe (ioError (userError "missing process runtime")) pure . txProcesses

txCleanupProcesses :: IORef TxState -> IO ()
txCleanupProcesses ref = readIORef ref >>= mapM_ Process.closeRuntime . txProcesses

txCleanup :: IORef TxState -> IO ()
txCleanup ref = do
  state <- readIORef ref
  txCleanupProcesses ref `finally` (mapM_ ScriptIO.closeRuntime (txIO state) `finally` txCleanupTemps ref)

txSetRetryPolicy :: IORef TxState -> RetryPolicy -> IO ()
txSetRetryPolicy ref policy = modifyIORef' ref (\s -> s {txRetryPolicy = policy})

-- Mark before attempting the effect: an exception/spawn failure cannot
-- prove that nothing externally visible happened. Replay assertions are
-- thread-scoped so one actor cannot bless another actor's effects.
txMarkExternal :: IORef TxState -> String -> IO ()
txMarkExternal ref name = do
  tid <- myThreadId
  atomicModifyIORef' ref $ \s ->
    (if M.findWithDefault 0 tid (txReplayableThreads s) > 0 then s
     else s {txExternal = S.insert name (txExternal s)}, ())

txReplayableScope :: IORef TxState -> IO a -> IO a
txReplayableScope ref action = mask $ \restore -> do
  tid <- myThreadId
  atomicModifyIORef' ref (\s -> (s {txReplayableThreads = M.insertWith (+) tid 1 (txReplayableThreads s)}, ()))
  restore action `finally` atomicModifyIORef' ref (\s ->
    (s {txReplayableThreads = M.update (\n -> if n <= 1 then Nothing else Just (n-1)) tid (txReplayableThreads s)}, ()))

txRetryRefusal :: IORef TxState -> IO [String]
txRetryRefusal ref = do
  state <- readIORef ref
  pure (if txRetryPolicy state == GuardedRetry then S.toList (txExternal state) else [])

-- an effect issued after commit sealed the log (an actor thread that
-- outlived program order) can only be lost — name it, loudly
pushEffect :: IORef TxState -> Effect -> IO ()
pushEffect ref rawEffect = do
  e <- captureEffect rawEffect
  result <- atomicModifyIORef' ref $ \s ->
    if txSealed s || txTerminal s then (s, Left "effect after commit or terminal Git.push")
    else (s {txEffects=e:txEffects s, txNextStep=txNextStep s+1, txTerminal=isPush e}, Right ())
  either (ioError . userError) pure result

txLater :: IORef TxState -> DeferredStep -> IO (Unique, DeferredRef)
txLater ref rawStep = do
  step <- captureStep rawStep
  result <- atomicModifyIORef' ref $ \s ->
    if txSealed s || txTerminal s then (s, Left "effect after commit or terminal Git.push")
    else case txIdentity s of
      Nothing -> (s, Left "missing transaction identity")
      Just owner -> (s {txEffects=ELater step:txEffects s, txNextStep=txNextStep s+1,
                        txTerminal=isPush (ELater step)}, Right (owner, DeferredRef (txNextStep s) []))
  either (ioError . userError) pure result

txLogTo :: IORef TxState -> FilePath -> String -> IO ()
txLogTo ref rawPath line = do
  path <- stableWorldPath rawPath
  link <- (PF.isSymbolicLink <$> PF.getSymbolicLinkStatus path) `catch` \e ->
    if isDoesNotExistError e then pure False else throwIO (e :: IOException)
  when link $ ioError (userError ("logTo: refusing symbolic link: " ++ path))
  ok <- atomicModifyIORef' ref $ \s -> if txSealed s then (s,False)
    else (s {txPathLogs=(path,line):txPathLogs s},True)
  unless ok $ ioError (userError "logTo after commit")

txMarkPivot :: IORef TxState -> IO ()
txMarkPivot ref = do
  allowed <- atomicModifyIORef' ref $ \s ->
    if txSaga s /= Nothing then (s,False) else (s {txPivot=True},True)
  unless allowed $ ioError (userError "immediate pivot after compensable Git commit refused; queue it for commit instead")

-- Capture interpretation context while the script runs. Recovery may be
-- launched from another directory; argv text stays literal, while process
-- cwd and file/Git paths in a new plan have stable absolute identities.
-- Resolve parent aliases (including macOS /var versus /private/var), but
-- keep the leaf itself: write/rm/archive must not follow a leaf symlink.
-- A trailing separator retains its directory-only OS interpretation.
stableWorldPath :: FilePath -> IO FilePath
stableWorldPath path = do
  absolute <- makeAbsolute path
  if takeFileName absolute `elem` [".", ".."] then canonicalizePath absolute
  else if hasTrailingPathSeparator absolute then pure absolute else do
    parent <- canonicalizePath (takeDirectory absolute)
    pure (parent </> takeFileName absolute)

captureProcessSpec :: ProcessSpec -> IO ProcessSpec
captureProcessSpec spec = do
  cwd <- maybe getCurrentDirectory makeAbsolute (psCwd spec)
  pure spec {psCwd=Just cwd}

captureGit :: GitRequest -> IO GitRequest
captureGit (GitRequest path op arg name email paths limit) = do
  absolute <- canonicalizePath path
  pure (GitRequest absolute op arg name email paths limit)

captureStep :: DeferredStep -> IO DeferredStep
captureStep (PlannedProcess args spec) = PlannedProcess args <$> captureProcessSpec spec
captureStep (PlannedGit request) = PlannedGit <$> captureGit request
captureStep (PlannedTag path name ref limit) = do
  absolute <- canonicalizePath path
  pure (PlannedTag absolute name ref limit)

captureEffect :: Effect -> IO Effect
captureEffect (EWrite path value) = (\p -> EWrite p value) <$> stableWorldPath path
captureEffect (EWriteBytes path value) = (\p -> EWriteBytes p value) <$> stableWorldPath path
captureEffect (ERemove path) = ERemove <$> stableWorldPath path
captureEffect (EMkdir path) = EMkdir <$> stableWorldPath path
captureEffect (ERmdir path) = ERmdir <$> stableWorldPath path
captureEffect (EShell cmd) = (\cwd -> EShellAt cwd cmd) <$> getCurrentDirectory
captureEffect (EProcess spec) = EProcess <$> captureProcessSpec spec
captureEffect (EGit request) = EGit <$> captureGit request
captureEffect archive@EArchive{} = pure archive -- archive member names retain their existing path spelling
captureEffect (ELater step) = ELater <$> captureStep step
captureEffect other = pure other

-- `log`: a transactional line. `print` is a direct effect (it happens
-- when called, repeats on retry, survives an abort); a log line records
-- something the run DID, so it waits for the commit: discarded with the
-- attempt on retry or panic, emitted once, and only when every effect
-- reached its goal state. It lives beside the effect log, not in it, so a
-- redo by another process never prints this run's lines.
txLog :: IORef TxState -> String -> IO ()
txLog ref line = do
  sealed <- atomicModifyIORef' ref (\s -> (s {txLogs = line : txLogs s}, txSealed s))
  when sealed $
    hPutStrLn stderr ("[sol] log AFTER COMMIT (lost): " ++ line ++ " — join actors before the script ends")

txTakeLogs :: IORef TxState -> IO [String]
txTakeLogs ref = reverse . txLogs <$> readIORef ref

-- one-line description of a queued effect, for the diagnostics that have
-- to name what is still pending
effectBrief :: Effect -> String
effectBrief (EWrite p _) = "write " ++ p
effectBrief (EWriteBytes p _) = "write bytes " ++ p
effectBrief (ERemove p) = "rm " ++ p
effectBrief (EMkdir p) = "mkdirp " ++ p
effectBrief (ERmdir p) = "rmdir " ++ p
effectBrief (EShellAt _ c) = "shq " ++ c
effectBrief (EShell c) = "shq " ++ c
effectBrief (EProcess spec) = "Proc.afterCommit " ++ displayProcess spec
effectBrief (EGit (GitRequest path op _ _ _ _ _)) = "native Git " ++ show op ++ " in " ++ path
effectBrief (ELater (PlannedProcess args _)) = "Proc.later " ++ case args of
  LiteralArg exe:_ -> show exe
  FromArg (DeferredRef i _):_ -> "<executable from step " ++ show i ++ ">"
  [] -> "<empty argv>"
effectBrief (ELater (PlannedGit (GitRequest path op _ _ _ _ _))) =
  (case op of 14 -> "Git.headLater"; 15 -> "Git.push"; _ -> "native Git") ++ " in " ++ path
effectBrief (ELater (PlannedTag path name _ _)) = "Git.tagAt " ++ name ++ " in " ++ path
effectBrief (ELogWrite p _) = "transactional log " ++ p
effectBrief (EArchive source target _ _) = "native archive " ++ source ++ " -> " ++ target

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
    ++ (if null deferredSpelling then "" else " Queue it too (" ++ deferredSpelling ++ "), or")
    ++ " move the queued effects into an earlier statement:"
    ++ " each statement commits before the next one starts."

-- Keep exact bytes for validation; decode once for the text-facing API.
-- Comparing bytes is faster and distinguishes invalid UTF-8 sequences which
-- otherwise decode to the same replacement character.
diskReadBytes :: FilePath -> IO (Maybe BS.ByteString)
diskReadBytes p = do
  r <- try (BS.readFile p) :: IO (Either IOException BS.ByteString)
  case r of
    Left e | isDoesNotExistError e -> pure Nothing
           | otherwise -> throwIO e
    Right bs -> pure (Just bs)

decodeSnapshot :: BS.ByteString -> (String, Bool)
decodeSnapshot bs = let t = BSU.toString bs in (t, BSU.fromString t == bs)

diskReadT :: FilePath -> IO (Maybe (String, Bool))
diskReadT p = fmap decodeSnapshot <$> diskReadBytes p

diskRead :: FilePath -> IO (Maybe String)
diskRead p = fmap fst <$> diskReadT p

-- open: register the path, hand back a handle id. Reading is NOT done here;
-- the snapshot happens lazily at first txHRead so a write-only open doesn't
-- inflate the read set (and therefore can't cause a spurious conflict).
txOpen :: IORef TxState -> FilePath -> IO Int
txOpen ref raw = do
  p <- stableWorldPath raw
  atomicModifyIORef' ref $ \s ->
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
-- exact bytes accompany the decoded view. Non-UTF-8 files are remembered as
-- non-text so the read surface can refuse them. Metadata queries (exists/
-- stat/isDir) do NOT snapshot: they record promises in txMetaReads instead.
snapshot :: IORef TxState -> FilePath -> IO (Maybe String)
snapshot ref raw = do
  p <- stableWorldPath raw
  s <- readIORef ref
  case M.lookup p (txReads s) of
    Just snap -> pure snap
    Nothing -> do
      bytes <- diskReadBytes p
      let d = fmap decodeSnapshot bytes
          txt = fmap fst d
          nonText = maybe False (not . snd) d
      atomicModifyIORef' ref
        ( \st ->
            ( st
                { txReads = M.insert p txt (txReads st),
                  txReadBytes = M.insert p bytes (txReadBytes st),
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
txTryRead ref raw = do
  p <- stableWorldPath raw
  s <- readIORef ref
  case (M.lookup p (txBytesView s), M.lookup p (txView s)) of
    (Just b, _) -> pure (either (const TxNonText) TxText (ScriptIO.decodeUtf8 b)) -- this txn's writeBytes
    (Nothing, view) -> txTryReadView ref p view

txTryReadView :: IORef TxState -> FilePath -> Maybe (Maybe String) -> IO TxRead
txTryReadView ref p view =
  case view of
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
  link <- (PF.isSymbolicLink <$> PF.getSymbolicLinkStatus p) `catch` \e ->
    if isDoesNotExistError e then pure False else throwIO (e :: IOException)
  when link $ ioError (userError ("writeAtomic: refusing symbolic link: " ++ p))
  pushEffect ref (EWrite p v)
  atomicModifyIORef' ref (\s -> (s {txView = M.insert p (Just v) (txView s), txDirView = M.delete p (txDirView s), txBytesView = M.delete p (txBytesView s)}, ()))

-- writeBytes: a whole-file write of exact bytes, queued like any write
txWriteBytes :: IORef TxState -> FilePath -> BS.ByteString -> IO ()
txWriteBytes ref raw b = do
  p <- stableWorldPath raw
  link <- (PF.isSymbolicLink <$> PF.getSymbolicLinkStatus p) `catch` \e ->
    if isDoesNotExistError e then pure False else throwIO (e :: IOException)
  when link $ ioError (userError ("writeAtomic: refusing symbolic link: " ++ p))
  pushEffect ref (EWriteBytes p b)
  atomicModifyIORef' ref (\s -> (s {txBytesView = M.insert p b (txBytesView s), txView = M.delete p (txView s), txDirView = M.delete p (txDirView s)}, ()))

-- readBytes: the exact bytes, binary or not: this txn's own write, else the
-- snapshot (taken now, validated at commit like any read)
txReadBytesE :: IORef TxState -> FilePath -> IO (Either String BS.ByteString)
txReadBytesE ref raw = do
  p <- stableWorldPath raw
  s <- readIORef ref
  case (M.lookup p (txBytesView s), M.lookup p (txView s)) of
    (Just b, _) -> pure (Right b)
    (_, Just (Just w)) -> pure (either Left Right (ScriptIO.encodeUtf8 w))
    (_, Just Nothing) -> pure (Left ("no such file: " ++ p))
    _ -> do
      r <- try (snapshot ref p) :: IO (Either IOException (Maybe String))
      case r of
        Left e -> pure (Left (show e))
        Right _ -> do
          s2 <- readIORef ref
          pure $ case M.lookup p (txReadBytes s2) of
            Just (Just b) -> Right b
            _ -> Left ("no such file: " ++ p)

-- ---- path-level transactional ops ----------------------------------------

-- remove: snapshot current state (so a concurrent write aborts us), mark
-- deleted in the view, queue the removal
txRm :: IORef TxState -> FilePath -> IO ()
txRm ref raw = do
  p <- stableWorldPath raw
  _ <- snapshot ref p
  pushEffect ref (ERemove p)
  atomicModifyIORef' ref (\s -> (s {txView = M.insert p Nothing (txView s), txBytesView = M.delete p (txBytesView s)}, ()))

txMkdirp :: IORef TxState -> FilePath -> IO ()
txMkdirp ref raw = do
  p <- stableWorldPath (dropTrailingPathSeparator raw)
  pushEffect ref (EMkdir p)
  markParents p
  where
    -- mkdirp will create absent ancestors too. Reflect that intent in the
    -- pending view so a subsequent walk need not guess the future tree.
    markParents p = do
      atomicModifyIORef' ref (\s -> (s {txDirView = M.insert p True (txDirView s), txView = M.delete p (txView s)}, ()))
      let parent = takeDirectory p
      s <- readIORef ref
      present <- case M.lookup parent (txDirView s) of
        Just b -> pure b
        Nothing -> doesDirectoryExist parent
      unless (present || parent == p) (markParents parent)

txRmdir :: IORef TxState -> FilePath -> IO ()
txRmdir ref raw = do
  p <- stableWorldPath (dropTrailingPathSeparator raw)
  pushEffect ref (ERmdir p)
  atomicModifyIORef' ref (\s -> (s {txDirView = M.insert p False (txDirView s), txView = M.delete p (txView s)}, ()))

-- the hosted filesystem error model: one value answers WHICH operation
-- failed, on WHAT path, and a distinguishable WHY (the typed tier —
-- Try.ls/Try.stat/Try.exists — pattern-matches this; the panicking
-- spellings render it). feNote carries a plain-text hint that only the
-- panic message uses (e.g. "removed earlier in this transaction").
data FsWhy = WhyMissing | WhyDenied | WhyWrongKind | WhyLoop | WhyEncoding | WhyLimit | WhyOther | WhyExists | WhyCrossDevice deriving (Eq)

data FsErr = FsErr
  { feOp :: String, -- "ls" / "stat" / "exists" (also the FsOp constructor)
    fePath :: FilePath,
    feWhy :: FsWhy,
    feMsg :: String, -- the OS report
    feNote :: String -- panic-message hint; "" on the typed tier
  }

fsWhyName :: FsWhy -> String
fsWhyName WhyMissing = "FsMissing"
fsWhyName WhyDenied = "FsDenied"
fsWhyName WhyWrongKind = "FsWrongKind"
fsWhyName WhyLoop = "FsLoop"
fsWhyName WhyEncoding = "FsEncoding"
fsWhyName WhyLimit = "FsLimit"
fsWhyName WhyOther = "FsOther"
fsWhyName WhyExists = "FsExists"
fsWhyName WhyCrossDevice = "FsCrossDevice"

-- errno first (ELOOP/EISDIR/ENOTDIR only exist there); the IOErrorType
-- fallback covers exceptions raised without an errno
classifyIO :: String -> FilePath -> IOException -> FsErr
classifyIO op p e = FsErr op p why (show e) ""
  where
    why = case ioe_errno e of
      Just n
        | Errno n == eEXIST -> WhyExists
        | Errno n == eXDEV -> WhyCrossDevice
        | Errno n == eNOENT -> WhyMissing
        | Errno n == eACCES || Errno n == ePERM -> WhyDenied
        | Errno n == eLOOP || Errno n == eMLINK -> WhyLoop
        | Errno n == eISDIR || Errno n == eNOTDIR -> WhyWrongKind
      _ -> case ioeGetErrorType e of
        NoSuchThing -> WhyMissing
        PermissionDenied -> WhyDenied
        _ -> WhyOther

-- Path resolution is fallible too. Keep the caller's spelling in the
-- public error while using stable keys for the transaction's own view.
fsAt :: String -> FilePath -> IO (Either FsErr a) -> IO (Either FsErr a)
fsAt op path action =
  (either (Left . (\e -> e {fePath = path})) Right <$> action)
    `catch` \(e :: IOException) -> pure (Left (classifyIO op path e))

-- the panic line a plain spelling renders for a classified failure;
-- missing keeps its dedicated guard-hint (or the note) for continuity
fsPanic :: String -> FsErr -> String
fsPanic spelling fe =
  "*** SOL PANIC: " ++ spelling ++ ": " ++ body ++ " ***"
  where
    body = case feWhy fe of
      WhyMissing ->
        "no such " ++ kindOf spelling ++ ": " ++ fePath fe
          ++ (if null (feNote fe) then " — guard with `exists`, or use Try." ++ spelling
                                   else " — " ++ feNote fe)
      _ -> fePath fe ++ ": " ++ feMsg fe ++ " — use Try." ++ spelling
    kindOf "ls" = "directory"
    kindOf _ = "file"

txLs :: IORef TxState -> FilePath -> IO [String]
txLs ref dir = txLsE ref dir >>= either (ioError . userError . fsPanic "ls") pure

-- list a directory: disk listing (validated at commit) composed with this
-- txn's own additions and removals in that directory. sol-lock artifacts
-- are invisible. ABSENCE IS NOT EMPTY: a missing (or this-txn-removed)
-- directory is a typed error; only a pending mkdir may compose over an
-- absent disk listing, because then the entries below are all the
-- directory has.
txLsE :: IORef TxState -> FilePath -> IO (Either FsErr [String])
txLsE ref raw = fsAt "ls" raw $ do
  dir <- stableWorldPath (dropTrailingPathSeparator raw)
  s <- readIORef ref
  let pendingDir = M.lookup dir (txDirView s)
  base <- case pendingDir of
    Just False ->
      pure (Left (FsErr "ls" dir WhyMissing "" "removed earlier in this transaction"))
    _ -> case M.lookup dir (txDirReads s) of
      Just names -> pure (Right names)
      Nothing -> do
        r <- listTextDirectory dir
        case r of
          Left fe
            | feWhy fe == WhyMissing, pendingDir == Just True -> pure (Right [])
            | otherwise -> pure (Left fe)
          Right names0 -> do
            let names = sort (filter (not . lockArtifact) names0)
            atomicModifyIORef' ref (\st -> (st {txDirReads = M.insert dir names (txDirReads st)}, ()))
            pure (Right names)
  case base of
    Left fe -> pure (Left fe)
    Right names -> do
      s2 <- readIORef ref
      let inDir p = takeDir p == dir
          takeDir p = let q = reverse (dropWhile (/= '/') (reverse p)) in if null q then "." else init q
          baseName p = reverse (takeWhile (/= '/') (reverse p))
          added = [baseName p | (p, Just _) <- M.toList (txView s2), inDir p, baseName p `notElem` names]
          removed = [baseName p | (p, Nothing) <- M.toList (txView s2), inDir p]
          addedDirs = [baseName p | (p, True) <- M.toList (txDirView s2), inDir p, baseName p `notElem` names]
          removedDirs = [baseName p | (p, False) <- M.toList (txDirView s2), inDir p]
      pure (Right (sort (S.toList (S.fromList (names ++ added ++ addedDirs)) `without` (removed ++ removedDirs))))
  where
    without xs ys = [x | x <- xs, x `notElem` ys]

-- surrogate-escaped undecodable bytes (GHC's filesystem decode)
badUTF8 :: String -> Bool
badUTF8 = any (\c -> c >= '\xDC80' && c <= '\xDCFF')

-- Read raw entry bytes before decoding: behavior must not depend on the
-- host locale's replacement/escape policy. The stream is closed even when
-- an unsupported name or cancellation interrupts enumeration.
listTextDirectory :: FilePath -> IO (Either FsErr [String])
listTextDirectory dir
  | badUTF8 dir = pure (Left encodingError)
  | otherwise = fsAt "ls" dir $
      bracket (PDB.openDirStream (BSU.fromString dir)) PDB.closeDirStream (\stream -> gather stream [])
  where
    encodingError = FsErr "ls" dir WhyEncoding "non-UTF-8 filename is unsupported" ""
    gather stream names = do
      bytes <- PDB.readDirStream stream
      let (name, valid) = decodeSnapshot bytes
      if BS.null bytes then pure (Right names)
      else if not valid then pure (Left encodingError)
      else if name `elem` [".", ".."] then gather stream names
      else gather stream (name : names)

-- bounded recursive walk. Emits (path, kind, depth) in pre-order with the
-- transaction's own view composed over each listing (txLsE) and each
-- entry kind observed through the promise-recording lstat (txLstatE), so
-- a walk IS a set of dependencies: a foreign change under any walked
-- directory conflicts at commit. Limits are explicit: depth counts the
-- root's children as 1; the entry budget counts every emitted entry.
-- follow=False never descends a symlink (a POSIX directory cannot be
-- hard-linked, so this is cycle-free by construction). follow=True
-- resolves links: the emitted kind is the followed kind, and descent is
-- cut by ancestor identity, so a symlink cycle terminates at the cut.
-- Aliases in different branches may repeat, within the entry budget.
-- Missing entries are errors, never a silently incomplete inventory.
txWalkE :: IORef TxState -> FilePath -> Int -> Int -> Bool
        -> IO (Either FsErr [(FilePath, Int, Int)])
txWalkE ref root maxDepth maxEntries follow = do
  if maxDepth < 1 || maxDepth > 4096 || maxEntries < 1 || maxEntries > 10000000
    then pure (Left (FsErr "walk" root WhyLimit "depth must be 1..4096 and entries 1..10000000" ""))
    else (do
      -- Resolve the parent, retaining the root's leaf for no-follow policy
      -- and pending-view lookup. An explicitly supplied link root follows
      -- only when follow=True, just like a link encountered below it.
      absolute <- stableWorldPath (dropTrailingPathSeparator root)
      kr <- txLstatE ref absolute
      kind <- case kr of
        Right k | k == kindLink && follow -> txStatKindE ref absolute
        _ -> pure kr
      case kind of
        Left fe -> pure (Left (walkError fe))
        Right k | k /= kindDir -> pure (Left (FsErr "walk" root WhyWrongKind "walk root must be a directory" ""))
        _ -> do
          identity <- canonicalizePath absolute
          r <- goE absolute 1 (S.singleton identity) 0 []
          pure (fmap (reverse . fst) r)) `catch` \(e :: IOException) -> pure (Left (classifyIO "walk" root e))
  where
    walkError fe = fe {feOp = "walk"}
    limitErr = FsErr "walk" root WhyLimit ("entry limit of " ++ show maxEntries ++ " reached") ""
    effKind p k
      | not follow || k /= kindLink = pure (Right k)
      | otherwise = do
          r <- txStatKindE ref p
          -- A dangling link is still an inventory entry. Recorded followed
          -- absence makes a target appearing before commit a conflict.
          pure $ case r of Left fe | feWhy fe == WhyMissing -> Right kindLink; _ -> r
    goE dir depth seen n acc = do
      lr <- txLsE ref dir
      case lr of
        Left fe -> pure (Left (walkError fe))
        Right names -> foldNames dir depth seen n acc names
    foldNames _ _ _ n acc [] = pure (Right (acc, n))
    foldNames dir depth seen n acc (nm : rest)
      | n >= maxEntries = pure (Left limitErr)
      | otherwise = do
          let full = dir ++ "/" ++ nm
          kr <- txLstatE ref full
          case kr of
            Left fe -> pure (Left (walkError fe))
            Right k0 -> do
              fk <- effKind full k0
              case fk of
                Left fe -> pure (Left (walkError fe))
                Right k -> do
                  let acc' = (full, k, depth) : acc
                  if k == kindDir && depth < maxDepth
                    then do
                      c <- canonicalizePath full
                      if S.member c seen
                        then foldNames dir depth seen (n + 1) acc' rest
                        else do
                          sub <- goE full (depth + 1) (S.insert c seen) (n + 1) acc'
                          case sub of
                            Left fe -> pure (Left fe)
                            Right (es, n') -> foldNames dir depth seen n' es rest
                    else foldNames dir depth seen (n + 1) acc' rest

-- an owned scratch directory: created NOW (the script writes into it
-- during the run), mode 0700, under the system temp dir, named by
-- prefix plus an unpredictable mkdtemp suffix. Cleanup retains scratch
-- while a durable recovery fence may still need it. A hard crash can
-- strand scratch as well; this is not durable application storage.
txTempDir :: IORef TxState -> String -> IO (Either FsErr FilePath)
txTempDir ref prefix = txTemp ref "tempDir" PT.mkdtemp prefix

txTempFile :: IORef TxState -> String -> IO (Either FsErr FilePath)
txTempFile ref prefix = txTemp ref "tempFile" (\template -> do
  (path, handle) <- PT.mkstemp template
  hClose handle `onException` removeFile path
  pure path) prefix

txTemp :: IORef TxState -> String -> (FilePath -> IO FilePath) -> String -> IO (Either FsErr FilePath)
txTemp ref op allocate prefix = do
  if null prefix || length prefix > 64 || any (\c -> not (c `elem` (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "_-"))) prefix
    then pure (Left (FsErr op prefix WhyOther "prefix must be 1..64 ASCII letters, digits, '_' or '-'" ""))
    else mask_ $ (do
      tmp <- getTemporaryDirectory >>= canonicalizePath
      d <- allocate (tmp </> (prefix ++ "-"))
      -- Allocation and registration are masked: cancellation cannot strand
      -- an allocated directory before its owner records it.
      atomicModifyIORef' ref (\s -> (s {txTemps = d : txTemps s}, ()))
      pure (Right d)) `catch` \(e :: IOException) -> pure (Left (classifyIO op prefix e))

-- remove every temp dir this attempt still owns; idempotent
txSweepTemps :: IORef TxState -> IO ()
txSweepTemps ref = do
  ts <- atomicModifyIORef' ref (\s -> (s {txTemps = []}, txTemps s))
  forM_ ts $ \d -> removePathForcibly d `catch` \(e :: IOException) ->
    diagnostic ("[sol] scratch cleanup failed for " ++ d ++ ": " ++ show e)

txCleanupTemps :: IORef TxState -> IO ()
txCleanupTemps ref = do
  s <- readIORef ref
  recovery <- case txSagaJournal s of
    Nothing -> pure False
    Just j -> (||) <$> doesFileExist j <*> doesFileExist (undoPath j)
  if recovery && not (null (txTemps s))
    then diagnostic ("[sol] retaining scratch for pending recovery: " ++ show (txTemps s))
    else txSweepTemps ref

txExists :: IORef TxState -> FilePath -> IO Bool
txExists ref p =
  txExistsE ref p >>= either (ioError . userError . fsPanic "exists") pure

txExistsE :: IORef TxState -> FilePath -> IO (Either FsErr Bool)
txExistsE ref raw = fsAt "exists" raw $ do
  p <- stableWorldPath raw
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just (Just _) -> pure (Right True)
    Just Nothing -> pure (Right False)
    Nothing -> case M.lookup p (txDirView s) of
      Just b -> pure (Right b)
      Nothing -> do
        r <- try (diskMeta p) :: IO (Either IOException (Maybe (Int, Integer, Integer)))
        case r of
          Left e -> pure (Left (classifyIO "exists" p e))
          Right Nothing -> do
            recordMeta ref p noMeta {msPresentF = Just False}
            pure (Right False)
          Right (Just _) -> do
            recordMeta ref p noMeta {msPresentF = Just True}
            pure (Right True)

txIsDir :: IORef TxState -> FilePath -> IO Bool
txIsDir ref raw = do
  p <- stableWorldPath raw
  s <- readIORef ref
  case if M.member p (txView s) then Just False else M.lookup p (txDirView s) of
    Just b -> pure b
    Nothing -> do
      r <- try (diskMeta p) :: IO (Either IOException (Maybe (Int, Integer, Integer)))
      case r of
        Left e -> ioError (userError (fsPanic "isDir" (classifyIO "isDir" p e)))
        Right o -> do
          let isD = maybe False (\(k, _, _) -> k == kindDir) o
          recordMeta ref p noMeta {msPresentF = Just (maybe False (const True) o), msIsDir = Just isD}
          pure isD

-- one stat(2) on the path: no open, follows symlinks (a dangling link
-- resolves to nothing). Answers (kind, size, mtime) of whatever the path
-- is; Nothing is absent. This is the only disk contact a followed
-- metadata query makes — no content snapshot, so unreadable files, FIFOs
-- and sparse multi-GiB files all observe at metadata cost.
diskMeta :: FilePath -> IO (Maybe (Int, Integer, Integer))
diskMeta p = do
  ms <- (Just <$> PF.getFileStatus p) `catch` \e ->
    if isDoesNotExistError e then pure Nothing else throwIO (e :: IOException)
  pure ((\st -> (kindOf st, fromIntegral (PF.fileSize st), floor (PF.modificationTimeHiRes st))) <$> ms)
  where
    kindOf st
      | PF.isDirectory st = kindDir
      | PF.isRegularFile st = kindFile
      | otherwise = kindOther

-- one lstat(2): no follow. A link answers kindLink however it dangles;
-- Nothing is an absent ENTRY (the dangling-vs-missing distinguisher).
diskMetaL :: FilePath -> IO (Maybe Int)
diskMetaL p = do
  ms <- (Just <$> PF.getSymbolicLinkStatus p) `catch` \e ->
    if isDoesNotExistError e then pure Nothing else throwIO (e :: IOException)
  pure (kindOf <$> ms)
  where
    kindOf st
      | PF.isSymbolicLink st = kindLink
      | PF.isDirectory st = kindDir
      | PF.isRegularFile st = kindFile
      | otherwise = kindOther

-- no-follow kind (lstat): the entry's own kind. The transaction's own
-- pending mkdir/rmdir answers from the view; everything else observes
-- the disk and records the no-follow promise (validated at commit).
txLstatE :: IORef TxState -> FilePath -> IO (Either FsErr Int)
txLstatE ref raw = fsAt "lstat" raw $ do
  p <- stableWorldPath raw
  s <- readIORef ref
  case M.lookup p (txDirView s) of
    Just True -> pure (Right kindDir)
    Just False -> pure (Left (FsErr "lstat" p WhyMissing "" "removed earlier in this transaction"))
    Nothing -> case M.lookup p (txView s) of
      Just (Just _) -> pure (Right kindFile) -- this txn's own pending write
      Just Nothing -> pure (Left (FsErr "lstat" p WhyMissing "" "removed earlier in this transaction"))
      Nothing -> do
        r <- try (diskMetaL p) :: IO (Either IOException (Maybe Int))
        case r of
          Left e -> pure (Left (classifyIO "lstat" p e))
          Right Nothing -> do
            recordMeta ref p noMeta {msPresentL = Just False}
            pure (Left (FsErr "lstat" p WhyMissing "" ""))
          Right (Just k) -> do
            recordMeta ref p noMeta {msPresentL = Just True, msKindL = Just k}
            pure (Right k)

-- followed kind (statKind)
txStatKindE :: IORef TxState -> FilePath -> IO (Either FsErr Int)
txStatKindE ref raw = fsAt "statKind" raw $ do
  p <- stableWorldPath raw
  s <- readIORef ref
  case M.lookup p (txDirView s) of
    Just True -> pure (Right kindDir)
    Just False -> pure (Left (FsErr "statKind" p WhyMissing "" "removed earlier in this transaction"))
    Nothing -> case M.lookup p (txView s) of
      Just (Just _) -> pure (Right kindFile)
      Just Nothing -> pure (Left (FsErr "statKind" p WhyMissing "" "removed earlier in this transaction"))
      Nothing -> do
        r <- try (diskMeta p) :: IO (Either IOException (Maybe (Int, Integer, Integer)))
        case r of
          Left e -> pure (Left (classifyIO "statKind" p e))
          Right Nothing -> do
            recordMeta ref p noMeta {msPresentF = Just False}
            pure (Left (FsErr "statKind" p WhyMissing "" ""))
          Right (Just (k, _, _)) -> do
            recordMeta ref p noMeta {msPresentF = Just True, msKind = Just k}
            pure (Right k)

-- record a metadata promise; a second query of the same path widens it
-- to the union of promised fields (the newest presence wins)
recordMeta :: IORef TxState -> FilePath -> MetaSnap -> IO ()
recordMeta ref p snap = atomicModifyIORef' ref $ \st ->
  (st {txMetaReads = M.insertWith mergeMeta p snap (txMetaReads st)}, ())

mergeMeta :: MetaSnap -> MetaSnap -> MetaSnap
mergeMeta new old =
  MetaSnap
    { msPresentF = firstJust (msPresentF new) (msPresentF old),
      msPresentL = firstJust (msPresentL new) (msPresentL old),
      msKind = firstJust (msKind new) (msKind old),
      msKindL = firstJust (msKindL new) (msKindL old),
      msIsDir = firstJust (msIsDir new) (msIsDir old),
      msSize = firstJust (msSize new) (msSize old),
      msMtime = firstJust (msMtime new) (msMtime old),
      msFollowTarget = firstJust (msFollowTarget new) (msFollowTarget old),
      msChanged = msChanged old || msChanged new || or
        [ differs (msPresentF new) (msPresentF old), differs (msPresentL new) (msPresentL old)
        , differs (msKind new) (msKind old), differs (msKindL new) (msKindL old)
        , differs (msIsDir new) (msIsDir old), differs (msSize new) (msSize old)
        , differs (msMtime new) (msMtime old), differs (msFollowTarget new) (msFollowTarget old) ]
    }
  where
    firstJust (Just a) _ = Just a
    firstJust Nothing b = b
    differs (Just a) (Just b) = a /= b
    differs _ _ = False

-- (exists, size, mtime-seconds). The transaction's own view answers
-- first — a file this txn wrote EXISTS, sized by its pending content
-- (UTF-8 bytes, matching what commit will put on disk), mtime = now
-- (it has no disk mtime yet); a dir this txn mkdir'd answers from the
-- disk when it is already there, from the view otherwise, and the
-- transaction owns the path so no dependency is recorded. A view miss
-- observes disk metadata only (stat(2), no content read) and records
-- its promise in txMetaReads; commit rechecks exactly the promised
-- fields. Directory sizes are filesystem-specific; only the presence
-- bit is contractual.
txStat :: IORef TxState -> FilePath -> IO (Bool, Integer, Integer)
txStat ref p =
  txStatE ref p >>= either statPlain pure
  where
    -- the plain spelling answers absence (its documented contract since
    -- the metadata slice); only an unknowable observation panics
    statPlain fe
      | feWhy fe == WhyMissing = pure (False, 0, 0)
      | otherwise = ioError (userError (fsPanic "stat" fe))

txStatE :: IORef TxState -> FilePath -> IO (Either FsErr (Bool, Integer, Integer))
txStatE ref raw = fsAt "stat" raw $ do
  p <- stableWorldPath raw
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just Nothing -> pure (Right (False, 0, 0)) -- removed earlier in this txn
    Just (Just w) -> do
      now <- getPOSIXTime
      pure (Right (True, fromIntegral (utf8Len w), floor now))
    Nothing -> case M.lookup p (txDirView s) of
      Just False -> pure (Right (False, 0, 0)) -- rmdir'd earlier in this txn
      Just True -> do
        r <- try (diskMeta p) :: IO (Either IOException (Maybe (Int, Integer, Integer)))
        case r of
          Left e -> pure (Left (classifyIO "stat" p e))
          Right (Just (_, sz, mt)) -> pure (Right (True, sz, mt))
          Right Nothing -> do
            now <- getPOSIXTime
            pure (Right (True, 0, floor now))
      Nothing -> do
        r <- try (diskMeta p) :: IO (Either IOException (Maybe (Int, Integer, Integer)))
        case r of
          Left e -> pure (Left (classifyIO "stat" p e))
          Right Nothing -> do
            -- the Err IS an observation of absence; the promise keeps the
            -- presence-flip conflict that exists-missing already records
            recordMeta ref p noMeta {msPresentF = Just False}
            pure (Left (FsErr "stat" p WhyMissing "" ""))
          Right (Just (k, sz, mt)) -> do
            if k == kindDir then do
              -- Directory size/mtime must validate at the referent's lock
              -- before its child locks change those fields. Retain the
              -- alias-to-referent promise too, so retargeting is not hidden.
              target <- canonicalizePath p
              recordMeta ref target noMeta {msPresentF = Just True, msSize = Just sz, msMtime = Just mt}
              recordMeta ref p noMeta {msPresentF = Just True, msFollowTarget = Just target}
            else recordMeta ref p noMeta {msPresentF = Just True, msSize = Just sz, msMtime = Just mt}
            pure (Right (True, sz, mt))

-- promised-field recheck at commit: a presence flip always conflicts;
-- followed kind, no-follow kind and size/mtime conflict only where
-- promised. A same-metadata content rewrite passes here BY DESIGN —
-- exact-byte validation lives in the content read set, and a script
-- wanting that dependency reads the file.
metaStale :: MetaSnap -> Maybe (Int, Integer, Integer) -> Maybe Int -> Bool
metaStale ms nowF nowL = msChanged ms || fStale || lStale
  where
    -- each modality's check runs only where that modality was promised
    fStale = case (msPresentF ms, nowF) of
      (Nothing, _) -> False
      (Just False, Nothing) -> False
      (Just False, Just _) -> True -- promised absent, now there
      (Just True, Nothing) -> True -- promised present, now gone
      (Just True, Just (k, sz, mt)) ->
        maybe False (/= k) (msKind ms)
          || maybe False (/= (k == kindDir)) (msIsDir ms)
          || maybe False (/= sz) (msSize ms)
          || maybe False (/= mt) (msMtime ms)
    lStale = case (msPresentL ms, nowL) of
      (Nothing, _) -> False
      (Just False, Nothing) -> False
      (Just False, Just _) -> True
      (Just True, Nothing) -> True
      (Just True, Just k) -> maybe False (/= k) (msKindL ms)

-- the observations the recheck needs: followed stat always, no-follow
-- lstat only where a no-follow kind was promised
metaStaleIO :: MetaSnap -> FilePath -> IO Bool
metaStaleIO ms p = (do
  nowF <- maybe (pure Nothing) (const (diskMeta p)) (msPresentF ms)
  nowL <- maybe (pure Nothing) (const (diskMetaL p)) (msPresentL ms)
  moved <- case msFollowTarget ms of
    Nothing -> pure False
    Just wanted -> (/= wanted) <$> canonicalizePath p
  pure (moved || metaStale ms nowF nowL)) `catch` \(_ :: IOException) -> pure True

-- byte length of the string as commit will encode it
utf8Len :: String -> Int
utf8Len = sum . map w
  where
    w c
      | fromEnum c < 0x80 = 1
      | fromEnum c < 0x800 = 2
      | fromEnum c < 0x10000 = 3
      | otherwise = 4


-- naming helpers shared with the protocol layer
displayProcess :: ProcessSpec -> String
displayProcess spec = unwords (map show (psArgv spec))
undoPath :: FilePath -> FilePath
undoPath j = j ++ ".undo"

-- commit-protocol artifact names (shared with the protocol layer below)

-- .sol-lock dirs, reclaim renames, and .sol-tmp staging files are
-- commit-protocol artifacts: invisible to validation and to txLs
lockArtifact :: FilePath -> Bool
lockArtifact n =
  ".sol-lock" `isSuffixOf` n
    || ".sol-tmp" `isSuffixOf` n
    || ".sol-lock.reclaim." `isInfixOf` n
