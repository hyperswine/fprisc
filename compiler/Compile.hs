module Compile (compileMain) where

import Data.List (sortBy)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Codegen (Target, codegenRev, emitProgram, externals, rv32, rv64, tgtName)
import A64 (deTlsQosAppA64, lowerA64, a64Rev)
import X64 (lowerX64, deTlsQosApp, x64Rev)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State.Strict (runState)
import Data.List (isPrefixOf)
import qualified Data.List as List
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import FPRISC
import Infer (builtinLinShapes, inferTops)
import Safety (safetyCheck)
import System.Environment (lookupEnv)
import Struct (erasePSig, expandStructs, sigTable, specialize, structTable)
import Modules (LoadResult (..), ModExport (..), hashAST, loadProgram)
import Precond (PreNote (..), PreStatus (..), applyPreconds, preTable, renderNote, validatePre)
import Home (underHome)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getArgs)
import StdBridge (runStdCheck)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Text.Megaparsec (errorBundlePretty, parse)

data Opts = Opts
  { oTarget :: Target,
    oA64 :: Bool, -- lower the rv64 emission (the shared RISC IR) to AArch64
    oA64Mac :: Bool, -- AArch64 with Mach-O syntax (macOS): _sym, @PAGE, TLV
    oX64 :: Bool, -- lower it to x86-64 (SysV) instead
    oQosApp :: Bool, -- qx64: QOS-x86_64 app image (plain-global cells, no TLS)
    oQosSingle :: Bool, -- qa64single: global hart cell for hosts without TP-relative TLS
    oPlugin :: Bool, -- emit root binds in fpr_modtab for a loadable plugin
    oRvv :: Bool,
    oStdCheck :: Bool, -- run the std proof pass (StdBridge + StdCheck) and stop
    oSol :: Bool, -- the HostedBytecode/sol VIEW of the one grammar: `>` top-level eval accepted (auto-on for .sol input)
    oPrelude :: Maybe FilePath,
    oNoSafety :: Bool,
    oFiles :: [FilePath]
  }

parseArgs :: [String] -> Opts
parseArgs = foldl step (Opts rv64 False False False False False False False False False Nothing False [])
  where
    -- profile aliases (Target.hs): the AOT profiles resolved to their
    -- default ISA for this build.  bare-metal -> rv64 (QEMU virt);
    -- qos-native -> rv64 .qa is built by tools, so the alias maps the
    -- codegen the same way; qos-portable -> qx64 (x86-64 build host).
    -- hosted-bytecode is NOT an fprc target: that profile is the sol
    -- executable (fp-risc/sol).
    step o "--profile=bare-metal" = o {oTarget = rv64}
    step o "--profile=qos-native" = o {oTarget = rv64}
    step o "--profile=qos-portable" = o {oTarget = rv64, oX64 = True, oQosApp = True}
    step o "--stdcheck" = o {oStdCheck = True}
    step o "--sol" = o {oSol = True}
    step o "--target=rv32" = o {oTarget = rv32}
    step o "--target=rv64" = o {oTarget = rv64}
    step o "--target=a64" = o {oTarget = rv64, oA64 = True} -- rv64 emission is the IR
    step o "--target=a64mac" = o {oTarget = rv64, oA64 = True, oA64Mac = True} -- same lowering, Mach-O syntax
    step o "--target=x64" = o {oTarget = rv64, oX64 = True} -- likewise
    step o "--target=qx64" = o {oTarget = rv64, oX64 = True, oQosApp = True} -- QOS-x86_64
    step o "--target=qa64" = o {oTarget = rv64, oA64 = True, oQosApp = True} -- QOS-aarch64
    step o "--target=qa64single" = o {oTarget = rv64, oA64 = True, oQosApp = True, oQosSingle = True} -- QOS-aarch64, global hart cell
    step o "--target=qa64mac" = o {oTarget = rv64, oA64 = True, oA64Mac = True, oQosApp = True} -- QOS app, Apple Silicon
    step o "--plugin" = o {oPlugin = True}
    step o "--rvv" = o {oRvv = True}
    step o a
      | "--prelude=" `isPrefixOf` a = o {oPrelude = Just (drop (length "--prelude=") a)}
      | a == "--no-safety" = o {oNoSafety = True}
      | otherwise = o {oFiles = oFiles o ++ [a]}

parseFile :: FilePath -> IO [STop]
parseFile p = snd <$> parseFileSrc p

-- keep the source: bindAnchors scans it for the file:line of every
-- top-level definition (spans step 1)
parseFileSrc :: FilePath -> IO (String, [STop])
parseFileSrc p = do
  src <- readFile p
  case parse program p src of
    Left e -> putStrLn (errorBundlePretty e) >> exitFailure >> pure (src, [])
    Right tops -> pure (src, tops)

-- top-level bind name -> arity, for the extern-known-globals map:
-- cross-unit references stay KNOWN (direct calls, 0-ary `call`,
-- fpr_obj_ value refs) because the importer parsed the dep anyway.
arities :: [STop] -> M.Map String Int
arities tops = M.fromList [(n, length ps) | TBind n ps _ _ <- tops]

isMain :: STop -> Bool
isMain (TBind "main" _ _ _) = True
isMain _ = False

bindNames :: [STop] -> S.Set String
bindNames = M.keysSet . arities

compileMain :: IO ()
compileMain = do
  setLocaleEncoding utf8
  opts <- parseArgs <$> getArgs
  -- --stdcheck: parse the single file and run the std proof pass
  -- (StdBridge lowers the checkable fragment into StdCheck's interval /
  -- measure / WCET engine); no code is generated.
  when (oStdCheck opts) $ do
    inp <- case oFiles opts of
      [i] -> pure i
      _ -> putStrLn "usage: fprc --stdcheck <in.fpr>" >> exitFailure >> pure ""
    tops <- parseFile inp
    runStdCheck tops
    exitSuccess
  (inp, out) <- case oFiles opts of
    [i, o] -> pure (i, o)
    _ -> putStrLn "usage: fprc [--profile=bare-metal|qos-native|qos-portable] [--target=rv32|rv64|a64|a64mac|x64|qx64|qa64|qa64single|qa64mac] [--plugin] [--rvv] [--stdcheck] [--prelude=FILE] <in.fpr> <out.s>" >> exitFailure >> pure ("", "")
  -- --prelude=FILE as given; no flag = the prelude beside the binary
  -- (core/prelude.fpr under Home.fprHome), so `fpr compile x.fpr x.s`
  -- means the same thing from any directory; --prelude= (empty) = none
  prelude <- case oPrelude opts of
    Just "" -> pure Nothing
    Just f -> pure (Just f)
    Nothing -> underHome ("core" </> "prelude.fpr")
  let opts' = opts {oPrelude = prelude}
  (preludeSrc, preludeTops) <- maybe (pure ("", [])) parseFileSrc prelude
  (rootSrc, rootTops0) <- parseFileSrc inp
  -- ONE grammar, profile-gated views: `>` top-level statements are the
  -- sol/HostedBytecode surface.  Outside that view they are a profile
  -- error, not a parse error -- the sentence is grammatical everywhere,
  -- it just isn't part of this profile's contract.
  let solView = oSol opts || takeExtension inp == ".sol"
      (rootTops, nEvals) = desugarEvals rootTops0
  when (nEvals > 0 && not solView) $ do
    hPutStrLn stderr ("error: " ++ show nEvals ++ " top-level `>` statement(s): the sol view of the grammar (enable with --sol, or name the file .sol)")
    exitFailure
  when (nEvals > 0 && any isMain rootTops0) $ do
    hPutStrLn stderr "error: both `main` and top-level `>` statements -- the `>` list IS main in the sol view"
    exitFailure
  lr <- loadProgram preludeTops inp rootTops
  case lr of
    Left e -> putStrLn e >> exitFailure
    Right (LoadResult tops0RL exports notes units0L root0L rootHash unitAnchors unitSources) -> do
      mapM_ putStrLn notes
      -- spans steps 1-3: every "in NAME:" diagnostic below gets the
      -- best available anchor -- a stamped statement offset, the named
      -- token's position, or NAME's definition line (root + prelude
      -- scanned here, spliced units by Modules under qualified names)
      let anchors =
            M.unions
              [ bindAnchors inp rootSrc rootTops0,
                maybe M.empty (\pp -> bindAnchors pp preludeSrc preludeTops) (oPrelude opts'),
                unitAnchors
              ]
          sources =
            M.unions
              [ M.singleton inp rootSrc,
                maybe M.empty (`M.singleton` preludeSrc) (oPrelude opts'),
                unitSources
              ]
          anchored = map (anchorMsg sources anchors)
      -- first-class paths: validate + desugar @Shape.path literals on the
      -- surface tree, first transform after load (ONE table from the
      -- merged program, so root and unit rewrites agree; the generated
      -- records then flow through every later pass like user code).
      let ptbl = shapeTyTable tops0RL
          (pathErrsM, tops0R) = expandPathLits ptbl tops0RL
          (pathErrsR, root0) = expandPathLits ptbl root0L
          unitsPR = [(h, expandPathLits ptbl uts) | (h, uts) <- units0L]
          units0 = [(h, ts) | (h, (_, ts)) <- unitsPR]
          pathErrs = List.nub (pathErrsM ++ pathErrsR ++ concat [es | (_, (es, _)) <- unitsPR])
      unless (null pathErrs) $ do
        putStrLn "=== PATH LITERALS: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored pathErrs)
        exitFailure
      -- autodrop: mechanical discharge of the drop-what-you-receive law
      -- (conservative destructure-then-dead shape; see FPRISC.autoDrop)
      let (tops0S, asNotes) = aritySpill tops0R
      mapM_ putStrLn asNotes
      let (tops0, adNotes) = autoDrop tops0S
      mapM_ putStrLn adNotes
      -- ---- ML-style modules: expand sigs/structures, typecheck (HM +
      -- rows), resolve operators by operand type, monomorphize -----------
      -- The global sig table spans units (prelude sigs are visible
      -- everywhere). Structs expand per-unit to flat `Numeric.+` globals
      -- plus a first-class record; codegen stays per-unit, cached.
      let sigs = sigTable tops0
          structs = structTable tops0
          expandU uts = snd (expandStructs sigs uts)
          preludeExpErrs = fst (expandStructs sigs preludeTops)
          preludeE = expandU preludeTops
          -- autodrop must reach the ASTs codegen actually consumes:
          -- root codegen reads finalTops (derived from tops0, already
          -- dropped above), but UNIT codegen reads units0 -- without
          -- this, the pass reports insertions the emitted units never
          -- contain (the mvutick +1 arcLive/frame leak).  root0 is
          -- transformed too so root' -- used for cons/tid tables --
          -- matches what the root emits.  Notes are dropped here:
          -- the merged pass above already printed the same lines.
          root' = expandU (fst (autoDrop (fst (aritySpill root0))))
          units = [(h, expandU (fst (autoDrop (fst (aritySpill uts))))) | (h, uts) <- units0]
          tops = expandU tops0
      unless (null preludeExpErrs) $ do
        putStrLn "=== SIG/STRUCT: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored preludeExpErrs)
        exitFailure
      -- ---- preconditions (contracts): signatures may constrain params,
      -- (n : Int | n > 0).  Discharge obligations statically from local
      -- facts (clause guards, case discrimination, own preconditions),
      -- insert blame-carrying runtime checks otherwise.  Runs BEFORE
      -- inference so inserted checks are typechecked + operator-resolved
      -- like any user code; the merged table spans units, and the pass
      -- is deterministic per-bind so unit and root rewrites agree.
      let preTab = preTable tops
          preFragErrs = validatePre preTab
      unless (null preFragErrs) $ do
        putStrLn "=== PRECONDITION: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored preFragErrs)
        exitFailure
      let (pnAll, tops') = applyPreconds preTab tops
          preludeE' = snd (applyPreconds preTab preludeE)
          root'' = snd (applyPreconds preTab root')
          units' = [(h, snd (applyPreconds preTab uts)) | (h, uts) <- units]
          rootBinds = S.fromList [fst3 b | b@TBind {} <- root']
          pnRoot = [n | n <- pnAll, S.member (pnCaller n) rootBinds]
          nDis = length [() | n <- pnAll, pnStatus n == Discharged]
          nRt = length [() | n <- pnAll, pnStatus n == RuntimeCheck]
          nTrap = length [() | n <- pnAll, pnStatus n == BuiltinTrap]
      -- per-obligation notes are telemetry, not signal: 100+ lines per
      -- compile buried the errors.  FPR_PRECOND_NOTES=1 restores them;
      -- the one-line summary below always prints.
      verbosePre <- (== Just "1") <$> lookupEnv "FPR_PRECOND_NOTES"
      when verbosePre $ mapM_ (putStrLn . renderNote) pnRoot
      unless (null pnAll) $
        putStrLn ("precond: " ++ show (length pnAll) ++ " obligations: "
                  ++ show nDis ++ " discharged, " ++ show nRt
                  ++ " runtime-checked, " ++ show nTrap ++ " builtin traps")
      -- typecheck the merged expanded program; rewritten tops carry
      -- operator sites resolved to prims / Str.+ / s.(+)
      let (terrs, notes, holes, linsigs, topsRW) = inferTops sigs structs tops'
      unless (null terrs) $ do
        putStrLn "=== TYPE ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored terrs)
        exitFailure
      -- typed holes: NAMED holes typecheck everything around them and
      -- then refuse to compile, with the inferred type -- exactly the
      -- "let it typecheck, don't let it ship" contract.  ?? holes were
      -- elaborated to runtime traps and pass through.
      let named = [(n, t) | (n, t) <- holes, not (null n)]
      unless (null named) $ do
        putStrLn "=== TYPED HOLES ==="
        mapM_ (\(n, t) -> putStrLn ("  * got into a typed hole, ?" ++ n ++ " : " ++ t)) named
        unless (null [t | (_, t) <- holes, False]) (pure ())
        exitFailure
      unless (null [() | (n, _) <- holes, null n]) $
        mapM_ (\(_, t) -> putStrLn ("note: ?? hole (runtime trap) : " ++ t)) [h | h@(n, _) <- holes, null n]
      -- the safe/unsafe line (Safety.hs): recursion and unsafe-taint
      -- must be DECLARED.  --no-safety exists for transition only.
      unless (oNoSafety opts) $ do
        let preludeNames = S.fromList [n | TBind n _ _ _ <- preludeTops]
            (serrs, ssug) = safetyCheck preludeNames tops' notes
        unless (null serrs) $ do
          putStrLn "=== SAFETY: the safe/unsafe line ==="
          mapM_ (putStrLn . ("  * " ++)) (anchored serrs)
          sug <- lookupEnv "FPR_UNSAFE_SUGGEST"
          when (sug == Just "1" && not (null ssug)) $ do
            putStrLn "-- paste-ready signatures (inferred types):"
            mapM_ (putStrLn . ("SUGGEST " ++)) ssug
          exitFailure
      -- specialize generic calls; clones land in the merged program used
      -- for whole-program analyses. Per-unit codegen re-expands + rewrites
      -- its own tops (deterministic), so operator resolution is local.
      let (specErrs, topsSpec) = specialize sigs structs topsRW
      unless (null specErrs) $ do
        putStrLn "=== SIG/STRUCT: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored specErrs)
        exitFailure
      let finalTops = erasePSig topsSpec
      -- ---- whole-program ANALYSES (cheap; codegen below is per-unit) ----
      let preludeHash = hashAST preludeTops
          -- content-addressed cons: every unit's types under ITS hash;
          -- both sides of a `use` compute the same ids from the same AST.
          consAll =
            M.unions
              ( collectCons preludeHash preludeE
                  : collectCons rootHash root'
                  : [collectCons h uts | (h, uts) <- units]
              )
          shapes = collectShapes finalTops -- structural fnv ids: globally consistent
          -- tid collision check (fnv32 is probabilistic; fail LOUDLY)
          tidDecls =
            [ (t, ownerT ++ "." ++ n)
              | (ownerT, ownerH, uts) <-
                  ("prelude", preludeHash, preludeE)
                    : ("root", rootHash, root')
                    : [(take 12 h, h, uts) | (h, uts) <- units],
              TType n _ _ _ <- uts,
              let t = tidFor ownerH n
            ]
          -- linearity shapes come from THREE sources, most-authored
          -- first (M.union is left-biased): explicit TSigs, then the
          -- INFERRED types of unannotated binds, then the builtin
          -- prims' own types (Vec.push consumes a Vector because its
          -- type says so).  Before the latter two, an unannotated
          -- function -- main included -- could double-free a Vec and
          -- compile "linearity OK": the checker only knew declared
          -- sigs, so let-bound results of Vec prims were untracked
          -- and sigless params defaulted to unrestricted.
          li0 = buildLinInfo finalTops
          li =
            li0
              { liSigs =
                  liSigs li0
                    `M.union` M.fromList linsigs
                    `M.union` builtinLinShapes (liLinTys li0)
              }
          lerrs = lcheck li finalTops
      -- real tid clash check: same tid, different qualified type name
      let byTid = M.fromListWith (++) [(t, [q]) | (t, q) <- tidDecls]
          bad = [(t, qs) | (t, qs) <- M.toList byTid, length (S.toList (S.fromList qs)) > 1]
      unless (null bad) $ do
        putStrLn "=== TYPEID COLLISION (content-addressed tid clash; rename a type) ==="
        forM_ bad $ \(t, qs) -> putStrLn ("  tid " ++ show t ++ ": " ++ unwords qs)
        exitFailure
      unless (null (liLinTys li)) $
        putStrLn ("linear types: " ++ unwords (liLinTys li))
      unless (null lerrs) $ do
        putStrLn "=== LINEARITY: ERRORS ==="
        mapM_ (putStrLn . ("  * " ++)) (anchored lerrs)
        exitFailure
      -- ---- per-unit CODEGEN (separate compilation) ----
      -- Each unit is expanded already (preludeE/units/root'). For codegen
      -- we also need operator sites resolved locally (Int prim / Str.+),
      -- which inferTops does; a unit typechecks standalone WITH the prelude
      -- in scope. Cross-unit monomorphization clones live in the ROOT
      -- (specialize ran on the whole program above); finalTops' root
      -- portion carries them.
      let resolveUnit uts =
            let (_, _, _, _, rw) = inferTops sigs structs (preludeE' ++ uts)
                bn = S.fromList ([fst3 b | b@(TBind {}) <- uts])
             in [t | t@(TBind n _ _ _) <- rw, S.member n bn]
                  ++ [t | t <- rw, not (isTBind t)]
          compileUnit uts = fst (runState (compileTop uts >>= liftFix) (DEnv 0 consAll shapes []))
          preludeExt = arities preludeE'
          unitExt = M.unions [arities uts | (_, uts) <- units']
          extFor = M.union preludeExt unitExt -- own names win via prog-first lookup
          tgt = oTarget opts
          a64 = oA64 opts
          a64mac = oA64Mac opts
          x64 = oX64 opts
          qapp = oQosApp opts
          qsingle = oQosSingle opts
          lower | a64 && qapp = deTlsQosAppA64 a64mac qsingle . lowerA64 a64mac
                | a64 = lowerA64 a64mac
                | x64 && qapp = deTlsQosApp . lowerX64
                | x64 = lowerX64
                | otherwise = id
          rvv = oRvv opts && not a64 && not x64 -- no RVV lowering in the PoCs
          spec = not x64 -- SysV callee-saved registers can't host the s6+ spec loops
          tname = if qsingle then "qa64singler" ++ show a64Rev
                  else if a64mac then "a64macr" ++ show a64Rev
                  else if a64 && qapp then "qa64r" ++ show a64Rev
                  else if a64 then "a64r" ++ show a64Rev
                  else if x64 && qapp then "qx64r" ++ show x64Rev
                  else if x64 then "x64r" ++ show x64Rev
                  else tgtName tgt
          tag = "g" ++ show codegenRev ++ "pc1-" ++ tname ++ (if rvv then "-rvv" else "")
          unitDir = takeDirectory out </> "units"
          emitUnit path exps ext uts = do
            cached <- doesFileExist path
            if cached
              then pure (path, "cached")
              else do
                let prog = compileUnit uts
                -- FORCE before the write: an `error` raised while the
                -- assembly is lazily produced must propagate, never
                -- leave an empty file the cache then serves as a valid
                -- compiled unit (the bbspi arity>8 incident)
                let (asm0, vnotes) = emitProgram tgt rvv spec [] ext exps prog
                    asm = lower asm0
                mapM_ putStrLn vnotes
                length asm `seq` writeFile path asm
                wcetSummary ("unit " ++ takeFileName path) asm
                pure (path, show (M.size prog) ++ " supercombinators")
      createDirectoryIfMissing True unitDir
      -- prelude unit (unqualified names; the always-linked stdlib unit).
      -- The prelude is self-contained, so resolve its own operators.
      let preludeResolved = let (_, _, _, _, rw) = inferTops sigs structs preludeE' in rw
      preludeOut <-
        if null preludeTops
          then pure []
          else do
            r <- emitUnit (unitDir </> ("prelude-" ++ take 12 preludeHash ++ "-" ++ tag ++ ".s"))
                          (bindNames preludeE') M.empty preludeResolved
            pure [r]
      -- dep module units (hash-qualified; filename carries the prelude
      -- hash too -- unit code depends on prelude arities -- AND a hash of
      -- the whole program's record SHAPES: a unit's row-typed projections
      -- (`st.uart`) compile to a tag chain over the shapes this program
      -- declares, so a unit compiled under one program is wrong for
      -- another with a different shape set (the uartroute/timerroute
      -- incident: a cached svc unit from a program without the field)
      let shapesHash = hashAST [TShape (concat fs) [] | fs <- M.keys shapes]
      unitOuts <- forM units' $ \(h, uts) ->
        emitUnit (unitDir </> ("u-" ++ take 12 h ++ "-p" ++ take 8 preludeHash ++ "-s" ++ take 8 shapesHash ++ "-" ++ tag ++ ".s"))
                 (bindNames uts) extFor (resolveUnit uts)
      -- the root: exports its own binds; modtab (all dep exports) lives
      -- here. Root codegen uses the FULLY specialized+resolved tops
      -- (finalTops), filtered to root's own names + any monomorphized
      -- clones (clones have no home unit; they ride with the root).
      let rootNames = S.fromList ([fst3 b | b@(TBind {}) <- root'])
          unitNames = S.fromList (concat [[fst3 b | b@(TBind {}) <- uts] | (_, uts) <- units])
          preludeNames = S.fromList (map fst3 [b | b@(TBind {}) <- preludeE, True])
          rootProgTops =
            [ t | t@(TBind n _ _ _) <- finalTops,
                  S.member n rootNames
                    || (not (S.member n unitNames) && not (S.member n preludeNames))
            ]
          rootProg = compileUnit rootProgTops
          rootExports =
            [ ModExport rootHash n n (length ps)
              | oPlugin opts,
                TBind n ps _ _ <- root'
            ]
          imageExports = exports ++ rootExports
      let (rootAsm0, rootVNotes) = emitProgram tgt rvv spec imageExports extFor (bindNames root') rootProg
          rootAsm = lower rootAsm0
      mapM_ putStrLn rootVNotes
      writeFile out rootAsm
      wcetSummary "root" rootAsm
      -- the link list: everything the root's image needs beyond out itself
      writeFile (out ++ ".units") (unlines (map fst (preludeOut ++ unitOuts)))
      -- the ABI stamp half the compiler owns: mkqa folds this into the
      -- manifest (abi = "<QOS_ABI_VERSION>.<codegenRev>"); the loader
      -- refuses a mismatch.  Same artifact discipline as .units.
      writeFile (out ++ ".abirev") (show codegenRev)
      forM_ (preludeOut ++ unitOuts) $ \(p, note) -> putStrLn ("unit " ++ p ++ " (" ++ note ++ ")")
      putStrLn ("wrote " ++ out ++ " (" ++ show (M.size rootProg) ++ " supercombinators, linearity OK)")
      when (not (null imageExports)) $
        putStrLn ("module table: " ++ show (length [e | e <- imageExports, meArity e >= 1]) ++ " remote-callable exports")
      putStrLn "assumed external symbols (the fpr_g_ HAL/runtime contract):"
      putStrLn ("  " ++ unwords (externals extFor rootProg))

fst3 :: STop -> String
fst3 (TBind n _ _ _) = n
fst3 _ = ""

isTBind :: STop -> Bool
isTBind TBind {} = True
isTBind _ = False

-- G1 (docs/FUEL-RC-ABI.md): with FPRC_WCET=1, print the per-emission
-- safepoint-distance table. The program bound is the max over ALL
-- emissions linked together (root + units), plus the C-entry bounds
-- (G2) for each counted ccall.
wcetSummary :: String -> String -> IO ()
wcetSummary what asm = do
  w <- lookupEnv "FPRC_WCET"
  case w of
    Just "1" -> do
      let rows = [drop 8 l | l <- lines asm, take 8 l == "# wcet: "]
          parse r = case words r of
            (fn : kvs) -> (fn, [(takeWhile (/= '=') kv, drop 1 (dropWhile (/= '=') kv)) | kv <- kvs])
            _ -> ("?", [])
          segOf (_, kvs) = maybe (0 :: Int) (\v -> if v == "UNBOUNDED" then maxBound else read v) (lookup "segmax" kvs)
          parsed = map parse rows
          top = take 12 (sortBy (\a b -> compare (segOf b) (segOf a)) parsed)
      hPutStrLn stderr ("[wcet] " ++ what ++ ": " ++ show (length parsed) ++ " function(s), max segment " ++ (case parsed of [] -> "0"; _ -> show (maximum (map segOf parsed))) ++ " IR insns between safepoints")
      mapM_ (\(fn, kvs) -> hPutStrLn stderr ("[wcet]   " ++ fn ++ "  segmax=" ++ maybe "?" id (lookup "segmax" kvs) ++ "  ccalls=" ++ maybe "?" id (lookup "ccalls" kvs))) top
    _ -> pure ()
