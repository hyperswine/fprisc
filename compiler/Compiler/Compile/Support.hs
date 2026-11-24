{-# LANGUAGE LambdaCase, TupleSections, ScopedTypeVariables, EmptyCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Compiler.Compile.Support -- self-contained helpers of the native
-- compile driver: module dedup, parsing entry points, small syntax probes,
-- the timing wrapper, the privileged-builtin policy tables and the
-- view-purity checks. Nothing here touches the compile pipeline's
-- orchestration (Compile.compileWithArguments/compileWithReport); these
-- are the leaves it calls.
module Compiler.Compile.Support
  ( dedupeUnits, symbolize, parseFile, parseFileSrc, parseFileSrcEditor,
    arities, isMain, bindNames, phaseTime,
    fst3, writeWhole, nativeSummary, posixPic,
    privilegedBuiltins, privilegedBuiltinModules, canonicalPathOr,
    privilegedModulePaths, privilegedMentions, impureViewPrimitives,
    viewPurityErrors,
  ) where

import Compiler.Editor (Report)
import Struct
import Core.Syntax
import FPRISC (program)
import Text.Megaparsec (parse)
import Text.Megaparsec (errorBundlePretty, parse)
import Data.List (isPrefixOf, isSuffixOf, isInfixOf)
import qualified Data.Map.Strict as M
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Set as S
import Control.Monad (unless, when)
import Data.IORef
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (takeExtension, takeDirectory, (</>))
import System.Process (readProcess)
import Text.Printf (printf)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Frontend.Syntax (STop (..))
import Core.Syntax (Name)
import Data.List (sortBy)
import Data.Maybe (fromMaybe,isJust)
import System.IO (hClose, hPutStr, hPutStrLn, openTempFile, stderr)
import Core.Opt.Representation (eraseLayoutCasts)
import Arc (lowerArcWithProductEvidence, lowerRawWithProductEvidence, arcExterns, arcRev)
import qualified Compiler.Native.Representation as NativeRep
import Core.Typed.Callback (CallbackMode(..))
import qualified Compiler.Native.Exports as Exports
import Codegen.Export.Plan (FloatABI(..))
import Codegen.Target.RV.Export (renderAdapter,adapterStack,adapterHeap)
import qualified Codegen.Stack as Stack
import qualified Codegen.Heap as Heap
import Codegen.Selected (CodeSymbol(..))
import qualified Compiler.Native.Core as NativeCore
import qualified Compiler.Native.Linked as Linked
import qualified Compiler.Native.Imports as NativeImports
import Compiler.DataLayout (Layouts(..), i64StoreAt)
import Mono (specializeCompatibilityWithProducts, qualifyAux)
import Inline (inlineSmall, inlineCompatibilityWithImports, vecPeekCompatibility)
import qualified Compiler.Native.Regions as Regions
import qualified Compiler.Native.Regions.Typed as TypedRegions
import qualified Compiler.Native.TypedLowering as TypedLowering
import qualified Core.Typed.Syntax as TCore
import qualified Core.VectorRead as VectorRead
import qualified Codegen.Target.RV as RV
import qualified Codegen as Backend (tgtW)
import Codegen.Target.Common (Tune (..), dataSyntax, functionSymbol)
import Codegen (codegenRev, productBackendWidth, emitTypedProductProgramWithImports, TypedUse (..), Emission (..), NativeMode (..), NativeBackend (..), externals, tgtName, tgtFuel, tgtArc, tgtWeak, tgtHeapProof, tgtStackReport, tgtHal, tgtFloatInline, tgtSimd, tgtFusion, tgtScalarFast, tgtIndexedMemory, tgtScalarWorkers, tgtPairReturns, tgtFieldWorkers, tgtTupleScalars, tgtPipelineInline, tgtReuse, tgtSpineBuilders, tgtMapBodies, tgtPoolResetters, tgtTypedIr, tgtPolicy, tgtNative, foreignEntries, normalizesLiterals)
import Codegen.Policy (Policy (..), Profile (..), StackPolicy (..), policyWidth, registerBudget)
import Codegen.Target.X64 (x64InterfaceRev, x64SelectionRev)
import Codegen.Target.A64 (ObjectFormat (..), HartAccess (..), a64HostedInterfaceRev, a64InterfaceRev, a64SelectionRev)
import Data.Char (ord)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Control.Monad (forM, forM_, unless, when)
import Data.List (intercalate, isPrefixOf)
import qualified Data.List as List
import qualified Data.Map.Strict as M
import qualified Data.Map.Lazy as ML
import qualified Core.Alpha as Alpha
import qualified Data.Set as S
import Core.Syntax
import Reuse (poolResetters,spineBuilders,mapBodiesOf)
import Core.Opt.ProductParameters (withImportedVariantResults, withoutVariantResults)
import Core.CacheIdentity (CallArities(..),coreCacheIdentityWithBuilders)
import qualified Compiler.Options as Options
import Compiler.CommandLine
import Core.Identity (Namespace(..))
import Frontend.Syntax
import Frontend.Parser (program)
import Frontend.Desugar
import Frontend.OwnedMapFold (ownedMapFolds)
import Frontend.KeyedListFold (keyedListFolds)
import Frontend.ListRewrites (sharedMaps, snocFolds)
import Frontend.Paths
import Frontend.Linearity
import Frontend.Traverse
import Frontend.Normalize
import Frontend.Diagnostics
import qualified Diagnostic.Render as Diagnostic
import qualified Compiler.Editor as Editor
import qualified Compiler.CallableReport as CallableReport
import qualified Source.Span as Source
import qualified Data.List.NonEmpty as NE
import qualified Diagnostic.Remark as Remark
import qualified Compiler.Remarks as Remarks
import Core.Opt.Normalize (normArc)
import Type.Syntax (Scheme(..), Type(..))
import Infer.Result
import Frontend.Desugar.Typed (prepareChecked,selectCheckedUnit,checkedCallArities,specializeCheckedSource,specializedTops,checkedTransportCatalog,selectUnit,selectSpecialized)
import Infer (inferTopsChecked, aotProf, builtinEnv, builtinLinShapes, canonicalTypeWith)
import Safety (measureCheck, checkSafety, safetyDiagnostics, safetySuggestions, trustedLibraryPaths)
import qualified Cost
import qualified Resource.Analysis as Resource
import Manifest (Manifest (..), readManifest, renderNs)
import Struct (expandStructs, sigTable, structTable)
import Modules (LoadResult (..), ModExport (..), hashAST, loadProgram)
import qualified Precond
import Precond (PreNote (..), PreStatus (..), applyPreconds, checkedName, preTable, renderNote, validatePre, validatePreUses)
import Home (fprHome, underHome)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, renameFile)
import System.Environment (getArgs, lookupEnv)
import StdBridge (runStdCheck)
import System.Exit (exitFailure, exitSuccess)
import Control.Exception (SomeException, evaluate, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Clock (getMonotonicTimeNSec)
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Text.Megaparsec (errorBundlePretty, parse, bundleErrors, errorOffset)
import Text.Printf (printf)

-- compiled once (the cache) and linked twice (duplicate symbols, 2026-10-02).
dedupeUnits :: [(String, b)] -> [(String, b)]
dedupeUnits = go S.empty
  where
    go _ [] = []
    go seen ((h, u) : r)
      | S.member h seen = go seen r
      | otherwise = (h, u) : go (S.insert h seen) r

-- `Addr.symbol "name"` -> CVar "$sym.name": the address of a linker symbol,
-- the builtin profile's `extern char name[]`.  Rewritten on lifted Core
-- before ownership lowering; Representation types it 'a', Arc passes it
-- through unowned, Codegen emits one `la`.  A non-literal argument is a
-- compile error: the name IS the link, there is nothing to compute.
symbolize :: Prog -> Either String Prog
symbolize = traverse (\(ps, b) -> (,) ps <$> go b)
  where
    go e = case e of
      CApp (CVar "Addr.symbol") (CStr s) -> Right (CVar ("$sym." ++ s))
      CApp (CVar "Addr.symbol") _ -> Left "Addr.symbol takes a string literal naming a linker symbol"
      CVar "Addr.symbol" -> Left "Addr.symbol is not a function value: apply it to a string literal"
      CApp f a -> CApp <$> go f <*> go a
      CLam ps b -> CLam ps <$> go b
      CLet n a b -> CLet n <$> go a <*> go b
      CIf c t f -> CIf <$> go c <*> go t <*> go f
      CMk t v fs -> CMk t v <$> traverse go fs
      CTagEq t v x -> CTagEq t v <$> go x
      CProj i x -> CProj i <$> go x
      _ -> Right e

parseFile :: FilePath -> IO [STop]
parseFile p = snd <$> parseFileSrc p

-- keep the source: bindAnchors scans it for the file:line of every
-- top-level definition (spans step 1)
parseFileSrc :: FilePath -> IO (String, [STop])
parseFileSrc = parseFileSrcEditor Editor.disabled

parseFileSrcEditor :: Editor.Report -> FilePath -> IO (String, [STop])
parseFileSrcEditor report p = do
  bytes <- BS.readFile p
  -- a source file is UTF-8 text; a byte order mark is skipped (an editor
  -- wrote it, it is not a character) and a byte that is not UTF-8 is
  -- refused by name, not reported as a decoding exception or a parse error
  let body = fromMaybe bytes (BS.stripPrefix (BS.pack [0xEF, 0xBB, 0xBF]) bytes)
  src <- case TE.decodeUtf8' body of
    Right t -> pure (T.unpack t)
    Left _ -> do
      let bad = length (takeWhile id (zipWith (==) (BS.unpack body) (BS.unpack (TE.encodeUtf8 (TE.decodeUtf8With TEE.lenientDecode body)))))
      hPutStrLn stderr ("error: " ++ p ++ ": byte " ++ show bad ++ " is not UTF-8 (a source file is UTF-8 text)")
      exitFailure
  Editor.source report p src
  case parse program p src of
    Left e -> do
      Editor.problem report "parse" (errorBundlePretty e) (Just (Source.pointSpan p (Source.SourceOffset (errorOffset (NE.head (bundleErrors e))))))
      putStrLn (errorBundlePretty e) >> exitFailure >> pure (src, [])
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

phaseTime :: Bool -> String -> IO a -> IO a
phaseTime False _ action = action
phaseTime True name action = do
  start <- getMonotonicTimeNSec
  result <- action
  end <- getMonotonicTimeNSec
  hPutStrLn stderr (printf "[fpr timing] %s: %.3f ms" name (fromIntegral (end - start) / 1e6 :: Double))
  pure result
fst3 :: STop -> String
fst3 (TBind n _ _ _) = n
fst3 _ = ""

-- a cache file appears whole: written to a temp name in its directory, renamed
writeWhole :: FilePath -> String -> IO ()
writeWhole path text = do
  (tmp, h) <- openTempFile (takeDirectory path) (takeFileName path ++ ".tmp")
  hPutStr h text
  hClose h
  renameFile tmp path

-- Target instruction distances between safepoints. This is not an elapsed
-- time certificate or a bound on the bodies of runtime calls.
nativeSummary :: Bool -> String -> String -> IO ()
nativeSummary enabled what asm =
  when enabled $ do
    let label = "# native-insns-v1: "
        rows = [drop (length label) l | l <- lines asm,label `isPrefixOf` l]
        parse r = case words r of
          fn:kvs -> (fn,[(takeWhile (/= '=') kv,drop 1 (dropWhile (/= '=') kv)) | kv <- kvs])
          [] -> ("?",[])
        distance (_,kvs) = maybe (0::Int) (\v -> if v=="UNBOUNDED" then maxBound else read v) (lookup "segmax" kvs)
        parsed = map parse rows
        top = take 12 (sortBy (\a b -> compare (distance b) (distance a)) parsed)
    unless (null parsed) $ do
      hPutStrLn stderr ("[native-insns-v1] "++what++": "++show (length parsed)++" function(s), max segment "++show (maximum (map distance parsed))++" target instructions between safepoints")
      mapM_ (\(fn,kvs) -> hPutStrLn stderr ("[native-insns-v1]   "++fn++"  segmax="++maybe "?" id (lookup "segmax" kvs)++"  exittail="++maybe "?" id (lookup "exittail" kvs)++"  ccalls="++maybe "?" id (lookup "ccalls" kvs))) top


-- Shared host modules resolve externally visible addresses through the GOT.
-- Local labels keep direct PC-relative addresses. x64 borrows main's static
-- TLS through the initial-exec model, never a module-local TLS block.
posixPic :: Bool -> Bool -> String -> String
posixPic a64 mach asm = unlines (go (lines asm))
  where
    locals = S.fromList [init l | l <- lines asm, not (null l), last l == ':']
    external n = not (S.member n locals)
    go [] = []
    go (l:rest)
      | a64, ["adrp", reg, sym] <- words l, external (takeWhile (/= '@') sym),
        next:tail' <- rest, "add " `isPrefixOf` dropWhile (== ' ') next =
          let r = filter (/= ',') reg; n = takeWhile (/= '@') sym
          in (if mach then ["    adrp " ++ r ++ ", " ++ n ++ "@GOTPAGE", "    ldr " ++ r ++ ", [" ++ r ++ ", " ++ n ++ "@GOTPAGEOFF]"]
                      else ["    adrp " ++ r ++ ", :got:" ++ n, "    ldr " ++ r ++ ", [" ++ r ++ ", :got_lo12:" ++ n ++ "]"]) ++ go tail'
      | not a64, ["leaq", src, dst] <- words l,
        let n = takeWhile (/= '(') src, "(%rip)," `List.isSuffixOf` src, external n =
          ("    movq " ++ n ++ "@GOTPCREL(%rip), " ++ dst) : go rest
      | not a64, "%fs:" `List.isInfixOf` l, "@tpoff" `List.isInfixOf` l =
          let ws = words l; args = takeWhile (/= "#") (drop 1 ws)
              n = case [w | w <- args, "%fs:" `isPrefixOf` w] of
                    (w : _) -> takeWhile (/= '@') (drop 4 w)
                    [] -> ""
              scratch = if "%r11" `List.isInfixOf` l then "%r10" else "%r11"
              old = "%fs:" ++ n ++ "@tpoff"
              replace [] = []
              replace xs@(c : cs)
                | old `isPrefixOf` xs = "%fs:(" ++ scratch ++ ")" ++ replace (drop (length old) xs)
                | otherwise = c : replace cs
          in ["    pushq " ++ scratch, "    movq " ++ n ++ "@GOTTPOFF(%rip), " ++ scratch, replace l, "    popq " ++ scratch] ++ go rest
      | not mach, dropWhile (== ' ') l == ".section .rodata" = ".section .data.rel.ro" : go rest
      | otherwise = l : go rest

-- ---- privileged builtins ---------------------------------------------------
-- Builtins whose types the checker cannot make safe (field-number cell
-- access), and the std modules allowed to name them.  Kept here rather than in
-- Safety.hs: tests/sol-checks/trust.sol reads every quoted std path in that
-- file as a safety allow-list entry.
privilegedBuiltins :: [Name]
privilegedBuiltins = ["nodeGet", "nodeWith", "nodeSet"]

privilegedBuiltinModules :: [FilePath]
privilegedBuiltinModules = ["std" </> "hashmap.fpr"]

canonicalPathOr :: FilePath -> IO FilePath
canonicalPathOr p = either (const p) id <$> (try (canonicalizePath p) :: IO (Either SomeException FilePath))

-- FPR_HOME only (not FPR_PATH): a search-path root cannot supply its own
-- std/hashmap.fpr and inherit the privilege.
privilegedModulePaths :: IO (S.Set FilePath)
privilegedModulePaths = do
  h <- fprHome
  S.fromList <$> mapM (canonicalPathOr . (h </>)) privilegedBuiltinModules

-- (defining top, builtin) for every mention of a privileged builtin in a
-- unit's tops.  Deliberately ignores local shadowing: the names are reserved,
-- so a mention anywhere (value, alias, guard, precondition, struct field,
-- top-level eval) counts.  Every constructor is listed (no wildcard), so a
-- new expression form cannot silently escape the check.
privilegedMentions :: [STop] -> [(Name, Name)]
privilegedMentions tops = List.nub (concatMap topM tops)
  where
    hit n = n `elem` privilegedBuiltins
    topM = \case
      TBind n _ gs e -> [(n, b) | b <- concatMap guardM gs ++ exprM e]
      TSig n _ pres -> [(n, b) | Just (_, e) <- pres, b <- exprM e]
      TStruct n _ fs -> [(n, b) | (_, e) <- fs, b <- exprM e]
      TAlias a b -> [(a, b) | hit b]
      TEval e -> [("main", b) | b <- exprM e]
      TType {} -> []
      TShape {} -> []
      TSigDef {} -> []
      TUse {} -> []
      TSkip -> []
    guardM = \case
      GBool e -> exprM e
      GPat _ e -> exprM e
    exprM = \case
      SVar v -> [v | hit v]
      SMark _ e -> exprM e
      SInt _ -> []
      SStrI segs -> concat [exprM e | SegExpr e <- segs]
      SApp a b -> exprM a ++ exprM b
      SLam _ e -> exprM e
      SBlock ss e -> concatMap stmtM ss ++ exprM e
      SCase x arms -> exprM x ++ concatMap (exprM . snd) arms
      SBin _ a b -> exprM a ++ exprM b
      SProj e _ -> exprM e
      SRec fs -> concatMap (exprM . snd) fs
      SUpd m as -> exprM m ++ concatMap (exprM . snd) as
      STup es -> concatMap exprM es
      SList es -> concatMap exprM es
    stmtM = \case
      SBind _ _ e -> exprM e
      SBindPat _ e -> exprM e

-- ---- Game.app view purity --------------------------------------------------
impureViewPrimitives :: S.Set Name
impureViewPrimitives = S.fromList
  [ "print", "Sys.stderr", "Sys.readLine", "Sys.env", "Sys.args", "Sys.name", "Sys.exit", "Sys.timeUs",
    "fileRead", "fileWrite", "fileAppend", "fileExists",
    "read", "write", "Mem.read8", "Mem.write8", "Mem.read16", "Mem.write16",
    "Mem.read32", "Mem.write32", "Mem.read64", "Mem.write64",
    "Mem.alloc", "Mem.realloc", "Mem.free", "Mem.atomicExchange", "Mem.compareExchange", "Mem.fence",
    "CPU.csrRead", "CPU.csrWrite", "CPU.irqSave", "CPU.irqRestore", "CPU.irqEnable", "CPU.wait", "CPU.instructionFence",
    "device", "reg8", "reg32",
    "send", "sendLinear", "sendArc", "receive", "receiveRes", "receiveNow",
    "receiveFrom", "receiveFromRes", "receiveFromNow", "receiveUntil", "receiveFromUntil",
    "spawn", "spawnCap", "spawnCapOn", "spawnOn", "spawnHeap",
    "myself", "myPid", "kill", "yield", "hartId",
    "Sys.sleepUs", "Sys.mtime", "Sys.uptimeMs", "Sys.nextId", "Sys.actLive", "Sys.actInfo", "Sys.spawnApp", "Sys.poolReset",
    "Sys.logStage", "Sys.logStaged", "Sys.logInstall", "Sys.logger",
    "Sys.irqInstall", "Sys.irqRouter", "Sys.irqOpen", "Sys.irqDeliver", "Sys.irqTarget", "Sys.irqAck",
    "Sys.timerBind", "Sys.timerArm", "Mod.fn", "Mod.detachLast", "schedSetTau"
  ]

viewPurityErrors :: S.Set Name -> S.Set Name -> [STop] -> [String]
viewPurityErrors gameApps impureNames tops
  | S.null gameApps = []
  | otherwise = List.nub (concatMap checkTop tops)
  where
    bindMap = M.fromListWith (++) [(n, [(ps, gs, e)]) | TBind n ps gs e <- tops]
    unmark (SMark _ e) = unmark e
    unmark e = e
    flattenApp e = case unmark e of
      SApp f a -> let (h, as) = flattenApp f in (h, as ++ [a])
      h -> (h, [])
    checkTop = \case
      TBind n _ gs e | S.notMember n gameApps ->
        concatMap (checkGuard n) gs ++ checkExpr n e
      TEval e -> checkExpr "main" e
      _ -> []
    checkGuard caller = \case
      GBool e -> checkExpr caller e
      GPat _ e -> checkExpr caller e
    checkExpr caller e0 =
      let here = case flattenApp e0 of
            (SVar fn, args) | S.member fn gameApps, length args >= 4 ->
              checkView caller (args !! 3)
            _ -> []
          sub = case e0 of
            SMark _ e -> checkExpr caller e
            SApp a b -> checkExpr caller a ++ checkExpr caller b
            SLam _ e -> checkExpr caller e
            SBlock ss e -> concatMap (checkStmt caller) ss ++ checkExpr caller e
            SCase x arms -> checkExpr caller x ++ concatMap (checkExpr caller . snd) arms
            SBin _ a b -> checkExpr caller a ++ checkExpr caller b
            SProj e _ -> checkExpr caller e
            SRec fs -> concatMap (checkExpr caller . snd) fs
            SUpd m as -> checkExpr caller m ++ concatMap (checkExpr caller . snd) as
            STup es -> concatMap (checkExpr caller) es
            SList es -> concatMap (checkExpr caller) es
            SStrI segs -> concat [checkExpr caller e | SegExpr e <- segs]
            _ -> []
       in here ++ sub
    checkStmt caller = \case
      SBind _ _ e -> checkExpr caller e
      SBindPat _ e -> checkExpr caller e
    checkView caller viewArg =
      let seeds = [(Nothing, r) | r <- exprRefs S.empty viewArg]
       in bfs S.empty seeds
      where
        bfs _ [] = []
        bfs seen ((via, r) : rest)
          | S.member r impureNames =
              let detail = case via of
                    Nothing -> "calls impure primitive '" ++ r ++ "'"
                    Just v -> "reaches impure primitive '" ++ r ++ "' via '" ++ v ++ "'"
               in ("in " ++ caller ++ ": Game.app view cannot perform side effects (" ++ detail ++ ")") : bfs seen rest
          | S.member r seen = bfs seen rest
          | Just cls <- M.lookup r bindMap =
              let nextVia = Just (fromMaybe r via)
                  nextRefs = [(nextVia, x) | cl <- cls, x <- clauseRefs cl]
               in bfs (S.insert r seen) (rest ++ nextRefs)
          | otherwise = bfs (S.insert r seen) rest
    clauseRefs (ps, gs, body) =
      let b0 = S.fromList (concatMap patVars ps)
          (gRefs, b1) = List.foldl' stepGuard ([], b0) gs
       in gRefs ++ exprRefs b1 body
    stepGuard (acc, bs) = \case
      GBool e -> (acc ++ exprRefs bs e, bs)
      GPat p e -> (acc ++ exprRefs bs e, bs `S.union` S.fromList (patVars p))
    exprRefs bs = \case
      SMark _ e -> exprRefs bs e
      SVar v -> [v | S.notMember v bs]
      SApp a b -> exprRefs bs a ++ exprRefs bs b
      SLam ps e -> exprRefs (bs `S.union` S.fromList ps) e
      SBlock ss e -> let (rs, bs') = stmtsRefs bs ss in rs ++ exprRefs bs' e
      SCase x arms -> exprRefs bs x ++ concat [exprRefs (bs `S.union` S.fromList (patVars p)) e | (p, e) <- arms]
      SBin op a b -> [op | S.notMember op bs] ++ exprRefs bs a ++ exprRefs bs b
      SProj e _ -> exprRefs bs e
      SRec fs -> concatMap (exprRefs bs . snd) fs
      SUpd m as -> exprRefs bs m ++ concatMap (exprRefs bs . snd) as
      STup es -> concatMap (exprRefs bs) es
      SList es -> concatMap (exprRefs bs) es
      SStrI segs -> concat [exprRefs bs e | SegExpr e <- segs]
      SInt _ -> []
    stmtsRefs bs [] = ([], bs)
    stmtsRefs bs (SBind n ps e : rest) =
      let bs1 = S.insert n bs
          rs1 = exprRefs (bs1 `S.union` S.fromList ps) e
          (rs2, bs2) = stmtsRefs bs1 rest
       in (rs1 ++ rs2, bs2)
    stmtsRefs bs (SBindPat p e : rest) =
      let rs1 = exprRefs bs e
          bs1 = bs `S.union` S.fromList (patVars p)
          (rs2, bs2) = stmtsRefs bs1 rest
       in (rs1 ++ rs2, bs2)
