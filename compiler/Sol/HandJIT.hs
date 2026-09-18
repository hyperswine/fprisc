{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

-- Sol/HandJIT.hs -- THE native JIT tier of the Sol VM: hand-rolled,
-- no LLVM, two ISAs.
--
--   typed Core  --JitCore-->  typed closure  --KIR-->  kernel IR
--              --AsmX64 / AsmA64-->  bytes  --hj_alloc-->  callable
--
-- What gets compiled (unchanged from the LLVM tier it replaces):
-- RECURSION SCHEMES ONLY -- list map / filter / foldl and the Vec duals
-- vecmap / vecfilter / vecfold / vecmapr -- whose element function is a
-- top-level supercombinator in the pure arithmetic fragment, closed
-- over other such functions (recursion allowed, fuel-counted), with
-- captured scalars as typed extras and SoA columns as typed loads.
-- Everything else is the interpreter's job, by a decline that is
-- printed under SOL_JIT_DEBUG=1.
--
-- Bit-identical by construction: i64 ops are the machine's, `/` is
-- quot, f64 ops are IEEE scalar instructions in the same order the
-- interpreter evaluates, exact ints promote on contact (sitofp), floor
-- and round are the ISA's floor / round-to-nearest-even -- the same
-- split the interpreter's `arith` makes.
--
-- Cross-checking the OTHER ISA from this host: SOL_HJIT_XCHECK=<dir>
-- makes every install also assemble the A64 (or x86-64) blob and every
-- native run dump its inputs + outputs as a case file; tools/hjrun.c
-- (under qemu-user) executes the foreign blob on those inputs and
-- compares.  tools/sol-hjit-a64-check.sh drives it.
module Sol.HandJIT
  ( JitCtx, initJIT, jitDebug,
    compileScheme, compileVecScheme, compileVecMapR,
    runMapFilter, runFold, runVecMapFilter, runVecFold, runVecMapR,
    module Sol.JitCore,
  ) where

import Control.Monad (forM_, when)
import Data.IORef
import Data.Int (Int64)
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word (Word8)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray, withArrayLen)
import Foreign.Ptr
import Foreign.Storable
import Sol.AsmA64 (assembleA64)
import Sol.AsmX64 (assembleX64)
import Sol.JitCore
import Sol.KIR
import Sol.Lang (Core (..), Name, Prog)
import System.Environment (lookupEnv)
import System.IO (IOMode (..), hPutBuf, withBinaryFile)
import System.IO.Unsafe (unsafePerformIO)
import System.Info (arch)
import Data.Time.Clock.POSIX (getPOSIXTime)

foreign import ccall unsafe "hj_alloc" c_hjAlloc :: Ptr Word8 -> Int -> IO (Ptr Word8)

foreign import ccall unsafe "hj_has_sse41" c_hjHasSse41 :: IO Int

data Arch = X64 | A64 deriving (Eq, Show)

data JitCtx = JitCtx
  { jcArch :: Arch,
    jcCache :: IORef (M.Map (String, Name) (Int64, JTy, JTy)),
    jcMapR :: IORef (M.Map (String, Name) (Int64, Int, [JTy])),
    jcCount :: IORef Int,
    jcXcheck :: Maybe FilePath,
    jcRun :: String -- per-process tag so cross-check dumps from concurrent runs never collide
  }

jitDebug :: String -> IO ()
jitDebug msg = do
  d <- lookupEnv "SOL_JIT_DEBUG"
  when (d == Just "1") (putStrLn msg)

initJIT :: IO (Maybe JitCtx)
initJIT = do
  x <- lookupEnv "SOL_HJIT_XCHECK"
  t <- getPOSIXTime
  let run = "r" ++ show (floor (t * 1000000) `mod` (1000000000 :: Integer))
      mk a = Just <$> (JitCtx a <$> newIORef M.empty <*> newIORef M.empty <*> newIORef 0 <*> pure x <*> pure run)
  case arch of
    "x86_64" -> do
      ok <- c_hjHasSse41
      if ok /= 0
        then mk X64
        else putStrLn "[jit] x86-64 without SSE4.1 (roundsd): native tier disabled, interpreting" >> pure Nothing
    "aarch64" -> mk A64
    other -> putStrLn ("[jit] no native backend for " ++ other ++ ": interpreting") >> pure Nothing

-- ---- install: assemble, map executable, remember the symbol ----------------

-- address -> (symbol, unit) for the cross-check dumps
symTable :: IORef (M.Map Int64 (String, Unit, Int))
symTable = unsafePerformIO (newIORef M.empty)
{-# NOINLINE symTable #-}

assembleFor :: Arch -> Unit -> [Word8]
assembleFor X64 = assembleX64
assembleFor A64 = assembleA64

archName :: Arch -> String
archName X64 = "x86-64"
archName A64 = "a64"

install :: JitCtx -> String -> Int -> Unit -> IO (Maybe Int64)
install jc sym nCols unit = do
  dump <- lookupEnv "SOL_HJIT_DUMP"
  when (dump == Just "1") (putStr (showUnit unit))
  let bytes = assembleFor (jcArch jc) unit
  p <- withArray bytes $ \pb -> c_hjAlloc pb (length bytes)
  let a = fromIntegral (ptrToIntPtr p)
  if a == 0
    then pure Nothing
    else do
      modifyIORef' symTable (M.insert a (sym, unit, nCols))
      forM_ (jcXcheck jc) $ \dir -> do
        let other = if jcArch jc == X64 then A64 else X64
        writeWords (dir ++ "/" ++ sym ++ "." ++ archName other ++ ".bin") (assembleFor other unit)
        writeWords (dir ++ "/" ++ sym ++ "." ++ archName (jcArch jc) ++ ".bin") bytes
      pure (Just a)
  where
    writeWords path bs = withBinaryFile path WriteMode $ \h -> withArrayLen bs $ \n pb -> hPutBuf h pb n

freshSym :: JitCtx -> IO String
freshSym jc = do
  k <- atomicModifyIORef' (jcCount jc) (\c -> (c + 1, c))
  pure (jcRun jc ++ "_t" ++ show k)

-- ---- the list tier: map / filter / foldl over unboxed lists ----------------

compileScheme :: JitCtx -> Prog -> String -> Name -> JTy -> JTy -> IO (Maybe (Int64, JTy, JTy))
compileScheme jc prog scheme root elemTy accTy0 = do
  let ckey = (scheme ++ "|" ++ [tyChar elemTy] ++ "|" ++ [tyChar accTy0], root)
  cache <- readIORef (jcCache jc)
  case M.lookup ckey cache of
    Just hit -> pure (Just hit)
    Nothing -> case fmap prepClosure (gatherFns prog root) >>= checkAll of
      Nothing -> pure Nothing
      Just closure -> do
        let Just (rootPs, _) = M.lookup root closure
            isFold = scheme == "foldl"
            stab acc n
              | n <= (0 :: Int) = Nothing
              | otherwise = do
                  let rootArgs = if isFold then [acc, elemTy] else [elemTy]
                      rootTy sigs = do
                        (ps, body) <- M.lookup root closure
                        tyExpr sigs closure (M.fromList (zip ps rootArgs)) body
                  (sigs, rt) <- inferSigs closure rootTy
                  if isFold && rt /= acc && joinT acc rt /= acc
                    then stab (joinT acc rt) (n - 1)
                    else Just (sigs, if isFold then acc else rt, rt)
        case (length rootPs == (if isFold then 2 else 1), stab accTy0 3) of
          (False, _) -> pure Nothing
          (_, Nothing) -> jitDebug ("[jit-debug] " ++ root ++ ": untypeable (JW div / bool / non-convergence)") >> pure Nothing
          (True, Just (sigs, accTy, retTy))
            | scheme == "filter" && retTy /= JI -> pure Nothing
            | retTy == JW -> jitDebug ("[jit-debug] " ++ root ++ ": JW result escapes; interpreter's job") >> pure Nothing
            | otherwise -> do
                sym <- freshSym jc
                let rootKey = (root, if isFold then [accTy, elemTy] else [elemTy])
                    sigs' = M.insert rootKey retTy sigs
                    allKeys = nub (rootKey : M.keys sigs)
                    le = LowerEnv sigs' closure (sym ++ "_") Nothing
                    fns = [lowerVariant le k (M.findWithDefault JI k sigs') | k <- allKeys]
                    unit = Unit (driverList sym scheme (mangleV (sym ++ "_") rootKey) accTy retTy : fns)
                install jc sym 0 unit >>= \case
                  Nothing -> pure Nothing
                  Just addr -> do
                    putStrLn ("[jit] compiled " ++ scheme ++ "<" ++ root ++ "> elem=" ++ [tyChar elemTy] ++ (if isFold then " acc=" ++ [tyChar accTy] else "") ++ " (typed, fuel reified, hand-rolled " ++ archName (jcArch jc) ++ ")")
                    atomicModifyIORef' (jcCache jc) (\m -> (M.insert ckey (addr, accTy, retTy) m, ()))
                    pure (Just (addr, accTy, retTy))

-- ---- the Vec tier: typed duals over SoA columns ----------------------------

compileVecScheme :: JitCtx -> Prog -> String -> Name -> Bool -> [JTy] -> String -> [JTy] -> JTy -> IO (Maybe (Int64, JTy, JTy))
compileVecScheme jc prog scheme root scalar colTys laySig exTys accTy0 = do
  let ckey = (scheme ++ "|" ++ laySig ++ "|" ++ map tyChar exTys ++ "|" ++ [tyChar accTy0], root)
  cache <- readIORef (jcCache jc)
  case M.lookup ckey cache of
    Just hit -> pure (Just hit)
    Nothing -> case fmap prepClosure (gatherFns prog root) of
      Nothing -> jitDebug ("[jit-debug] " ++ root ++ ": gather failed (call outside prog?)") >> pure Nothing
      Just closure -> do
        let ars = M.map (length . fst) closure
            Just (rootPs, rootBody) = M.lookup root closure
            helpers = M.delete root closure
            nEx = length exTys
            isFold = scheme == "vecfold"
            needed = nEx + (if isFold then 2 else 1)
            exPs = take nEx rootPs
            (accP, elemP) = case (scheme, drop nEx rootPs) of
              ("vecfold", [a, x]) -> (Just a, x)
              (_, [x]) -> (Nothing, x)
              _ -> (Nothing, "?")
            loadable = map (/= JW) colTys
            helpersOK = all (uncurry (jitOK ars)) (M.elems helpers)
            rootOK = length rootPs == needed && jitOKVec ars scalar loadable elemP (exPs ++ maybe [] pure accP) rootBody
            stab acc n
              | n <= (0 :: Int) = Nothing
              | otherwise = do
                  let env0 = M.fromList (zip exPs exTys ++ maybe [] (\a -> [(a, acc)]) accP)
                      rootTy sigs = tyExprV sigs closure scalar colTys (S.singleton elemP) env0 rootBody
                  (sigs, rt) <- inferSigs closure rootTy
                  if isFold && rt /= acc && joinT acc rt /= acc
                    then stab (joinT acc rt) (n - 1)
                    else Just (sigs, if isFold then acc else rt, rt)
        if not (helpersOK && rootOK)
          then do
            jitDebug ("[jit-debug] " ++ root ++ ": helpersOK=" ++ show helpersOK ++ " rootOK=" ++ show rootOK ++ " closure=" ++ show (M.keys closure))
            jitDebug ("[jit-debug] failing helpers: " ++ show [n | (n, (ps, b)) <- M.toList helpers, not (jitOK ars ps b)])
            pure Nothing
          else case stab accTy0 3 of
            Nothing -> jitDebug ("[jit-debug] " ++ root ++ ": untypeable (JW div / bool / non-convergence)") >> pure Nothing
            Just (sigs, accTy, retTy)
              | scheme == "vecfilter" && retTy /= JI -> pure Nothing
              | retTy == JW -> jitDebug ("[jit-debug] " ++ root ++ ": JW result escapes; interpreter's job") >> pure Nothing
              | otherwise -> do
                  sym <- freshSym jc
                  let le = LowerEnv sigs helpers (sym ++ "_") Nothing
                      fns = [lowerVariant le k (M.findWithDefault JI k sigs) | k <- nub (M.keys sigs)]
                      dualLab = sym ++ "_f"
                      dual = lowerDual le dualLab exPs exTys (fmap (,accTy) accP) elemP scalar colTys rootBody retTy
                      unit = Unit (driverVec sym scheme dualLab nEx accTy retTy : dual : fns)
                  install jc sym (length colTys) unit >>= \case
                    Nothing -> pure Nothing
                    Just addr -> do
                      putStrLn ("[jit] compiled " ++ scheme ++ "<" ++ root ++ "> over SoA layout " ++ laySig ++ (if nEx > 0 then " + " ++ show nEx ++ " captured scalar(s)" else "") ++ " (typed dual, fuel reified, hand-rolled " ++ archName (jcArch jc) ++ ")")
                      atomicModifyIORef' (jcCache jc) (\m -> (M.insert ckey (addr, accTy, retTy) m, ()))
                      pure (Just (addr, accTy, retTy))

-- record-returning map: one typed dual per field, native SoA construction
compileVecMapR :: JitCtx -> Prog -> Name -> Bool -> [JTy] -> String -> [JTy] -> IO (Maybe (Int64, Int, [JTy]))
compileVecMapR jc prog root scalar colTys laySig exTys = do
  let ckey = ("vecmapr|" ++ laySig ++ "|" ++ map tyChar exTys, root)
  cache <- readIORef (jcMapR jc)
  case M.lookup ckey cache of
    Just hit -> pure (Just hit)
    Nothing -> case fmap prepClosure (gatherFns prog root) of
      Nothing -> pure Nothing
      Just closure -> do
        let ars = M.map (length . fst) closure
            Just (rootPs, rootBody) = M.lookup root closure
            helpers = M.delete root closure
            nEx = length exTys
            loadable = map (/= JW) colTys
        case splitMkR rootBody of
          Just (lets, tid, var, fs)
            | length rootPs == nEx + 1,
              let k = length fs,
              k >= 1 && k <= 8,
              var == (if tid >= 100 then k else 0),
              exPs <- take nEx rootPs,
              elemP <- last rootPs,
              fbodies <- [foldr (\(x, v) b -> CLet x v b) f lets | f <- fs],
              all (uncurry (jitOK ars)) (M.elems helpers),
              all (jitOKVec ars scalar loadable elemP exPs) fbodies -> do
                let env0 = M.fromList (zip exPs exTys)
                    inferF fb = inferSigs closure (\sigs -> tyExprV sigs closure scalar colTys (S.singleton elemP) env0 fb)
                case mapM inferF fbodies of
                  Just rs
                    | all (\(_, t) -> t == JI || t == JD) rs -> do
                        sym <- freshSym jc
                        let ftys = map snd rs
                            sigsAll = M.unions (map fst rs)
                            le = LowerEnv sigsAll helpers (sym ++ "_") Nothing
                            fns = [lowerVariant le k (M.findWithDefault JI k sigsAll) | k <- nub (M.keys sigsAll)]
                            labs = [sym ++ "_f" ++ show j | j <- [0 .. length fs - 1]]
                            duals = [lowerDual le lab exPs exTys Nothing elemP scalar colTys fb fty | (lab, fb, fty) <- zip3 labs fbodies ftys]
                            unit = Unit (driverVecMapR sym labs nEx : duals ++ fns)
                        install jc sym (length colTys) unit >>= \case
                          Nothing -> pure Nothing
                          Just addr -> do
                            putStrLn ("[jit] compiled vecmapr<" ++ root ++ "> " ++ show (length ftys) ++ " field dual(s) over " ++ laySig ++ (if nEx > 0 then " + " ++ show nEx ++ " captured scalar(s)" else "") ++ " (native SoA construction, hand-rolled " ++ archName (jcArch jc) ++ ")")
                            let hit = (addr, tid, ftys)
                            atomicModifyIORef' (jcMapR jc) (\m -> (M.insert ckey hit m, ()))
                            pure (Just hit)
                  _ -> jitDebug ("[jit-debug] " ++ root ++ ": vecmapr fields untypeable") >> pure Nothing
          _ -> pure Nothing

-- ---- native invocation (fuel cell reconciled by the VM) --------------------
--   list map/filter: i64 drv(fuel*, in*, n, out*)      fold: (fuel*, in*, n, acc0)
--   vec  map/filter: i64 drv(fuel*, extras*, cols**, n, out*)  fold: (..., n, acc0)
--   vecmapr:         i64 drv(fuel*, extras*, cols**, n, outs**)

type Drv4 = Ptr Int64 -> Ptr Int64 -> Int64 -> Ptr Int64 -> IO Int64

type DrvF = Ptr Int64 -> Ptr Int64 -> Int64 -> Int64 -> IO Int64

type Drv5 = Ptr Int64 -> Ptr Int64 -> Ptr Int64 -> Int64 -> Ptr Int64 -> IO Int64

type DrvF5 = Ptr Int64 -> Ptr Int64 -> Ptr Int64 -> Int64 -> Int64 -> IO Int64

foreign import ccall "dynamic" mkDrv4 :: FunPtr Drv4 -> Drv4

foreign import ccall "dynamic" mkDrvF :: FunPtr DrvF -> DrvF

foreign import ccall "dynamic" mkDrv5 :: FunPtr Drv5 -> Drv5

foreign import ccall "dynamic" mkDrvF5 :: FunPtr DrvF5 -> DrvF5

fp :: Int64 -> FunPtr a
fp addr = castPtrToFunPtr (intPtrToPtr (fromIntegral addr))

runMapFilter :: Int64 -> Ptr Int64 -> [Int64] -> IO (Int64, [Int64])
runMapFilter addr pfuel xs =
  withArrayLen xs $ \n pin ->
    allocaArray (max 1 n) $ \pout -> do
      k <- mkDrv4 (fp addr) pfuel pin (fromIntegral n) pout
      out <- peekArray (fromIntegral k) pout
      xcheck addr 0 [] [xs] (fromIntegral n) 0 (k : out)
      pure (k, out)

runFold :: Int64 -> Ptr Int64 -> Int64 -> [Int64] -> IO Int64
runFold addr pfuel acc0 xs =
  withArrayLen xs $ \n pin -> do
    r <- mkDrvF (fp addr) pfuel pin (fromIntegral n) acc0
    xcheck addr 1 [] [xs] (fromIntegral n) acc0 [r]
    pure r

runVecMapFilter :: Int64 -> Ptr Int64 -> [Int64] -> Ptr (Ptr Int64) -> Int -> IO (Int64, [Int64])
runVecMapFilter addr pfuel extras cols n =
  withArrayLen (extras ++ [0]) $ \_ pex ->
    allocaArray (max 1 n) $ \pout -> do
      k <- mkDrv5 (fp addr) pfuel pex (castPtr cols) (fromIntegral n) pout
      out <- peekArray (fromIntegral k) pout
      colsIn <- colsFor addr cols n
      xcheck addr 2 extras colsIn (fromIntegral n) 0 (k : out)
      pure (k, out)

runVecFold :: Int64 -> Ptr Int64 -> [Int64] -> Ptr (Ptr Int64) -> Int -> Int64 -> IO Int64
runVecFold addr pfuel extras cols n acc0 =
  withArrayLen (extras ++ [0]) $ \_ pex -> do
    r <- mkDrvF5 (fp addr) pfuel pex (castPtr cols) (fromIntegral n) acc0
    colsIn <- colsFor addr cols n
    xcheck addr 3 extras colsIn (fromIntegral n) acc0 [r]
    pure r

runVecMapR :: Int64 -> Ptr Int64 -> [Int64] -> Ptr (Ptr Int64) -> Int -> [Ptr Int64] -> IO ()
runVecMapR addr pfuel extras cols n outs =
  withArrayLen (extras ++ [0]) $ \_ pex ->
    withArray outs $ \pouts -> do
      _ <- mkDrv5 (fp addr) pfuel pex (castPtr cols) (fromIntegral n) (castPtr pouts)
      colsIn <- colsFor addr cols n
      outVals <- mapM (peekArray n) outs
      xcheck addr 4 extras colsIn (fromIntegral n) 0 (fromIntegral (length outs) : concat outVals)

-- ---- cross-check dumps ---------------------------------------------------------
-- case file, little-endian i64 words:
--   [magic 0x484A4954, kind, n, nEx, nCols, nExp, acc0, extras.., cols (n words each).., expected..]
-- kind: 0 list map/filter (expected = k : out), 1 list fold (= [r]),
--       2 vec map/filter (= k : out), 3 vec fold (= [r]),
--       4 vecmapr (= nOuts : out columns concatenated)

xcheckDir :: IORef (Maybe FilePath)
xcheckDir = unsafePerformIO (lookupEnv "SOL_HJIT_XCHECK" >>= newIORef)
{-# NOINLINE xcheckDir #-}

caseSeq :: IORef Int
caseSeq = unsafePerformIO (newIORef 0)
{-# NOINLINE caseSeq #-}

-- the unit's column count is recorded at install time; boxed columns are
-- null pointers and dump as zeros so indices stay aligned
colsFor :: Int64 -> Ptr (Ptr Int64) -> Int -> IO [[Int64]]
colsFor addr cols n = do
  dir <- readIORef xcheckDir
  tbl <- readIORef symTable
  case (dir, M.lookup addr tbl) of
    (Just _, Just (_, _, nc)) -> do
      ps <- peekArray nc cols
      mapM (\p -> if p == nullPtr then pure (replicate n 0) else peekArray n p) ps
    _ -> pure []

xcheck :: Int64 -> Int -> [Int64] -> [[Int64]] -> Int64 -> Int64 -> [Int64] -> IO ()
xcheck addr kind extras colsIn n acc0 expected = do
  dir <- readIORef xcheckDir
  forM_ dir $ \d -> do
    tbl <- readIORef symTable
    forM_ (M.lookup addr tbl) $ \(sym, _, _) -> do
      k <- atomicModifyIORef' caseSeq (\c -> (c + 1, c))
      let ws = [0x484A4954, fromIntegral kind, n, fromIntegral (length extras), fromIntegral (length colsIn), fromIntegral (length expected), acc0]
              ++ extras ++ concat colsIn ++ expected
      withBinaryFile (d ++ "/" ++ sym ++ "." ++ show k ++ ".case") WriteMode $ \h ->
        withArrayLen ws $ \cnt p -> hPutBuf h p (cnt * 8)
