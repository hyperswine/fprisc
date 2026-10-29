{-# LANGUAGE LambdaCase, ScopedTypeVariables #-}

-- Main.hs — `sol script.sol`
--
-- Pipeline (front half reused verbatim from the FPRISC compiler):
--   prelude + script --> parse --> linearity check --> desugar --> lambda
--   lift --> BYTECODE (instead of RISC-V asm) --> Sol VM
--
-- The whole run is one transaction: reads snapshot host files, writes are
-- buffered, and at exit we lock / validate / commit / unlock. A validation
-- failure retries only when the external-effect policy permits — see Txn.hs.

module Sol.Main where

import Mono (specializeFunctions)
import Sol.Cache (Prepared (..), cached, cachedPrelude)
import Sol.Startup (phase, phaseIO)
import Control.DeepSeq (force)
import Sol.Diagnostic
import qualified Sol.ScriptIO as ScriptIO
import Sol.Bytecode
import Control.Exception (AsyncException (UserInterrupt), Handler (..), IOException, SomeAsyncException, SomeException, fromException, bracket, catch, catches, finally, onException, throwIO, try, evaluate)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State.Strict (runState)
import Data.IORef
import Data.Char (isSpace)
import Data.List (intercalate, isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Foldable (toList)
import System.IO.Unsafe (unsafeInterleaveIO)
import Sol.Lang
import Sol.Mod (resolveModuleParsed, parseCachedSource)
import Sol.Preamble (halArities, prelude)
import Struct (erasePSig, expandStructs, sigTable, specialize, structTable)
import Safety (checkSafety, safetyDiagnostics, safetySuggestions, trustedLibraryPaths)
import Precond (applyPreconds, preTable, validatePre, validatePreUses)
import Sol.Infer (inferResult, builtinNames)
import Sol.Slice (injectedNames, mentions, shapeSeed, slicePrelude)
import Infer.Result
import qualified Diagnostic.Render as SourceDiagnostic
import Infer (builtinLinShapes)
import Sol.Width (widthReport)
import Sol.HandJIT (JitCtx, initJIT)
import System.Environment (getArgs, lookupEnv)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Exit (ExitCode (..), exitFailure, exitSuccess, exitWith)
import System.IO (hFlush, hGetLine, hIsTerminalDevice, hPutStr, hPutStrLn, putStr, stderr, stdin, stdout)
import System.IO.Error (ioeGetErrorString, isUserError)
import System.Directory (canonicalizePath, getCurrentDirectory, getTemporaryDirectory)
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.FilePath (dropExtension, takeDirectory, takeExtension)
import Text.Megaparsec (errorBundlePretty, parse)
import Sol.Txn
import qualified Sol.Gpu as Gpu
import Sol.VM hiding ()
import qualified Sol.VM as VM

maxRetries :: Int
maxRetries = 12

main :: IO ()
main = runScript `catch` ioFailure `catch` interrupted `catch` aborted
  where
    ioFailure :: IOException -> IO ()
    ioFailure e = diagnostic ("[sol] " ++ if isUserError e then ioeGetErrorString e else show e) >> exitFailure
    interrupted :: AsyncException -> IO ()
    interrupted UserInterrupt = diagnostic "[sol] interrupted" >> exitWith (ExitFailure 130)
    interrupted e = throwIO e
    aborted (ScriptIO.ScriptAbort code) = exitWith (ExitFailure code)

runScript :: IO ()
runScript = do
  setLocaleEncoding utf8
  as <- getArgs
  case as of
    ["--help"] -> putStrLn solHelp
    ["-h"] -> putStrLn solHelp
    ["--version"] -> putStrLn "Sol 0.12.0 (scripting API 1)"
    ["state"] -> maintainState False
    ["recover"] -> maintainState True
    ("--repl" : rest) -> runRepl rest
    _ -> runFile as

runFile :: [String] -> IO ()
runFile as = do
  configured <- maybe "guarded" id <$> lookupEnv "SOL_RETRY_POLICY"
  (dumpAsm, retryPolicy, path, scriptArgs) <- case parseRetryPolicy configured >>= \policy -> parseSolArgs False policy as of
    Right options -> pure options
    Left why -> diagnostic why >> exitFailure >> pure (False, GuardedRetry, "", [])
  prepared <- phase "startup" $ do
    src <- phase "source" (readFile path >>= evaluate . force)
    utops <- phase "parse" $ do
      parsed <- parseCachedSource path src
      case parsed of
        Left err -> diagnostic err >> exitFailure >> pure []
        Right (_, tops) -> pure tops
    seenRef <- newIORef M.empty
    trustRef <- newIORef S.empty
    -- canonicalizing ~65 shipped library paths costs ~4 ms; only a script
    -- with `use` asks the set anything, so a one-liner never pays for it.
    -- Read-only filesystem queries: deferring them cannot reorder effects.
    trustedPaths <- unsafeInterleaveIO (phaseIO "library-paths" trustedLibraryPaths)
    expanded <- phase "imports" $ expandUses 8 "" trustedPaths trustRef seenRef (takeExtension path) (takeDirectory path) utops
    trusted <- readIORef trustRef
    cached path src prelude expanded (S.toList trusted) $ do
      ptops <- phase "prelude-parse" preludeTops
      compilePrepared path src ptops utops expanded trusted
  let Prepared cons shapes prog bprog runList _ = prepared
  -- user constructors only (the builtins have their own spellings in render),
  -- by their BASE name: `L.O.Some` prints as `Some`
  writeIORef VM.conNames
    [ ((t, v, ar), reverse (takeWhile (/= '.') (reverse c)))
    | (c, (t, v, ar)) <- M.toList cons, M.notMember c builtinCons ]
  when dumpAsm $ do
    forM_ (M.toList bprog) $ \(n, fn) -> putStrLn (disasm n fn)

  when (null runList && not dumpAsm) $
    verbose "[sol] note: no `> expr.` statements and no main; nothing to run"

  -- JIT: one native tier per process (hand-rolled x86-64 / A64, no
  -- LLVM); the compile cache survives STM retries.  SOL_JIT=0 disables
  -- it (the interpreter handles everything); any other value, including
  -- the historical "hand", selects it.
  jitFlag <- lookupEnv "SOL_JIT"
  jc <- case jitFlag of
    Just "0" -> pure Nothing
    _ -> phaseIO "jit-init" initJIT

  let shapeNames = M.fromList [(tid, fields) | (fields, tid) <- M.toList shapes]
      consTV = M.map (\(t, v, _) -> (t, v)) cons
      dataFile = dropExtension path ++ ".soldata"
  journalFile <- if dumpAsm then pure "" else runJournalPath (dropExtension path)
  rt <- newRtCounts
  -- heal first: an earlier run of this script may have crashed mid-commit
  unless dumpAsm $ phaseIO "journal-recover" (recoverScriptJournals (dropExtension path))
  -- a panic ends the run with the clean SOL PANIC line and exit 1 — not
  -- the raw `fpr: user error (...)` wrapper. Nothing was committed: the
  -- exception propagates out of runTxLoop before its commit call.
  unless dumpAsm $ do
    r <- try (phase "execute" $ runTxLoop retryPolicy (takeDirectory path) scriptArgs dataFile journalFile consTV shapeNames bprog prog jc cons runList rt 0) :: IO (Either IOException ())
    case r of
      Right () -> pure ()
      Left e -> do
        let msg = if isUserError e then ioeGetErrorString e else show e
        hPutStrLn stderr (if "*** SOL PANIC" `isPrefixOf` msg then msg else "*** SOL PANIC: " ++ msg ++ " ***")
        exitFailure

parseSolArgs :: Bool -> RetryPolicy -> [String] -> Either String (Bool, RetryPolicy, FilePath, [String])
parseSolArgs asm policy ("--asm":rest) = parseSolArgs True policy rest
parseSolArgs asm policy ("--":path:rest) = Right (asm,policy,path,rest)
parseSolArgs asm _ (flag:rest) | "--retry-policy=" `isPrefixOf` flag =
  parseRetryPolicy (drop (length "--retry-policy=") flag) >>= \policy -> parseSolArgs asm policy rest
parseSolArgs asm policy (path:rest)
  | not ("-" `isPrefixOf` path) = Right (asm,policy,path,rest)
  | otherwise = Left ("unknown Sol option " ++ path ++ "; " ++ solUsage)
parseSolArgs _ _ _ = Left solUsage

solUsage :: String
solUsage = "usage: sol [--asm] [--retry-policy=guarded|legacy] <script.sol> [args] | --repl [args]"

solHelp :: String
solHelp = unlines
  [ solUsage
  , "       sol --help | --version | state | recover"
  , "Script arguments follow the script, without shell interpretation."
  , "--repl: interactive session; one command, one transaction (Ctrl-D exits)."
  , "state: list retained recovery journals and live/dead owners."
  , "recover: replay dead-owner journals; errors retain their recovery fences."
  , "State: SOL_STATE_DIR, XDG_STATE_HOME/sol, or ~/.local/state/sol."
  , "Cache: SOL_CACHE_DIR, XDG_CACHE_HOME/sol, or ~/.sol/cache."
  , "Recovery may complete previously committed external effects; see the Sol installation guide."
  ]

evalForSafety :: STop -> STop
evalForSafety (TEval e) = TBind "main" [] [] e
evalForSafety t = t

-- The parsed prelude. Parsing the ~450-line text costs ~30 ms; the result
-- depends only on this executable, so it is cached under the executable's
-- identity (Sol.Cache.cachedPrelude; SOL_CACHE=0 always parses).
preludeTops :: IO [STop]
preludeTops = do
  r <- cachedPrelude prelude (pure (either (Left . errorBundlePretty) (\ts -> Right ("", ts)) (parse program "<prelude>" prelude)))
  case r of
    Right (_, ts) -> pure ts
    Left e -> diagnostic e >> exitFailure >> pure []

-- Incremental prelude (docs/2026-10-29-SOL-INCREMENTAL-PRELUDE.md): compile
-- against only the prelude declarations the program can name (Sol.Slice).
-- The sliced compile is a trial: its diagnostics are held, and if it is
-- rejected for any reason the program is compiled again with the whole
-- prelude, exactly as before, so every diagnostic a user sees comes from
-- the full pipeline. SOL_INCREMENTAL=0 always compiles the whole prelude;
-- SOL_INCREMENTAL=trace reports slice sizes and fallbacks on stderr.
compilePrepared :: FilePath -> String -> [STop] -> [STop] -> [STop] -> S.Set Name -> IO Prepared
compilePrepared path src ptops utops expanded trusted = do
  mode <- lookupEnv "SOL_INCREMENTAL"
  let full = compileScript False path src ptops utops expanded trusted
      trace msg = when (mode == Just "trace") (hPutStrLn stderr ("[sol incremental] " ++ msg))
  -- SOL_TYPES / SOL_WIDTHS print inferred types: always the full program
  inspect <- mapM lookupEnv ["SOL_TYPES", "SOL_WIDTHS"]
  if mode == Just "0" || Just "1" `elem` inspect
    then full
    else do
      r <- try (withBufferedDiagnostics (compileScript True path src ptops utops expanded trusted >>= evaluate . force))
      case r of
        -- typed-hole notes print type-variable names, which depend on the
        -- whole program's fresh-variable supply: a compile that has one is
        -- redone in full so the wording is the full pipeline's. Other notes
        -- (realtime escapes, the notypes pragma) name only user code.
        Right (prepared, held)
          | any ("[hole]" `isPrefixOf`) held -> trace "typed-hole note; full prelude" >> full
          | otherwise -> mapM_ (hPutStrLn stderr) held >> pure prepared
        Left (e :: SomeException)
          | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
          | otherwise -> trace ("sliced compile rejected (" ++ takeWhile (/= '\n') (show e) ++ "); full prelude") >> full

-- Successful compiler output is pure data; transactions, actors, JIT state and
-- script arguments are deliberately created outside this cached boundary.
compileScript :: Bool -> FilePath -> String -> [STop] -> [STop] -> [STop] -> S.Set Name -> IO Prepared
compileScript slicing path src ptopsAll utops utopsX0' trusted = do
  noteRef <- newIORef []
  let note msg = modifyIORef' noteRef (msg :) >> diagnostic msg
  let sources=M.singleton path src
      anchors=M.union (bindAnchors path src utops) (evalAnchors path src)
      anchored=map (anchorMsg sources anchors)
      anchoredDiagnostics=map (SourceDiagnostic.renderSourceDiagnostic sources anchors)
  -- `Rand = rnd.Rand.` where the target is an imported STRUCT: resolve the
  -- local alias by rewriting every `Rand` / `Rand.f` reference to the
  -- canonical spliced name, so field calls hit the flat globals and
  -- struct-literal call sites still monomorphize. (Targets that are types
  -- or constructors keep the existing TAlias behavior untouched.)
  let utopsX1 = aliasStructRefs utopsX0'

  -- first-class paths (docs/2026-08-27-PATHS.md): the same surface rewrite the AOT
  -- pipeline runs -- @Shape.field literals validate against the merged
  -- program's declared shapes and desugar to {get,set,segs} records,
  -- bare @Shape to the flattened schema; sol file-path literals
  -- (lowercase / '/' roots) pass through untouched.
  let (pathErrs, utopsX0) = expandPathLits (shapeTyTable utopsX1) (typeTyTable utopsX1) utopsX1
  unless (null pathErrs) $ do
    diagnostic "=== PATH LITERALS: ERRORS ==="
    mapM_ (diagnostic . ("  * " ++)) pathErrs
    exitFailure

  -- incremental prelude (Sol.Slice): the prelude declarations this program
  -- can name, found from the program AFTER alias/path expansion so names the
  -- path codecs introduce (wireAnd, WRec, ...) are demanded like any other
  ptops <-
    if not slicing then pure ptopsAll else do
      mode <- lookupEnv "SOL_INCREMENTAL"
      let kept = slicePrelude (mentions utopsX0) (S.fromList (injectedNames ++ builtinNames)) ptopsAll
      when (mode == Just "trace") $
        hPutStrLn stderr ("[sol incremental] prelude " ++ show (length kept) ++ "/" ++ show (length ptopsAll) ++ " declarations")
      when (mode == Just "names") $
        hPutStrLn stderr ("[sol incremental] " ++ unwords [n | t <- kept, n <- case t of { TBind n _ _ _ -> [n]; TStruct n _ _ -> [n]; TSigDef n _ -> [n]; _ -> [] }])
      pure kept

  -- sigs / structs / (s : Sig) params — now including the PRELUDE stdlib
  -- structs (Numeric/Str/List): conformance-check, expand structs to flat
  -- globals + first-class records, TYPECHECK (HM + rows) which also
  -- resolves arith operators by operand type, then monomorphize
  let sigs = sigTable (ptops ++ utopsX0)
      structs = structTable (ptops ++ utopsX0)
      (perrs, ptopsExp) = expandStructs sigs ptops
      (structErrs1, topsExp) = expandStructs sigs utopsX0
  unless (null (perrs ++ structErrs1)) $ do
    diagnostic "=== SIG/STRUCT: ERRORS ==="
    mapM_ (diagnostic . ("  * " ++)) (perrs ++ structErrs1)
    exitFailure

  let contracts = preTable (ptopsExp ++ topsExp)
      contractErrors = validatePre contracts ++ validatePreUses contracts (ptopsExp ++ topsExp)
  unless (null contractErrors) $ do
    diagnostic "=== PRECONDITION: ERRORS ==="
    mapM_ (diagnostic . ("  * " ++)) (anchored contractErrors)
    exitFailure
  let checkedTops = snd (applyPreconds contracts (ptopsExp ++ topsExp))

  -- gradual boundary: `# sol:notypes` in a file header opts the run out
  -- of the checker (the MVU view DSL's heterogeneous node records need a
  -- Node ADT to type — a gen_view design decision, tracked in README)
  envNoTypes <- (== Just "1") <$> lookupEnv "SOL_NOTYPES"
  let pragmaNoTypes = any ("sol:notypes" `isPrefixOf`) (map (dropWhile (`elem` "# \t")) (take 20 (lines src)))
      noTypes = envNoTypes || pragmaNoTypes
  when pragmaNoTypes $ note "[sol] types: skipped (# sol:notypes pragma)"
  showTypes <- (== Just "1") <$> lookupEnv "SOL_TYPES"
  (combined, linsigs) <-
    if noTypes
      then pure (checkedTops, []) -- ops stay Int prims; debugging only
      else do
        let result=inferResult sigs structs checkedTops
            terrs0=inferenceDiagnostics result
            notes0=inferenceNotes result
            holes0=inferenceHoles result
            inferredLinSigs=inferenceLinearity result
            rewritten0=inferenceTops result
        (terrs, notes, holes, rewritten) <- phase "typecheck" $ pure (terrs0, notes0, holes0, rewritten0)
        let preludeNames = trusted <> S.fromList [n | TBind n _ _ _ <- ptopsExp]
            safety = checkSafety preludeNames (map evalForSafety (ptopsExp ++ topsExp)) notes
            serrs = safetyDiagnostics safety
            ssug = safetySuggestions safety
            userNames = S.fromList [n | TBind n _ _ _ <- topsExp]
        unless (null terrs) $ do
          diagnostic "=== TYPE ERRORS ==="
          mapM_ (diagnostic . ("  * " ++)) (anchoredDiagnostics terrs)
          exitFailure
        let namedHoles = [(n, t) | (n, t) <- holes, not (null n)]
        unless (null namedHoles) $ do
          diagnostic "=== TYPED HOLES ==="
          mapM_ (\(n, t) -> diagnostic ("  * got into a typed hole, ?" ++ n ++ " : " ++ t)) namedHoles
          exitFailure
        mapM_ (\(_, t) -> note ("[hole] ?? (runtime trap) : " ++ t)) [h | h@(n, _) <- holes, null n]
        -- the safe/unsafe line, HostedBytecode profile: same checker,
        -- same rules as the AOT path (SOL_NO_SAFETY=1 for transition)
        noSafety <- (== Just "1") <$> lookupEnv "SOL_NO_SAFETY"
        unless (noSafety || null serrs) $ do
          diagnostic "=== SAFETY: the safe/unsafe line ==="
          mapM_ (diagnostic . ("  * " ++)) (anchoredDiagnostics serrs)
          sug <- lookupEnv "FPR_UNSAFE_SUGGEST"
          when (sug == Just "1") $ mapM_ (diagnostic . ("SUGGEST " ++)) ssug
          exitFailure
        when showTypes $ do
          diagnostic "=== INFERRED TYPES ==="
          forM_ [nt | nt@(n, _) <- notes, S.member n userNames] $ \(n, t) ->
            diagnostic ("  " ++ n ++ " : " ++ t)
        pure (rewritten, inferredLinSigs)

  (structErrs2, topsSpec) <- phase "specialize" $ pure (specialize sigs structs combined)
  let allX = erasePSig topsSpec
  showWidths <- (== Just "1") <$> lookupEnv "SOL_WIDTHS"
  when showWidths $ do
    diagnostic "=== NUMERIC WIDTHS (advisory) ==="
    mapM_ diagnostic (widthReport allX)
  unless (null structErrs2) $ do
    diagnostic "=== SIG/STRUCT: ERRORS ==="
    mapM_ (diagnostic . ("  * " ++)) structErrs2
    exitFailure

  -- realtime escapes are opt-in and loud: report every use site's NAME and
  -- count before the script runs, with the transactional alternative. The
  -- prelude's own five wrapper definitions are skipped (they are the
  -- plumbing, not a use).
  let rtUses = scanRealtime allX
  unless (M.null rtUses) $ do
    note ("=== REALTIME ESCAPES: " ++ show (sum (M.elems rtUses)) ++ " use(s) ===")
    forM_ (M.toList rtUses) $ \(n, c) ->
      note ("  " ++ n ++ " x" ++ show c ++ "  — " ++ rtWhy n)
    note "  this script is NOT atomic with respect to those paths/commands"

  -- `> expr.` becomes an anonymous zero-arg binding, run in file order
  -- (prelude has no evals, so numbering over the combined list is identical)
  let (tops, evalNames) = numberEvals allX

  -- Use the shared checker's explicit, inferred and primitive ownership
  -- signatures in the same priority order as the native frontend.
  let li0 = buildLinInfo tops
      li = li0 {liSigs = liSigs li0 `M.union` M.fromList linsigs
                          `M.union` builtinLinShapes (liLinTys li0)}
      linearity = checkLinearity li tops
      lerrs = linearityDiagnostics linearity
  unless (null lerrs) $ do
    diagnostic "=== LINEARITY: ERRORS ==="
    mapM_ (diagnostic . ("  * " ++)) (anchoredDiagnostics lerrs)
    exitFailure

  (cons, shapes) <- phase "layout" $ pure (collectCons tops, collectShapes (shapeSeed ptopsAll ++ tops))
  -- The shared frontend stores UTF-8 bytes; the VM uses Chars.
  prog <- phase "lower" $ pure (decodeProgStrings (fst (runState (compileTop tops >>= liftFix) (DEnv 0 cons shapes [] []))))
  noSpec <- (== Just "1") <$> lookupEnv "FPR_NO_SPEC"
  let specialized = if noSpec then prog else specializeFunctions "sol" halArities M.empty prog
  bprog <- phase "bytecode" $ pure (compileProg halArities specialized)

  -- `>` statements run in file order; a zero-arity `main`, if defined,
  -- runs after them (so plain FPRISC-style files still do something)
  let runList =
        evalNames ++ case M.lookup "main" bprog of
          Just fn | fnArity fn == 0 -> ["main"]
          _ -> []
  notes <- readIORef noteRef
  -- Ship only what the run can reach. The whole prelude is compiled into
  -- every program, but a one-liner touches a handful of it; the compile
  -- cache decodes whatever is stored, so unreachable prelude code was the
  -- dominant warm-start cost (docs/2026-10-29-SOL-STARTUP-ANALYSIS.md).
  let live = reachableFns bprog runList
      shake m = M.restrictKeys m live
  pure (Prepared cons shapes (shake specialized) (shake bprog) runList (reverse notes))

-- Names reachable from the run roots through static calls, tail calls and
-- globals-as-values. HCall targets are HAL symbols, not program functions.
reachableFns :: BProg -> [Name] -> S.Set Name
reachableFns bprog = go S.empty
  where
    go seen [] = seen
    go seen (n : rest)
      | S.member n seen = go seen rest
      | otherwise = case M.lookup n bprog of
          Nothing -> go seen rest
          Just fn -> go (S.insert n seen) (concatMap refs (toList (fnCode fn)) ++ rest)
    refs (Call _ g _) = [g]
    refs (TailCall g _) = [g]
    refs (MkPap _ g) = [g]
    refs _ = []

-- run every `>` statement in order inside one transaction, then commit;
-- on read-set conflict, reset and re-run the whole script
runTxLoop :: RetryPolicy -> FilePath -> [String] -> FilePath -> FilePath -> M.Map Name (Int, Int) -> M.Map Int [Name] -> BProg -> Prog -> Maybe JitCtx -> M.Map Name (Int, Int, Int) -> [Name] -> RtCounts -> Int -> IO ()
runTxLoop retryPolicy base scriptArgs dataFile journalFile consTV shapeNames bprog core jc cons topNames rt attempt = bracket newTx txCleanup $ \tx -> do
  txSetRetryPolicy tx retryPolicy
  txSetSagaJournal tx journalFile
  fuel <- newIORef fuelQuantum
  preempts <- newIORef 0
  gpu <- phaseIO "gpu-init" Gpu.initGPU
  tabFlag <- lookupEnv "SOL_TABLE"
  tab <- if tabFlag == Just "0" then pure Nothing else Just <$> newIORef M.empty
  actors <- VM.newActorRuntime
  requestedExit <- newIORef 0
  let env = VMEnv base dataFile consTV shapeNames bprog core jc gpu tab (mkHal cons scriptArgs tx preempts rt) fuel preempts tx actors
      cleanup = VM.shutdownActorRuntime actors
  res <- (do
    (forM_ topNames $ \n -> do
      _ <- execFn env n []
      pure ()) `catch` \(ScriptIO.ScriptExit code) -> writeIORef requestedExit code
    statsFlag <- lookupEnv "SOL_TABLE_STATS"
    when (statsFlag == Just "1") $ VM.dumpTabStats env
    -- Every attempt owns its actor world. Actors still live at the boundary
    -- are cancelled and joined before commit or retry, so they cannot retain
    -- a discarded TxState or leave messages for the next attempt.
    liveA <- VM.liveSpawnedActors actors
    unless (null liveA) $
      diagnostic ("[sol] WARNING: " ++ show (length liveA) ++ " spawned actor(s) still running at the transaction boundary — "
                  ++ "cancelling them before the transaction boundary "
                  ++ "(join first: have each send a done message and receive it before the script ends)")
    cleanup
    txCleanupProcesses tx
    forceN <- lookupEnv "SOL_FORCE_RETRY"
    let force = maybe 0 read forceN :: Int
    if attempt < force
      then pure (Conflict ["<forced>"]) -- discard this attempt's effects
      else phaseIO "transaction-commit" (commit tx journalFile)) `onException` (cleanup `finally` rollbackSaga tx)
  case res of
    Committed n ncmd sfail efail -> do
      -- the receipt names every effect class that landed: files AND the
      -- deferred commands that ran inside the commit (a script that only
      -- queued commands still did something at commit)
      let cmds = if ncmd > 0 then " + " ++ show ncmd ++ " deferred command(s)" else ""
      when ((n > 0 || ncmd > 0) && not sfail && not efail) $ verbose ("[sol] committed " ++ show n ++ " file(s)" ++ cmds ++ " (file transaction committed; external commands are not atomic)")
      when (sfail && not efail) $ diagnostic ("[sol] committed " ++ show n ++ " file(s); NOT atomic: a deferred command failed (later queued commands skipped; file effects all applied)")
      when efail $ diagnostic ("[sol] committed " ++ show n ++ " file(s); FAILED: a file effect did not reach its goal state (named above; later queued commands skipped)")
      -- if the run left the transaction at any point, say so plainly: the
      -- file commit does not make immediate external effects atomic
      total <- rtTotal rt
      when (total > 0) $ do
        kinds <- rtReport rt
        diagnostic ("[sol] NOT atomic overall: " ++ show total
                    ++ " realtime escape(s) — " ++ intercalate ", " kinds)
      -- `log` lines mean what they say happened: only a run whose every
      -- effect reached its goal state emits them, once, after the commit
      logs <- txTakeLogs tx
      if sfail || efail
        then do
          unless (null logs) $ diagnostic ("[sol] " ++ show (length logs) ++ " log line(s) withheld: the commit did not complete")
          exitFailure
        else do
          mapM_ putStrLn logs >> hFlush stdout
          code <- readIORef requestedExit
          when (code /= 0) (exitWith (ExitFailure code))
    Conflict stale -> do
      unsafe <- txRetryRefusal tx
      rollbackSaga tx `finally` txCleanup tx
      unless (null unsafe) $ do
        diagnostic ("[sol] conflict on " ++ show stale ++ "; guarded retry refused after immediate external effects: " ++ intercalate ", " unsafe)
        diagnostic "[sol] partial external execution may have occurred; buffered file effects were discarded. Mark only known repeatable work with Script.replayable/Proc.queryReplayable, or explicitly select --retry-policy=legacy."
        exitFailure
      retry stale
  where
    retry stale
      | attempt + 1 >= maxRetries = do
          diagnostic ("[sol] giving up after " ++ show maxRetries ++ " attempts (conflicts on " ++ show stale ++ ")")
          exitFailure
      | otherwise = do
          diagnostic ("[sol] conflict on " ++ show stale ++ " — retrying (attempt " ++ show (attempt + 2) ++ ")")
          runTxLoop retryPolicy base scriptArgs dataFile journalFile consTV shapeNames bprog core jc cons topNames rt (attempt + 1)

-- ---- the REPL: one command, one transaction -------------------------------
-- docs/2026-10-29-SOL-REPL-DESIGN.md. The session is a growing source text:
-- each command recompiles the accumulated program (in memory; the module
-- disk cache is bypassed) and executes ONLY its own evals in a fresh
-- transaction. Definitions persist because they stay in the program —
-- checked purity means they carry no state needing transactional
-- protection. Effects, handles and actors die with their command. Guarded
-- retry only, at command granularity: a clean conflict re-runs the
-- command; a conflict after realtime escapes is reported, never replayed;
-- a panic or Ctrl-C aborts the command's transaction and returns to the
-- prompt. Sessions cannot redefine a name (the accumulated program is the
-- environment; redefinition would need incremental compilation). Each
-- command compiles against only the prelude declarations the session names
-- (docs/2026-10-29-SOL-INCREMENTAL-PRELUDE.md); the prelude is parsed once.

replMaxAttempts :: Int
replMaxAttempts = 12

runRepl :: [String] -> IO ()
runRepl scriptArgs = do
  tty <- hIsTerminalDevice stdin
  base <- getCurrentDirectory
  rt <- newRtCounts
  jitFlag <- lookupEnv "SOL_JIT"
  jc <- case jitFlag of
    Just "0" -> pure Nothing
    _ -> initJIT
  gpu <- Gpu.initGPU
  ptops <- preludeTops
  trustedPaths <- trustedLibraryPaths
  seenRef <- newIORef M.empty
  trustRef <- newIORef S.empty
  recoverScriptJournals "sol-repl"
  journalFile <- runJournalPath "sol-repl"
  tmp <- getTemporaryDirectory
  now <- getPOSIXTime
  let dataFile = tmp ++ "/sol-repl-" ++ show (floor (now * 1000000) :: Integer) ++ ".soldata"
  when tty $
    putStrLn "Sol 0.12.0 (scripting API 1) — one command, one transaction. Ctrl-D exits."
  let
    loop tty acc buffer evalsDone defined = do
      when tty (putStr (if null buffer then "sol> " else "...> ") >> hFlush stdout)
      got <- try (hGetLine stdin) :: IO (Either IOException String)
      case got of
        Left _ -> do
          when tty (putStrLn "")
          exitWith ExitSuccess
        Right line
          | all isSpace line && null buffer -> loop tty acc buffer evalsDone defined
          | otherwise -> do
              let buffer' = if null buffer then line ++ "\n" else buffer ++ line ++ "\n"
                  trial = acc ++ buffer'
              case parse program "<repl>" trial of
                Left e
                  -- a def ending mid-'.' keeps the buffer and prompts for
                  -- more; a blank line while waiting is the way out
                  | "unexpected end of input" `isInfixOf` errorBundlePretty e ->
                      if all isSpace line && not (null buffer)
                        then do
                          hPutStrLn stderr "[repl] incomplete input discarded"
                          loop tty acc "" evalsDone defined
                        else loop tty acc buffer' evalsDone defined
                  | otherwise -> do
                      hPutStr stderr (errorBundlePretty e)
                      hPutStrLn stderr "[repl] input rejected"
                      loop tty acc "" evalsDone defined
                Right tops -> do
                  -- names THIS command adds: parse the new lines alone, so
                  -- the accumulated program's own definitions do not clash
                  -- with themselves
                  let cmdNames = case parse program "<cmd>" buffer' of
                        Right ts -> S.fromList (concatMap replTopName ts)
                        Left _ -> S.empty
                      clash = S.toList (S.intersection cmdNames defined)
                  if not (null clash)
                    then do
                      hPutStrLn stderr ("[repl] already defined this session: " ++ unwords clash
                                        ++ " (restart the session to redefine)")
                      loop tty acc "" evalsDone defined
                    else do
                      r <- try (runReplCommand base scriptArgs dataFile journalFile
                                  ptops trustedPaths seenRef trustRef rt jc gpu
                                  trial tops evalsDone)
                      case r of
                        Left (_ :: ExitCode) ->
                          -- compile rejected the line: its diagnostics are
                          -- printed; the accumulated source stays as it was
                          loop tty acc "" evalsDone defined
                        Right evals' -> loop tty trial "" evals' (S.union defined cmdNames)
  loop tty "" "" 0 S.empty

-- top-level names a command defines (for the no-redefinition rule)
replTopName :: STop -> [Name]
replTopName (TBind n _ _ _) = [n]
replTopName (TType n _ _ _) = [n]
replTopName _ = []

-- compile the accumulated program, execute only the new evals, commit.
-- Panics/interrupts abort the command's transaction but still consume the
-- command (it is in the program text; never silently re-run later).
runReplCommand :: FilePath -> [String] -> FilePath -> FilePath -> [STop] -> S.Set FilePath
               -> IORef (M.Map FilePath String) -> IORef (S.Set FilePath) -> RtCounts
               -> Maybe JitCtx -> Maybe Gpu.GpuCtx -> String -> [STop] -> Int -> IO Int
runReplCommand base scriptArgs dataFile journalFile ptops trustedPaths seenRef trustRef rt jc gpu trial tops evalsDone = do
  expanded <- expandUses 8 "" trustedPaths trustRef seenRef ".sol" base tops
  trusted <- readIORef trustRef
  prepared <- compilePrepared "<repl>" trial ptops tops expanded trusted
  let Prepared cons shapes prog bprog runList _ = prepared
  writeIORef VM.conNames
    [ ((t, v, ar), reverse (takeWhile (/= '.') (reverse c)))
    | (c, (t, v, ar)) <- M.toList cons, M.notMember c builtinCons
    ]
  let newRuns = drop evalsDone runList
      consTV = M.map (\(t, v, _) -> (t, v)) cons
      shapeNames = M.fromList [(tid, fields) | (fields, tid) <- M.toList shapes]
  if null newRuns
    then pure (length runList) -- pure definitions: nothing to execute or commit
    else do
      let done = pure (length runList)
      (replExecCommit base scriptArgs dataFile journalFile consTV shapeNames
         bprog prog jc gpu cons newRuns rt (0 :: Int)
         >> done) `catches`
        [ Handler (\(ScriptIO.ScriptExit code) -> exitWith (ExitFailure code)),
          Handler (\UserInterrupt ->
            diagnostic "[repl] interrupted — command aborted, its transaction discarded" >> done),
          Handler (\(e :: IOException) -> do
            let msg = if isUserError e then ioeGetErrorString e else show e
            hPutStrLn stderr (if "*** SOL PANIC" `isPrefixOf` msg then msg else "*** SOL PANIC: " ++ msg ++ " ***")
            done)
        ]

-- the command's own mini runTxLoop: fresh transaction, run the new evals,
-- commit; clean conflicts retry the command, guarded refusals stop it
replExecCommit base scriptArgs dataFile journalFile consTV shapeNames bprog prog jc gpu cons newRuns rt attempt =
  bracket newTx txCleanup $ \tx -> do
    txSetRetryPolicy tx GuardedRetry
    txSetSagaJournal tx journalFile
    fuel <- newIORef fuelQuantum
    preempts <- newIORef 0
    tabFlag <- lookupEnv "SOL_TABLE"
    tab <- if tabFlag == Just "0" then pure Nothing else Just <$> newIORef M.empty
    actors <- VM.newActorRuntime
    let env = VMEnv base dataFile consTV shapeNames bprog prog jc gpu tab (mkHal cons scriptArgs tx preempts rt) fuel preempts tx actors
        cleanup = VM.shutdownActorRuntime actors
    res <- (do
      requestedExit <- newIORef 0
      (forM_ newRuns $ \n -> do
        _ <- execFn env n []
        pure ()) `catch` \(ScriptIO.ScriptExit code) -> writeIORef requestedExit code
      liveA <- VM.liveSpawnedActors actors
      unless (null liveA) $
        diagnostic ("[sol] WARNING: " ++ show (length liveA) ++ " spawned actor(s) still running at the transaction boundary — "
                    ++ "cancelling them before the transaction boundary "
                    ++ "(join first: have each send a done message and receive it before the script ends)")
      cleanup
      txCleanupProcesses tx
      code <- readIORef requestedExit
      if code /= 0
        then throwIO (ScriptIO.ScriptExit code)
        else phaseIO "transaction-commit" (commit tx journalFile)) `onException` (cleanup `finally` rollbackSaga tx)
    case res of
      Committed n ncmd sfail efail -> do
        let cmds = if ncmd > 0 then " + " ++ show ncmd ++ " deferred command(s)" else ""
        when ((n > 0 || ncmd > 0) && not sfail && not efail) $
          verbose ("[sol] committed " ++ show n ++ " file(s)" ++ cmds ++ " (file transaction committed; external commands are not atomic)")
        when (sfail && not efail) $
          diagnostic ("[sol] committed " ++ show n ++ " file(s); NOT atomic: a deferred command failed (later queued commands skipped; file effects all applied)")
        when efail $
          diagnostic ("[sol] committed " ++ show n ++ " file(s); FAILED: a file effect did not reach its goal state (named above; later queued commands skipped)")
        total <- rtTotal rt
        when (total > 0) $ do
          kinds <- rtReport rt
          diagnostic ("[sol] NOT atomic overall: " ++ show total ++ " realtime escape(s) — " ++ intercalate ", " kinds)
        logs <- txTakeLogs tx
        if sfail || efail
          then unless (null logs) $
                 diagnostic ("[sol] " ++ show (length logs) ++ " log line(s) withheld: the commit did not complete")
          else mapM_ putStrLn logs >> hFlush stdout
      Conflict stale -> do
        unsafe <- txRetryRefusal tx
        rollbackSaga tx `finally` txCleanup tx
        unless (null unsafe) $ do
          diagnostic ("[sol] conflict on " ++ show stale ++ "; guarded retry refused after immediate external effects: " ++ intercalate ", " unsafe)
          diagnostic "[sol] partial external execution may have occurred; buffered file effects were discarded. Mark only known repeatable work with Script.replayable/Proc.queryReplayable, or explicitly select --retry-policy=legacy."
        when (null unsafe) $
          if attempt + 1 >= replMaxAttempts
            then diagnostic ("[sol] giving up on this command after " ++ show replMaxAttempts ++ " attempts (conflicts on " ++ show stale ++ "); effects discarded")
            else do
              diagnostic ("[sol] conflict on " ++ show stale ++ " — retrying command (attempt " ++ show (attempt + 2) ++ ")")
              replExecCommit base scriptArgs dataFile journalFile consTV shapeNames bprog prog jc gpu cons newRuns rt (attempt + 1)

numberEvals :: [STop] -> ([STop], [Name])
numberEvals tops = (map fst numbered, [n | (_, Just n) <- numbered])
  where
    numbered = go (0 :: Int) tops
    go _ [] = []
    go i (TEval e : rest) =
      let n = "top__" ++ show i
       in (TBind n [] [] e, Just n) : go (i + 1) rest
    go i (t : rest) = (t, Nothing) : go i rest

-- THE FOLD, COMPLETE: one grammar (FPRISC.program, re-exported through
-- Sol.Lang).  There is no second parser to fall back to.
parseOrDie :: String -> String -> IO [STop]
parseOrDie name src = case parse program name src of
  Left e -> diagnostic (errorBundlePretty e) >> exitFailure >> pure []
  Right t -> pure t

-- ---- compile-time module import ---------------------------------------------
-- Recognize `m = use "name#hash".` at top level: resolve + hash-verify the
-- module, recursively expand ITS uses, rename every top-level definition
-- under the alias, and splice the result in front of the user tops.
--
-- DEDUP BY CONTENT HASH: two imports of the same module (directly, or
-- nested at any depth) splice ONCE. `seen` maps module hash -> the FINAL
-- fully-prefixed name of the canonical splice; later aliases just rewrite
-- their qualified references onto it. This is what keeps one type ONE type:
-- a PT built by a library's internal logic import unifies with the app's
-- own logic import because they are literally the same declarations.
expandUses :: Int -> String -> S.Set FilePath -> IORef (S.Set Name) -> IORef (M.Map String String) -> String -> FilePath -> [STop] -> IO [STop]
expandUses 0 _ _ _ _ _ _ _ = diagnostic "[sol] use: module nesting too deep" >> exitFailure >> pure []
expandUses depth prefix trustedPaths trustRef seenRef impExt baseDir tops = do
  let aliases = [(mn, spec) | TUse mn spec <- tops]
  pairs <- forM aliases $ \(mn, spec) -> do
    r <- resolveModuleParsed impExt baseDir spec
    case r of
      Left e -> diagnostic e >> exitFailure >> pure ([], (mn, mn))
      Right (mpath, h, pinned, mtops0) -> do
        approved <- (`S.member` trustedPaths) <$> canonicalizePath mpath
        when approved $ modifyIORef' trustRef (<> S.fromList
          ([prefix ++ mn ++ "." ++ n | TBind n _ _ _ <- mtops0]
           ++ [prefix ++ mn ++ "." ++ n ++ "." ++ f | TStruct n _ fs <- mtops0, (f, _) <- fs]))
        unless pinned $
          verbose ("[sol] use (compile): " ++ spec ++ " resolves to " ++ spec ++ "#" ++ h ++ " (pin this)")
        seen <- readIORef seenRef
        case M.lookup h seen of
          Just finalName -> do
            -- already spliced somewhere: alias onto the canonical copy
            let localName =
                  if prefix `isPrefixOf` finalName
                    then drop (length prefix) finalName
                    else finalName
            pure ([], (mn, localName))
          Nothing -> do
            modifyIORef' seenRef (M.insert h (prefix ++ mn))
            mtops1 <- expandUses (depth - 1) (prefix ++ mn ++ ".") trustedPaths trustRef seenRef (takeExtension mpath) (takeDirectory mpath) mtops0
            let defs = [t | t <- mtops1, notEval t]
                rn = M.fromList [(n, mn ++ "." ++ n) | n <- topNames defs]
            pure (renameTops rn defs, (mn, mn))
  let aliasMap = M.fromList (map snd pairs)
  pure (concatMap fst pairs ++ qualifyUses aliasMap tops)
  where
    notEval TEval {} = False
    notEval _ = True

-- rewrite references through `Local = target.` aliases whose target the
-- merged program DEFINES: structs (the original case), and -- for the
-- .fpr sketch tier -- types, constructors and values re-exported from a
-- spliced module (`MQuit = MV.MQuit.`, `STick = MV.STick.`).  Renames
-- expressions, PATTERNS (a case arm `ETick -> ...` is a PCon), and sig
-- types; alias chains resolve transitively (bounded).  Alias names are
-- capitalized by grammar, locals lowercase, so shadowing cannot occur.
aliasStructRefs :: [STop] -> [STop]
aliasStructRefs tops
  | M.null amap = tops
  | otherwise = map top tops
  where
    structNames = S.fromList [n | TStruct n _ _ <- tops]
    defined = S.union structNames (S.fromList (topNames tops))
    amap = M.fromList [(t, tgt) | TAlias t tgt <- tops, S.member tgt defined]
    ren = renFuel (8 :: Int)
    renFuel 0 v = v
    renFuel fuel v = case M.lookup v amap of
      Just tgt -> renFuel (fuel - 1) tgt
      Nothing -> case break (== '.') v of
        (h, '.' : rest) | Just tgt <- M.lookup h amap -> renFuel (fuel - 1) (tgt ++ "." ++ rest)
        _ -> v
    rp = \case
      PCon c ps -> PCon (ren c) (map rp ps)
      PTup ps -> PTup (map rp ps)
      o -> o
    rt = \case
      TCon n as -> TCon (ren n) (map rt as)
      TTup ts -> TTup (map rt ts)
      TArrT a b -> TArrT (rt a) (rt b)
      o -> o
    re bs = transformEP (\_ e -> case e of SVar v -> SVar (ren v); _ -> e) rp bs
    top = \case
      TBind n ps g b ->
        let (bs, g') = renGuards re rp (S.fromList (concatMap patVars ps)) g
         in TBind n (map rp ps) g' (re bs b)
      TEval e -> TEval (re S.empty e)
      TStruct n sigs fs -> TStruct n sigs [(f, re S.empty e) | (f, e) <- fs]
      TSig n (ps, r) pcs -> TSig n (map rt ps, rt r) pcs
      other -> other

-- ---- realtime escape reporting --------------------------------------------

realtimeNames :: [Name]
realtimeNames = ["readNow", "writeNow", "appendNow", "shNow", "readLineNow"]

rtWhy :: Name -> String
rtWhy "readNow" = "re-reads the disk, not snapshotted, not validated at commit (transactional: readPath)"
rtWhy "writeNow" = "hits the disk before commit and survives a rollback (transactional: writePath)"
rtWhy "appendNow" = "appends before commit and survives a rollback (transactional: writePath)"
rtWhy "shNow" = "streams a command live; guarded retry stops on a later conflict (deferred: shq)"
rtWhy "readLineNow" = "reads stdin now; guarded retry stops on a later conflict (snapshot: input)"
rtWhy n = n

-- Count realtime uses in code this run can actually REACH.
--
-- Reachability matters because `use` splices a whole module in: a library
-- with one realtime helper would otherwise make every importer report an
-- escape it never performs, and a warning you learn to ignore is worse than
-- no warning. Roots are the `>` statements plus a zero-arg `main`; from
-- there we follow references. The five prelude wrappers that DEFINE the
-- escapes are not themselves counted as uses.
scanRealtime :: [STop] -> M.Map Name Int
scanRealtime tops =
  M.filterWithKey (\k _ -> k `elem` realtimeNames) $
    M.fromListWith (+) [(n, 1 :: Int) | (owner, n) <- uses, owner `S.member` live]
  where
    -- name -> body references, for every binding
    refs = M.fromListWith (++) [(n, topVars t) | t@(TBind n _ _ _) <- tops]
    structRefs = M.fromListWith (++) [(n, topVars t) | t@(TStruct n _ _) <- tops]
    allRefs = M.unionWith (++) refs structRefs
    rootNames = concat [topVars t | t@(TEval _) <- tops] ++ ["main"]
    live = S.insert "<eval>" (grow (S.fromList rootNames) rootNames)
    grow seen [] = seen
    grow seen (n : rest) =
      let next = [m | m <- M.findWithDefault [] n allRefs, not (m `S.member` seen)]
       in grow (foldr S.insert seen next) (next ++ rest)
    -- (enclosing binding, referenced name); `> ...` bodies are always live
    uses =
      [("<eval>", n) | t@(TEval _) <- tops, n <- topVars t]
        ++ [ (owner, n)
             | t <- tops,
               Just owner <- [ownerOf t],
               not (owner `elem` realtimeNames),
               n <- topVars t
           ]
    ownerOf (TBind n _ _ _) = Just n
    ownerOf (TStruct n _ _) = Just n
    ownerOf _ = Nothing

topVars :: STop -> [Name]
topVars (TBind _ _ gs e) = concatMap exprVars (e : guardExprs gs)
topVars (TEval e) = exprVars e
topVars (TStruct _ _ fs) = concatMap (exprVars . snd) fs
topVars _ = []

exprVars :: SExpr -> [Name]
exprVars = go
  where
    go (SMark _ e) = go e
    go (SVar n) = [n]
    go (SApp a b) = go a ++ go b
    go (SLam _ b) = go b
    go (SBlock ss b) = concatMap stmt ss ++ go b
    go (SCase s alts) = go s ++ concatMap (go . snd) alts
    go (SBin _ a b) = go a ++ go b
    go (SProj e _) = go e
    go (SRec fs) = concatMap (go . snd) fs
    go (SUpd e fs) = go e ++ concatMap (go . snd) fs
    go (STup es) = concatMap go es
    go (SList es) = concatMap go es
    go (SStrI segs) = concat [go e | SegExpr e <- segs]
    go _ = []
    stmt (SBind _ _ e) = go e
    stmt (SBindPat _ e) = go e
