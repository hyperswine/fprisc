{-# LANGUAGE ScopedTypeVariables #-}
-- Owned byte pipelines. No shell interpretation; captures have explicit caps.
module Sol.Process where

import Control.Concurrent
import Control.Exception
import Control.Monad (forM, forM_, unless, when, void)
import qualified Data.ByteString as B
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import Data.Unique (Unique, newUnique)
import Sol.Effects (ProcessSpec(..))
import qualified Sol.ScriptIO as S
import System.Directory (removeFile, renameFile, getCurrentDirectory, makeAbsolute, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode(..))
import System.FilePath (takeDirectory, (</>), isAbsolute, splitSearchPath)
import System.IO
import System.IO.Error (isDoesNotExistError, isResourceVanishedError)
import System.Process
import qualified System.Posix.Files as F
import qualified System.Posix.Temp as T
import System.Posix.Signals (signalProcessGroup, sigKILL)
import System.Posix.Types (ProcessID)
import System.Timeout (timeout)

data Input = InputBytes B.ByteString | InputFile FilePath | InputInherit
data Output = Capture Int | CaptureUtf8 Int | FileNew FilePath | Publish FilePath Bool | OutputInherit | Discard
data Policy = LastStage | PipeFail
data Pipeline = Pipeline [ProcessSpec] Input Output Output Int Policy
data Failure = Failure String Int String Int deriving (Show)
instance Exception Failure
data Result = Result Int [Int] B.ByteString [B.ByteString]

-- The linear language value includes identity plus key. The table is also
-- swept before commit and on every exit, including abandoned linear branches.
data Job = Job ThreadId (MVar (Either Failure Result)) (MVar ())
data Runtime = Runtime {identity :: Unique, jobs :: MVar (Int, IM.IntMap Job)}
newRuntime :: IO Runtime
newRuntime = Runtime <$> newUnique <*> newMVar (1, IM.empty)

api :: [(String, Int, String)]
api = [("Proc.pipeline",1,"PipelineSpec -> Result PipelineResult ProcessError")
      ,("Proc.start",1,"PipelineSpec -> Result ProcessJob ProcessError")
      ,("Proc.wait",1,"ProcessJob -> Result PipelineResult ProcessError")
      ,("Proc.poll",1,"ProcessJob -> (Result Bool ProcessError, ProcessJob)")
      ,("Proc.cancel",1,"ProcessJob -> Result Unit ProcessError")]

quiet :: IO () -> IO ()
quiet action = action `catch` \(_ :: IOException) -> pure ()

start :: Runtime -> Pipeline -> IO Int
start rt spec = mask_ $ modifyMVar (jobs rt) $ \(key, table) -> do
  result <- newEmptyMVar
  joined <- newEmptyMVar
  tid <- forkIOWithUnmask $ \unmask ->
    (do r <- try (unmask (run spec))
        putMVar result (either (\e -> Left (Failure (showError e) 0 "worker" 0)) id r))
      `finally` putMVar joined ()
  pure ((key+1, IM.insert key (Job tid result joined) table), key)
  where
    showError :: SomeException -> String
    showError = show

-- Keep failures from the runner structured through the job worker.
run :: Pipeline -> IO (Either Failure Result)
run spec = (Right <$> execute spec) `catches`
  [Handler (\(e :: Failure) -> pure (Left e)),
   Handler (\(e :: IOException) -> pure (Left (Failure ("io: " ++ show e) 0 "" 0)))]

lookupJob :: Runtime -> Bool -> Int -> IO (Either Failure Job)
lookupJob rt consume key = modifyMVar (jobs rt) $ \(next, table) ->
  pure ((next, if consume then IM.delete key table else table),
        maybe (Left (Failure "closed or foreign job" 0 "" 0)) Right (IM.lookup key table))
wait :: Runtime -> Int -> IO (Either Failure Result)
wait rt key = mask $ \restore -> do
  found <- lookupJob rt True key
  case found of
    Left e -> pure (Left e)
    Right job@(Job _ result joined) ->
      restore (readMVar result <* readMVar joined) `onException` stopJob job
poll :: Runtime -> Int -> IO (Either Failure Bool)
poll rt key = do
  found <- lookupJob rt False key
  case found of
    Left e -> pure (Left e)
    Right (Job _ result _) -> Right . not <$> isEmptyMVar result
stopJob :: Job -> IO ()
stopJob (Job tid _ joined) = killThread tid >> readMVar joined
cancel :: Runtime -> Int -> IO (Either Failure ())
cancel rt key = mask_ $ do
  found <- lookupJob rt True key
  case found of Left e -> pure (Left e); Right job -> stopJob job >> pure (Right ())
closeRuntime :: Runtime -> IO ()
closeRuntime rt = mask_ $ do
  table <- modifyMVar (jobs rt) $ \(n, table) -> pure ((n,IM.empty), table)
  mapM_ stopJob (IM.elems table)

failWith :: String -> Int -> String -> Int -> IO a
failWith reason stage channel limit = throwIO (Failure reason stage channel limit)

-- A worker group joins all I/O tasks on failure/cancellation. Pipe endpoints
-- are closed only after these workers release their Handle locks.
concurrently :: forall a. [IO a] -> IO [a]
concurrently actions = mask $ \restore -> do
  completed <- newChan
  workers <- forM (zip [0..] actions) $ \(i, action) -> do
    joined <- newEmptyMVar
    tid <- forkIOWithUnmask $ \unmask ->
      ((try (unmask action) :: IO (Either SomeException a)) >>= writeChan completed . (,) i)
        `finally` putMVar joined ()
    pure (tid, joined)
  let gather 0 values = pure (map snd (IM.toAscList values))
      gather n values = do
        (i, value) <- readChan completed
        x <- either throwIO pure value
        gather (n-1) (IM.insert i x values)
      stop = mapM_ (killThread . fst) workers >> mapM_ (readMVar . snd) workers
  restore (gather (length actions) IM.empty) `finally` stop

boundedRead :: Int -> String -> Int -> Handle -> IO B.ByteString
boundedRead = boundedReadWith False

boundedReadWith :: Bool -> Int -> String -> Int -> Handle -> IO B.ByteString
boundedReadWith text stage channel limit h = go 0 [] B.empty
  where
    go n chunks carry = do
      b <- B.hGetSome h (min 65536 (limit - n + 1))
      when (B.length b > limit - n) (failWith "capture overflow" stage channel limit)
      rest <- if text then case S.utf8Chunk False carry b (B.null b) of
        Left why -> failWith ("invalid UTF-8 capture: " ++ why) stage channel limit
        Right (_,suffix) -> pure suffix
        else pure B.empty
      if B.null b then pure (B.concat (reverse chunks))
      else go (n + B.length b) (b:chunks) rest

data Child = Child (Maybe Handle) (Maybe Handle) (Maybe Handle) ProcessHandle (Maybe ProcessID)

execute :: Pipeline -> IO Result
execute (Pipeline specs input output errors deadline policy) = do
  unless (not (null specs) && length specs <= 16) (failWith "stage count must be 1..16" 0 "" 0)
  forM_ (zip [1..] specs) $ \(i,spec) -> do
    when (null (psArgv spec)) (failWith "empty argv" i "" 0)
    unless (null (psStdin spec)) (failWith "use PipelineSpec input; stage stdin text must be empty" i "stdin" 0)
    forM_ (psArgv spec ++ maybe [] pure (psCwd spec) ++ concatMap (\(k,v)->[k,v]) (psEnv spec)) $ \s -> do
      when ('\0' `elem` s) (failWith "NUL in process argument/environment" i "" 0)
      either (\why -> failWith why i "" 0) (const (pure ())) (S.encodeUtf8 s)
    forM_ (psEnv spec) $ \(k,_) -> when (null k || '=' `elem` k) (failWith "invalid environment name" i "" 0)
    when (maybe False (>0) (psTimeoutMs spec)) (failWith "use PipelineSpec deadline; stage timeouts must be zero" i "" 0)
  forM_ [output,errors] $ \sink -> case sink of
    Capture n -> unless (n >= 0 && n <= 16777216) (failWith "capture limit must be 0..16777216" 0 "" n)
    CaptureUtf8 n -> unless (n >= 0 && n <= 16777216) (failWith "capture limit must be 0..16777216" 0 "" n)
    _ -> pure ()
  let budget (Capture n) = toInteger n
      budget (CaptureUtf8 n) = toInteger n
      budget _ = 0
  when (budget output + toInteger (length specs) * budget errors > 33554432)
    (failWith "combined capture budget exceeds 33554432 bytes" 0 "" 33554432)
  case errors of FileNew _ -> invalidStderr; Publish _ _ -> invalidStderr; _ -> pure ()
  when (deadline < 0 || deadline > 86400000) (failWith "deadline must be 0..86400000 milliseconds" 0 "" 0)
  -- This API owns groups and does not allocate a PTY. The existing
  -- Proc.inheritNow API provides foreground terminal handoff/restoration.
  case input of InputInherit -> do
                  tty <- hIsTerminalDevice stdin
                  when tty (failWith "terminal input requires Proc.inheritNow" 0 "stdin" 0)
                _ -> pure ()
  withInput input $ \source -> withOutput output $ \sink publish -> do
    r <- if deadline == 0 then Just <$> owned source sink
         else timeout (deadline * 1000) (owned source sink)
    result@(Result status _ _ _) <- maybe (failWith "timeout" 0 "" deadline) pure r
    when (status == 0) publish
    pure result
  where
    invalidStderr = failWith "stderr supports capture, inherit or discard" 0 "stderr" 0
    owned source sink = mask $ \restore -> do
      children <- newMVar []
      let cleanup = do
            cs <- readMVar children
            forM_ cs $ \(Child _ _ _ ph gid) -> do
              maybe (quiet (terminateProcess ph)) (quiet . signalProcessGroup sigKILL) gid
            forM_ cs $ \(Child hin hout herr ph _) -> do
              quiet (void (waitForProcess ph))
              mapM_ (maybe (pure ()) (quiet . hClose)) [hin,hout,herr]
          spawn (i,spec) = do
            inherited <- getEnvironment
            let (exe:args) = psArgv spec
                stageEnv = M.union (M.fromList (psEnv spec)) (M.fromList inherited)
            resolved <- resolveExecutable spec stageEnv exe `catch` \(e :: IOException) -> failWith ("spawn: " ++ show e) i "" 0
            let inheritInput = case input of InputInherit -> i == 1; _ -> False
                cp = (proc resolved args) {cwd=psCwd spec,
                  env=Just (M.toList stageEnv),
                  std_in=if inheritInput then Inherit else CreatePipe,
                  std_out=CreatePipe, std_err=CreatePipe, create_group=True}
            (hin,hout,herr,ph) <- createProcess cp `catch` \(e :: IOException) -> failWith ("spawn: " ++ show e) i "" 0
            gid <- getPid ph
            let child = Child hin hout herr ph gid
            modifyMVar_ children (pure . (child:))
            pure child
      (do cs <- mapM spawn (zip [1..] specs)
          restore $ do
            let outs = [h | Child _ (Just h) _ _ _ <- cs]
                errs = [h | Child _ _ (Just h) _ _ <- cs]
                nextInputs = [h | Child (Just h) _ _ _ _ <- drop 1 cs]
                pumps = zipWith relay outs nextInputs
                writeInput = case cs of
                  Child (Just h) _ _ _ _ : _ -> (source h `catch` brokenPipe) `finally` quiet (hClose h)
                  _ -> pure ()
                readFinal = readSink (length cs) "stdout" output sink (last outs)
                readErrors = zipWith (\i h -> readSink i "stderr" errors Nothing h) [1..] errs
                waits = forM cs $ \(Child _ _ _ ph _) -> exitInt <$> waitForProcess ph
            -- Uniform tagged results allow one cancellation-aware worker group.
            values <- concurrently (map (fmap (const (Left []))) (writeInput:pumps)
              ++ [Right . Left <$> waits, Right . Right <$> readFinal]
              ++ map (fmap (Left . pure)) readErrors)
            let statuses = concat [xs | Right (Left xs) <- values]
                captured = [b | Right (Right b) <- values]
                capturedErrors = concat [bs | Left bs <- drop (length cs + 2) values]
                status = case policy of LastStage -> last statuses
                                        PipeFail -> case filter (/=0) statuses of [] -> 0; xs -> last xs
            pure (Result status statuses (B.concat captured) capturedErrors)) `finally` cleanup
    exitInt ExitSuccess = 0
    exitInt (ExitFailure n) = n

-- Search the stage's effective PATH and cwd, rather than relying on the
-- platform-specific execvp/execvpe choice in process. Empty entries mean cwd.
resolveExecutable :: ProcessSpec -> M.Map String String -> String -> IO FilePath
resolveExecutable spec environment exe = do
  base <- maybe getCurrentDirectory makeAbsolute (psCwd spec)
  let atBase path = if isAbsolute path then path else base </> path
      candidates = if '/' `elem` exe then [atBase exe]
        else [atBase path </> exe | path <- splitSearchPath (M.findWithDefault "/usr/bin:/bin" "PATH" environment)]
      choose [] = S.failIO ("executable not found or not executable: " ++ exe)
      choose (candidate:rest) = do
        exists <- doesFileExist candidate
        allowed <- if exists then F.fileAccess candidate False False True else pure False
        if allowed then pure candidate else choose rest
  choose candidates

brokenPipe :: IOException -> IO ()
brokenPipe e = unless (isResourceVanishedError e) (throwIO e)
relay :: Handle -> Handle -> IO ()
relay source target = (void (S.copyHandles source target 65536) `catch` brokenPipe)
  `finally` (quiet (hClose source) >> quiet (hClose target))

withInput :: Input -> ((Handle -> IO ()) -> IO a) -> IO a
withInput (InputBytes bytes) action = action (\h -> B.hPut h bytes >> hFlush h)
withInput (InputFile path) action = bracket (S.openReadHandle path) hClose $ \input ->
  action (\h -> void (S.copyHandles input h 65536))
withInput InputInherit action = action (\h -> void (S.copyHandles stdin h 65536))

withOutput :: Output -> (Maybe Handle -> IO () -> IO a) -> IO a
withOutput (FileNew path) action = bracket (S.openWriteHandle path) hClose $ \h -> action (Just h) (hFlush h)
withOutput (Publish target replace) action = do
  S.checkPath target
  bracket (T.mkstemp (takeDirectory target </> ".sol-pipe-")) cleanup $ \(stage,h) ->
    action (Just h) $ do
      hFlush h
      hClose h
      if replace then do
        old <- S.optionalStatus target
        forM_ old $ \st -> do
          unless (F.isRegularFile st) (S.failIO "replacement requires a regular non-symlink destination")
          F.setFileMode stage (F.fileMode st `mod` 0o1000)
        renameFile stage target
      else F.createLink stage target
  where cleanup (path,h) = quiet (hClose h) >> (removeFile path `catch` \e -> unless (isDoesNotExistError e) (throwIO (e :: IOException)))
withOutput _ action = action Nothing (pure ())

readSink :: Int -> String -> Output -> Maybe Handle -> Handle -> IO B.ByteString
readSink stage channel mode target h = case mode of
  Capture limit -> boundedRead stage channel limit h
  CaptureUtf8 limit -> boundedReadWith True stage channel limit h
  Discard -> drain (const (pure ()))
  OutputInherit -> drain (B.hPut (if channel == "stdout" then stdout else stderr))
  _ -> maybe (failWith "missing file sink" stage channel 0) (\out -> drain (B.hPut out)) target
  where
    drain emit = loop
      where
        loop = do
          b <- B.hGetSome h 65536
          if B.null b then pure B.empty else emit b >> loop
