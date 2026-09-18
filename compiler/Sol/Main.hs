{-# LANGUAGE LambdaCase #-}

-- Main.hs — `sol script.sol`
--
-- Pipeline (front half reused verbatim from the FPRISC compiler):
--   prelude + script --> parse --> linearity check --> desugar --> lambda
--   lift --> BYTECODE (instead of RISC-V asm) --> Sol VM
--
-- The whole run is one transaction: reads snapshot host files, writes are
-- buffered, and at exit we lock / validate / commit / unlock. A validation
-- failure re-runs the script (STM retry) — see Txn.hs.

module Sol.Main where

import Sol.Bytecode
import Control.Exception (IOException, onException, try)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State.Strict (runState)
import Data.IORef
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Sol.Lang
import Sol.Mod (resolveModule)
import Sol.Preamble (halArities, prelude)
import Struct (erasePSig, expandStructs, sigTable, specialize, structTable)
import Safety (safetyCheck)
import Sol.Infer (inferTops)
import Sol.Width (widthReport)
import Sol.HandJIT (JitCtx, initJIT)
import System.Environment (getArgs, lookupEnv)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.IO.Error (ioeGetErrorString, isUserError)
import System.FilePath (dropExtension, takeDirectory, takeExtension)
import Text.Megaparsec (errorBundlePretty, parse)
import Sol.Txn
import qualified Sol.Gpu as Gpu
import Sol.VM hiding ()
import qualified Sol.VM as VM

maxRetries :: Int
maxRetries = 12

main :: IO ()
main = do
  setLocaleEncoding utf8
  as <- getArgs
  (dumpAsm, path, scriptArgs) <- case as of
    ("--asm" : p : rest) -> pure (True, p, rest)
    (p : rest) -> pure (False, p, rest)
    _ -> putStrLn "usage: sol [--asm] <script.sol> [args]" >> exitFailure >> pure (False, "", [])
  src <- readFile path
  ptops <- parseOrDie "<prelude>" prelude
  utops <- parseOrDie path src
  -- spans step 1: "in NAME:" diagnostics anchor to NAME's definition
  -- line in the script (spliced-module binds keep their module-naming)
  let anchored =
        map
          ( anchorMsg
              (M.singleton path src)
              (M.union (bindAnchors path src utops) (evalAnchors path src))
          )

  -- compile-time FILE-module expansion: `m = use "spec".` splices the module's
  -- definitions in, renamed under the alias; `m.f` references and
  -- `T = m.T.` constructor aliases then resolve against the merged program
  seenRef <- newIORef M.empty
  utopsX0' <- expandUses 8 "" seenRef (takeExtension path) (takeDirectory path) utops
  -- `Rand = rnd.Rand.` where the target is an imported STRUCT: resolve the
  -- local alias by rewriting every `Rand` / `Rand.f` reference to the
  -- canonical spliced name, so field calls hit the flat globals and
  -- struct-literal call sites still monomorphize. (Targets that are types
  -- or constructors keep the existing TAlias behavior untouched.)
  let utopsX1 = aliasStructRefs utopsX0'

  -- first-class paths (docs/PATHS.md): the same surface rewrite the AOT
  -- pipeline runs -- @Shape.field literals validate against the merged
  -- program's declared shapes and desugar to {get,set,segs} records,
  -- bare @Shape to the flattened schema; sol file-path literals
  -- (lowercase / '/' roots) pass through untouched.
  let (pathErrs, utopsX0) = expandPathLits (shapeTyTable utopsX1) utopsX1
  unless (null pathErrs) $ do
    putStrLn "=== PATH LITERALS: ERRORS ==="
    mapM_ (putStrLn . ("  * " ++)) pathErrs
    exitFailure

  -- sigs / structs / (s : Sig) params — now including the PRELUDE stdlib
  -- structs (Numeric/Str/List): conformance-check, expand structs to flat
  -- globals + first-class records, TYPECHECK (HM + rows) which also
  -- resolves arith operators by operand type, then monomorphize
  let sigs = sigTable (ptops ++ utopsX0)
      structs = structTable (ptops ++ utopsX0)
      (perrs, ptopsExp) = expandStructs sigs ptops
      (structErrs1, topsExp) = expandStructs sigs utopsX0
  unless (null (perrs ++ structErrs1)) $ do
    putStrLn "=== SIG/STRUCT: ERRORS ==="
    mapM_ (putStrLn . ("  * " ++)) (perrs ++ structErrs1)
    exitFailure

  -- gradual boundary: `# sol:notypes` in a file header opts the run out
  -- of the checker (the MVU view DSL's heterogeneous node records need a
  -- Node ADT to type — a gen_view design decision, tracked in README)
  envNoTypes <- (== Just "1") <$> lookupEnv "SOL_NOTYPES"
  let pragmaNoTypes = any ("sol:notypes" `isPrefixOf`) (map (dropWhile (`elem` "# \t")) (take 20 (lines src)))
      noTypes = envNoTypes || pragmaNoTypes
  when pragmaNoTypes $ putStrLn "[sol] types: skipped (# sol:notypes pragma)"
  showTypes <- (== Just "1") <$> lookupEnv "SOL_TYPES"
  combined <-
    if noTypes
      then pure (ptopsExp ++ topsExp) -- ops stay Int prims; debugging only
      else do
        let (terrs, notes, holes, rewritten) = inferTops sigs structs (ptopsExp ++ topsExp)
            preludeNames = S.fromList [n | TBind n _ _ _ <- ptopsExp]
            (serrs, ssug) = safetyCheck preludeNames (ptopsExp ++ topsExp) notes
            userNames = S.fromList [n | TBind n _ _ _ <- topsExp]
        unless (null terrs) $ do
          putStrLn "=== TYPE ERRORS ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored terrs)
          exitFailure
        let namedHoles = [(n, t) | (n, t) <- holes, not (null n)]
        unless (null namedHoles) $ do
          putStrLn "=== TYPED HOLES ==="
          mapM_ (\(n, t) -> putStrLn ("  * got into a typed hole, ?" ++ n ++ " : " ++ t)) namedHoles
          exitFailure
        mapM_ (\(_, t) -> putStrLn ("[hole] ?? (runtime trap) : " ++ t)) [h | h@(n, _) <- holes, null n]
        -- the safe/unsafe line, HostedBytecode profile: same checker,
        -- same rules as the AOT path (SOL_NO_SAFETY=1 for transition)
        noSafety <- (== Just "1") <$> lookupEnv "SOL_NO_SAFETY"
        unless (noSafety || null serrs) $ do
          putStrLn "=== SAFETY: the safe/unsafe line ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored serrs)
          sug <- lookupEnv "FPR_UNSAFE_SUGGEST"
          when (sug == Just "1") $ mapM_ (putStrLn . ("SUGGEST " ++)) ssug
          exitFailure
        when showTypes $ do
          putStrLn "=== INFERRED TYPES ==="
          forM_ [nt | nt@(n, _) <- notes, S.member n userNames] $ \(n, t) ->
            putStrLn ("  " ++ n ++ " : " ++ t)
        pure rewritten

  let (structErrs2, topsSpec) = specialize sigs structs combined
      allX = erasePSig topsSpec
  showWidths <- (== Just "1") <$> lookupEnv "SOL_WIDTHS"
  when showWidths $ do
    putStrLn "=== NUMERIC WIDTHS (advisory) ==="
    mapM_ putStrLn (widthReport allX)
  unless (null structErrs2) $ do
    putStrLn "=== SIG/STRUCT: ERRORS ==="
    mapM_ (putStrLn . ("  * " ++)) structErrs2
    exitFailure

  -- realtime escapes are opt-in and loud: report every use site's NAME and
  -- count before the script runs, with the transactional alternative. The
  -- prelude's own five wrapper definitions are skipped (they are the
  -- plumbing, not a use).
  let rtUses = scanRealtime allX
  unless (M.null rtUses) $ do
    putStrLn ("=== REALTIME ESCAPES: " ++ show (sum (M.elems rtUses)) ++ " use(s) ===")
    forM_ (M.toList rtUses) $ \(n, c) ->
      putStrLn ("  " ++ n ++ " x" ++ show c ++ "  — " ++ rtWhy n)
    putStrLn "  this script is NOT atomic with respect to those paths/commands"

  -- `> expr.` becomes an anonymous zero-arg binding, run in file order
  -- (prelude has no evals, so numbering over the combined list is identical)
  let (tops, evalNames) = numberEvals allX

  -- linearity: unchanged from the FPRISC front-end — this is what makes
  -- leaked / double-used handles a COMPILE error, not a runtime one
  let li = buildLinInfo tops
      lerrs = lcheck li tops
  unless (null lerrs) $ do
    putStrLn "=== LINEARITY: ERRORS ==="
    mapM_ (putStrLn . ("  * " ++)) (anchored lerrs)
    exitFailure

  let cons = collectCons tops
      shapes = collectShapes tops
      -- the shared desugar keeps string literals as UTF-8 bytes (the
      -- AOT codegen contract); the VM speaks Chars -- decode once here
      (prog0, _) = runState (compileTop tops >>= liftFix) (DEnv 0 cons shapes [])
      prog = decodeProgStrings prog0
      bprog = compileProg halArities prog

  when dumpAsm $ do
    forM_ (M.toList bprog) $ \(n, fn) -> putStrLn (disasm n fn)

  -- `>` statements run in file order; a zero-arity `main`, if defined,
  -- runs after them (so plain FPRISC-style files still do something)
  let runList =
        evalNames ++ case M.lookup "main" bprog of
          Just fn | fnArity fn == 0 -> ["main"]
          _ -> []
  when (null runList && not dumpAsm) $
    putStrLn "[sol] note: no `> expr.` statements and no main; nothing to run"

  -- JIT: one native tier per process (hand-rolled x86-64 / A64, no
  -- LLVM); the compile cache survives STM retries.  SOL_JIT=0 disables
  -- it (the interpreter handles everything); any other value, including
  -- the historical "hand", selects it.
  jitFlag <- lookupEnv "SOL_JIT"
  jc <- case jitFlag of
    Just "0" -> pure Nothing
    _ -> initJIT

  let shapeNames = M.fromList [(tid, fields) | (fields, tid) <- M.toList shapes]
      consTV = M.map (\(t, v, _) -> (t, v)) cons
      dataFile = dropExtension path ++ ".soldata"
      journalFile = dropExtension path ++ ".soljournal"
  rt <- newRtCounts
  -- heal first: a previous run of this script may have crashed mid-commit
  unless dumpAsm $ recoverJournal True journalFile
  -- a panic ends the run with the clean SOL PANIC line and exit 1 — not
  -- the raw `fpr: user error (...)` wrapper. Nothing was committed: the
  -- exception propagates out of runTxLoop before its commit call.
  unless dumpAsm $ do
    r <- try (runTxLoop (takeDirectory path) scriptArgs dataFile journalFile consTV shapeNames bprog prog jc cons runList rt 0) :: IO (Either IOException ())
    case r of
      Right () -> pure ()
      Left e -> do
        let msg = if isUserError e then ioeGetErrorString e else show e
        hPutStrLn stderr (if "*** SOL PANIC" `isPrefixOf` msg then msg else "*** SOL PANIC: " ++ msg ++ " ***")
        exitFailure

-- run every `>` statement in order inside one transaction, then commit;
-- on read-set conflict, reset and re-run the whole script
runTxLoop :: FilePath -> [String] -> FilePath -> FilePath -> M.Map Name (Int, Int) -> M.Map Int [Name] -> BProg -> Prog -> Maybe JitCtx -> M.Map Name (Int, Int, Int) -> [Name] -> RtCounts -> Int -> IO ()
runTxLoop base scriptArgs dataFile journalFile consTV shapeNames bprog core jc cons topNames rt attempt = do
  tx <- newTx
  fuel <- newIORef fuelQuantum
  preempts <- newIORef 0
  gpu <- Gpu.initGPU
  tabFlag <- lookupEnv "SOL_TABLE"
  tab <- if tabFlag == Just "0" then pure Nothing else Just <$> newIORef M.empty
  actors <- VM.newActorRuntime
  let env = VMEnv base dataFile consTV shapeNames bprog core jc gpu tab (mkHal cons scriptArgs tx preempts rt) fuel preempts tx actors
      cleanup = VM.shutdownActorRuntime actors
  res <- (do
    forM_ topNames $ \n -> do
      v <- execFn env n []
      unless (isUnit v) $ putStrLn ("=> " ++ VM.render v)
    statsFlag <- lookupEnv "SOL_TABLE_STATS"
    when (statsFlag == Just "1") $ VM.dumpTabStats env
    -- Every attempt owns its actor world. Actors still live at the boundary
    -- are cancelled and joined before commit or retry, so they cannot retain
    -- a discarded TxState or leave messages for the next attempt.
    liveA <- VM.liveSpawnedActors actors
    unless (null liveA) $
      putStrLn ("[sol] WARNING: " ++ show (length liveA) ++ " spawned actor(s) still running at the transaction boundary — "
                  ++ "cancelling them before the transaction boundary "
                  ++ "(join first: have each send a done message and receive it before the script ends)")
    cleanup
    forceN <- lookupEnv "SOL_FORCE_RETRY"
    let force = maybe 0 read forceN :: Int
    if attempt < force
      then pure (Conflict ["<forced>"]) -- discard this attempt's effects
      else commit tx journalFile) `onException` cleanup
  case res of
    Committed n ncmd sfail -> do
      -- the receipt names every effect class that landed: files AND the
      -- deferred commands that ran inside the commit (a script that only
      -- queued commands still did something at commit)
      let cmds = if ncmd > 0 then " + " ++ show ncmd ++ " deferred command(s)" else ""
      when ((n > 0 || ncmd > 0) && not sfail) $ putStrLn ("[sol] committed " ++ show n ++ " file(s)" ++ cmds ++ " atomically (whole-script transaction)")
      when sfail $ putStrLn ("[sol] committed " ++ show n ++ " file(s); NOT atomic: a deferred command failed (later queued commands skipped; file effects all applied)")
      -- if the run left the transaction at any point, say so plainly: the
      -- word "atomically" above is only true of the file set it names
      total <- rtTotal rt
      when (total > 0) $ do
        kinds <- rtReport rt
        putStrLn ("[sol] NOT atomic overall: " ++ show total
                    ++ " realtime escape(s) — " ++ intercalate ", " kinds)
      when sfail exitFailure
    Conflict stale
      | attempt + 1 >= maxRetries -> do
          putStrLn ("[sol] giving up after " ++ show maxRetries ++ " attempts (conflicts on " ++ show stale ++ ")")
          exitFailure
      | otherwise -> do
          putStrLn ("[sol] conflict on " ++ show stale ++ " — retrying (attempt " ++ show (attempt + 2) ++ ")")
          runTxLoop base scriptArgs dataFile journalFile consTV shapeNames bprog core jc cons topNames rt (attempt + 1)

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
  Left e -> putStrLn (errorBundlePretty e) >> exitFailure >> pure []
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
expandUses :: Int -> String -> IORef (M.Map String String) -> String -> FilePath -> [STop] -> IO [STop]
expandUses 0 _ _ _ _ _ = putStrLn "[sol] use: module nesting too deep" >> exitFailure >> pure []
expandUses depth prefix seenRef impExt baseDir tops = do
  let aliases = [(mn, spec) | TUse mn spec <- tops]
  pairs <- forM aliases $ \(mn, spec) -> do
    r <- resolveModule impExt baseDir spec
    case r of
      Left e -> putStrLn e >> exitFailure >> pure ([], (mn, mn))
      Right (mpath, h, pinned) -> do
        unless pinned $
          putStrLn ("[sol] use (compile): " ++ spec ++ " resolves to " ++ spec ++ "#" ++ h ++ " (pin this)")
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
            msrc <- readFile mpath
            mtops0 <- parseOrDie mpath msrc
            mtops1 <- expandUses (depth - 1) (prefix ++ mn ++ ".") seenRef (takeExtension mpath) (takeDirectory mpath) mtops0
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
rtWhy "shNow" = "streams a command live and re-runs on every retry (transactional: shq)"
rtWhy "readLineNow" = "reads stdin now and re-reads on retry (transactional: input)"
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
