{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
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

module Sol.Txn (module Sol.Txn, module Sol.Effects) where

import Sol.Diagnostic (diagnostic)
import Sol.Native
import Sol.Effects
import Data.Unique (Unique, newUnique)
import Control.Concurrent (threadDelay, forkIOWithUnmask, killThread, newEmptyMVar, putMVar, takeMVar, newChan, writeChan, readChan)
import Control.Exception (SomeException, bracket, catch, IOException, finally, mask, mask_, onException, throwIO, try)
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
  ( canonicalizePath, makeAbsolute, getCurrentDirectory,
    createDirectory,
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
import System.FilePath (takeDirectory, takeFileName, hasTrailingPathSeparator, (</>))
import System.IO (readFile', hClose, hIsTerminalDevice)
import System.IO.Error (ioeGetErrorType, isAlreadyExistsError, isDoesNotExistError, isResourceVanishedError)
import Foreign.C.Error (Errno (..), eACCES, eISDIR, eLOOP, eMLINK, eNOENT, eNOTDIR, ePERM)
import GHC.IO.Exception (IOException (..), IOErrorType (..))
import System.IO (hFlush, hGetContents', hIsEOF, hGetLine, stderr, stdin, stdout, hPutStr, hPutStrLn)
import System.Process (CreateProcess (..), StdStream (..), getPid, terminateProcess, createProcess, proc, readCreateProcessWithExitCode, shell, waitForProcess)
import System.Timeout (timeout)
import qualified System.Posix.Files as PF
import System.Posix.Signals (signalProcessGroup, sigKILL, sigCONT, sigTTOU, blockSignals, getSignalMask, setSignalMask, addSignal, emptySignalSet)
import System.Posix.Terminal (getTerminalProcessGroupID, setTerminalProcessGroupID)
import System.Posix.Process (getProcessGroupID)
import System.Posix.IO (stdInput)
import System.Posix.Types (ProcessGroupID)

-- a metadata promise: what a metadata query (exists/isDir/stat) recorded
-- about a path it did NOT read. Commit rechecks exactly these fields
-- under the locks — presence always; kind and size/mtime only where
-- promised. Nothing here claims content equality from size/mtime:
-- content reads keep exact-byte validation (txReadBytes).
data MetaSnap = MetaSnap
  { msPresent :: Bool,
    msIsDir :: Maybe Bool, -- promised by isDir only
    msSize :: Maybe Integer, -- promised by stat only
    msMtime :: Maybe Integer -- promised by stat only
  }

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
    txSaga :: Maybe GitUndo,
    txPivot :: !Bool,
    txLogs :: [String] -- REVERSED `log` lines: emitted only after a clean commit
  }

newTx :: IO (IORef TxState)
newTx = do
  identity <- newUnique
  newIORef emptyTx {txIdentity = Just identity}

emptyTx :: TxState
emptyTx = TxState
  { txReads=M.empty, txReadBytes=M.empty, txMetaReads=M.empty, txDirReads=M.empty
  , txEffects=[], txView=M.empty, txDirView=M.empty
  , txHandles=IM.empty, txNextH=1, txNonText=S.empty, txSealed=False
  , txIdentity=Nothing, txNextStep=0, txTerminal=False, txPathLogs=[]
  , txSagaJournal=Nothing, txSaga=Nothing, txPivot=False, txLogs=[]
  }

resetTx :: IORef TxState -> IO ()
resetTx ref = newTx >>= readIORef >>= writeIORef ref

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
  if hasTrailingPathSeparator absolute then pure absolute else do
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
    ++ " Queue it too ("
    ++ deferredSpelling
    ++ "), or move it to a separate script run."

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
-- exact bytes accompany the decoded view. Non-UTF-8 files are remembered as
-- non-text so the read surface can refuse them. Metadata queries (exists/
-- stat/isDir) do NOT snapshot: they record promises in txMetaReads instead.
snapshot :: IORef TxState -> FilePath -> IO (Maybe String)
snapshot ref p = do
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
  link <- (PF.isSymbolicLink <$> PF.getSymbolicLinkStatus p) `catch` \e ->
    if isDoesNotExistError e then pure False else throwIO (e :: IOException)
  when link $ ioError (userError ("writeAtomic: refusing symbolic link: " ++ p))
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

-- the hosted filesystem error model: one value answers WHICH operation
-- failed, on WHAT path, and a distinguishable WHY (the typed tier —
-- Try.ls/Try.stat/Try.exists — pattern-matches this; the panicking
-- spellings render it). feNote carries a plain-text hint that only the
-- panic message uses (e.g. "removed earlier in this transaction").
data FsWhy = WhyMissing | WhyDenied | WhyWrongKind | WhyLoop | WhyOther deriving (Eq)

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
fsWhyName WhyOther = "FsOther"

-- errno first (ELOOP/EISDIR/ENOTDIR only exist there); the IOErrorType
-- fallback covers exceptions raised without an errno
classifyIO :: String -> FilePath -> IOException -> FsErr
classifyIO op p e = FsErr op p why (show e) ""
  where
    why = case ioe_errno e of
      Just n
        | Errno n == eNOENT -> WhyMissing
        | Errno n == eACCES || Errno n == ePERM -> WhyDenied
        | Errno n == eLOOP || Errno n == eMLINK -> WhyLoop
        | Errno n == eISDIR || Errno n == eNOTDIR -> WhyWrongKind
      _ -> case ioeGetErrorType e of
        NoSuchThing -> WhyMissing
        PermissionDenied -> WhyDenied
        _ -> WhyOther

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
txLsE ref dir = do
  s <- readIORef ref
  let pendingDir = M.lookup dir (txDirView s)
  base <- case pendingDir of
    Just False ->
      pure (Left (FsErr "ls" dir WhyMissing "" "removed earlier in this transaction"))
    _ -> case M.lookup dir (txDirReads s) of
      Just names -> pure (Right names)
      Nothing -> do
        r <- try (listDirectory dir) :: IO (Either IOException [String])
        case r of
          Left e
            | isDoesNotExistError e, pendingDir == Just True -> pure (Right [])
            | otherwise -> pure (Left (classifyIO "ls" dir e))
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
      pure (Right (sort ((names ++ added ++ addedDirs) `without` removed)))
  where
    without xs ys = [x | x <- xs, x `notElem` ys]

txExists :: IORef TxState -> FilePath -> IO Bool
txExists ref p =
  txExistsE ref p >>= either (ioError . userError . fsPanic "exists") pure

txExistsE :: IORef TxState -> FilePath -> IO (Either FsErr Bool)
txExistsE ref p = do
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just (Just _) -> pure (Right True)
    Just Nothing -> pure (Right False)
    Nothing -> case M.lookup p (txDirView s) of
      Just b -> pure (Right b)
      Nothing -> do
        r <- try (diskMeta p) :: IO (Either IOException (Maybe (Bool, Integer, Integer)))
        case r of
          Left e -> pure (Left (classifyIO "exists" p e))
          Right Nothing -> do
            recordMeta ref p (MetaSnap False Nothing Nothing Nothing)
            pure (Right False)
          Right (Just _) -> do
            recordMeta ref p (MetaSnap True Nothing Nothing Nothing)
            pure (Right True)

txIsDir :: IORef TxState -> FilePath -> IO Bool
txIsDir ref p = do
  s <- readIORef ref
  case M.lookup p (txDirView s) of
    Just b -> pure b
    Nothing -> do
      r <- try (diskMeta p) :: IO (Either IOException (Maybe (Bool, Integer, Integer)))
      case r of
        Left e -> ioError (userError (fsPanic "isDir" (classifyIO "isDir" p e)))
        Right o -> do
          let isD = maybe False (\(d, _, _) -> d) o
          recordMeta ref p (MetaSnap (maybe False (const True) o) (Just isD) Nothing Nothing)
          pure isD

-- one stat(2) on the path: no open, follows symlinks (a dangling link
-- resolves to nothing). Answers (isDir, size, mtime) of whatever the
-- path is; Nothing is absent. This is the only disk contact a metadata
-- query makes — no content snapshot, so unreadable files, FIFOs and
-- sparse multi-GiB files all observe at metadata cost.
diskMeta :: FilePath -> IO (Maybe (Bool, Integer, Integer))
diskMeta p = do
  ms <- (Just <$> PF.getFileStatus p) `catch` \e ->
    if isDoesNotExistError e then pure Nothing else throwIO (e :: IOException)
  pure ((\st -> (PF.isDirectory st, fromIntegral (PF.fileSize st), floor (PF.modificationTimeHiRes st))) <$> ms)

-- record a metadata promise; a second query of the same path widens it
-- to the union of promised fields (the newest presence wins)
recordMeta :: IORef TxState -> FilePath -> MetaSnap -> IO ()
recordMeta ref p snap = atomicModifyIORef' ref $ \st ->
  (st {txMetaReads = M.insertWith mergeMeta p snap (txMetaReads st)}, ())

mergeMeta :: MetaSnap -> MetaSnap -> MetaSnap
mergeMeta new old =
  MetaSnap
    { msPresent = msPresent new,
      msIsDir = firstJust (msIsDir new) (msIsDir old),
      msSize = firstJust (msSize new) (msSize old),
      msMtime = firstJust (msMtime new) (msMtime old)
    }
  where
    firstJust (Just a) _ = Just a
    firstJust Nothing b = b

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
txStatE ref p = do
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just Nothing -> pure (Right (False, 0, 0)) -- removed earlier in this txn
    Just (Just w) -> do
      now <- getPOSIXTime
      pure (Right (True, fromIntegral (utf8Len w), floor now))
    Nothing -> case M.lookup p (txDirView s) of
      Just False -> pure (Right (False, 0, 0)) -- rmdir'd earlier in this txn
      Just True -> do
        r <- try (diskMeta p) :: IO (Either IOException (Maybe (Bool, Integer, Integer)))
        case r of
          Left e -> pure (Left (classifyIO "stat" p e))
          Right (Just (_, sz, mt)) -> pure (Right (True, sz, mt))
          Right Nothing -> do
            now <- getPOSIXTime
            pure (Right (True, 0, floor now))
      Nothing -> do
        r <- try (diskMeta p) :: IO (Either IOException (Maybe (Bool, Integer, Integer)))
        case r of
          Left e -> pure (Left (classifyIO "stat" p e))
          Right Nothing -> do
            -- the Err IS an observation of absence; the promise keeps the
            -- presence-flip conflict that exists-missing already records
            recordMeta ref p (MetaSnap False Nothing Nothing Nothing)
            pure (Left (FsErr "stat" p WhyMissing "" ""))
          Right (Just (_, sz, mt)) -> do
            recordMeta ref p (MetaSnap True Nothing (Just sz) (Just mt))
            pure (Right (True, sz, mt))

-- promised-field recheck at commit: a presence flip always conflicts;
-- kind and size/mtime conflict only where promised. A same-metadata
-- content rewrite passes here BY DESIGN — exact-byte validation lives
-- in the content read set, and a script wanting that dependency reads
-- the file.
metaStale :: MetaSnap -> Maybe (Bool, Integer, Integer) -> Bool
metaStale ms Nothing = msPresent ms -- promised present, now gone
metaStale ms (Just (isD, sz, mt)) =
  not (msPresent ms)
    || maybe False (/= isD) (msIsDir ms)
    || maybe False (/= sz) (msSize ms)
    || maybe False (/= mt) (msMtime ms)

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
-- All structured children have a process group so timeout/cancellation can
-- kill descendants which inherited pipes. A deliberately detached session is
-- outside this ownership boundary. Successful children may leave background jobs.
data ProcessIO = CaptureIO | StreamIO | InheritIO deriving (Eq)

runProcessSpec :: ProcessSpec -> IO (Either String (Int, String, String))
runProcessSpec = runProcessMode CaptureIO

runProcessMode :: ProcessIO -> ProcessSpec -> IO (Either String (Int, String, String))
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

undoPath :: FilePath -> FilePath
undoPath j = j ++ ".undo"

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
  r <- try (readFile' (donePath j)) :: IO (Either IOException String)
  case r of
    Left e | isDoesNotExistError e -> pure IM.empty
           | otherwise -> throwIO e
    Right txt -> either (ioError . userError) pure (decodeDone txt)

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

-- ---- one journal per run ---------------------------------------------------
--
-- The journal belongs to the RUN, not the script: two concurrent runs of
-- one script with disjoint write sets never contend on a lock, so a
-- shared <script>.soljournal let one clear or overwrite the other's and a
-- crash in either lost its redo. Each run journals to
-- <script>.soljournal.<pid>.<nonce>, a sibling file (no shared directory
-- to create or remove, so no race on it).

journalPrefix :: FilePath -> FilePath
journalPrefix base = base ++ ".soljournal."

-- this run's journal path; the nonce keeps a reused pid from naming a
-- dead predecessor's journal
runJournalPath :: FilePath -> IO FilePath
runJournalPath base = do
  me <- c_getpid
  t <- getPOSIXTime
  let nonce = floor (t * 1000000000) :: Integer
  makeAbsolute (journalPrefix base ++ show (fromIntegral me :: Int) ++ "." ++ show nonce)

-- heal at startup: redo every journal of this script whose owner is dead
-- (a live owner is mid-commit and holds its locks; leave it alone), plus
-- the pre-per-run <script>.soljournal if an older sol left one
recoverScriptJournals :: FilePath -> IO ()
recoverScriptJournals base = do
  recoverJournal True (base ++ ".soljournal")
  let dir = parentOf base
      stem = drop (length dir) (journalPrefix base)
  r <- try (listDirectory dir) :: IO (Either IOException [String])
  me <- c_getpid
  forM_ (reverse (either (const []) sort r)) $ \n ->
    case stripPrefixL stem n of
      Just rest
        | not (".done" `isSuffixOf` n),
          not (".sol-tmp" `isSuffixOf` n),
          Just pid <- readMaybe (takeWhile (/= '.') rest) -> do
            alive <- c_pidAlive (fromIntegral (pid :: Int))
            -- our own pid cannot own a journal yet: that one is a dead
            -- predecessor's whose pid was reused
            when (alive == 0 || pid == fromIntegral me) $
              recoverJournal True (dir ++ n)
      _ -> pure ()
  where
    stripPrefixL pre x = if pre `isPrefixOf` x then Just (drop (length pre) x) else Nothing

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
  withLocksHold hold (acquire jpath) touched $ do -- sorted: global lock order
    staleC <-
      foldM
        ( \acc (p, snap) -> do
            now <- diskReadBytes p
            pure (if now == snap then acc else p : acc)
        )
        []
        (M.toList (txReadBytes s))
    staleM <-
      foldM
        ( \acc (p, ms) -> do
            now <- diskMeta p
            pure (if metaStale ms now then p : acc else acc)
        )
        []
        (M.toList (txMetaReads s))
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
                r <- action
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
        EShell cmd -> external ("deferred command " ++ cmd) True $ do
          (status,out,err) <- readCreateProcessWithExitCode (shell cmd) ""
          pure (Right (ProcessCapture (case status of ExitSuccess -> 0; ExitFailure n -> n) out err))
        EShellAt cwd cmd -> external ("deferred command " ++ cmd) True $ do
          (status,out,err) <- readCreateProcessWithExitCode (shell cmd) {cwd=Just cwd} ""
          pure (Right (ProcessCapture (case status of ExitSuccess -> 0; ExitFailure n -> n) out err))
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
