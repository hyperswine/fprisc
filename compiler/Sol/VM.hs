{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- VM.hs — the Sol VM: dumb, mechanistic register interpreter.
--
--   * one frame of slots per activation (size known at compile time)
--   * fuel decremented at EVERY function entry — the same contract the
--     FPRISC compiler + actors.c use (function entry is the guaranteed
--     safepoint; structured control flow means recursion is the only loop).
--     No scheduler in this single-actor PoC: exhaustion refills and counts,
--     which is where a scheduler hook (or actor switch) slots in later.
--   * APPLY is fpr_apply's twin: PAP accumulation until saturation
--   * HCALL is the single trap into the Haskell HAL: prims, IO, and the
--     transactional file ops from Txn.hs
--   * no heap, no GC, no ARC at VM level: values are host values; the
--     real runtime's ARC discipline is enforced upstream by linearity

module Sol.VM (module Sol.VM, module Sol.Val) where

import Sol.Bytecode
import Sol.Mod
import Sol.Val
import Sol.Web
import Data.Bits (shiftL, (.|.), (.&.))
import GHC.Float (castDoubleToWord64, castWord32ToFloat, castWord64ToDouble)
import Foreign.ForeignPtr (mallocForeignPtrArray, withForeignPtr)
import Foreign.Marshal.Array (peekArray)
import Foreign.Ptr ()
import Foreign.Storable (peek)
import qualified Sol.Gpu as Gpu
import Control.Monad (forM, forM_, when)
import Data.List (minimumBy)
import Data.Ord (comparing)
import GHC.Clock (getMonotonicTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Sol.HandJIT
import Sol.KIR (fuelPoison, fuelTrap)
import Sol.Lang (Name)
import qualified Sol.Lang as Lang
import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, threadDelay)
import qualified Control.Concurrent
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, finally, fromException, mask, try)
import qualified Data.Set as S
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IM
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek, peekElemOff, poke, pokeElemOff)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Data.IORef
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Control.Monad (unless, when)
import Control.Applicative (liftA2)
import System.IO (hFlush, hGetContents', hPutStrLn, stderr, stdin, stdout)
import Sol.Txn
import qualified Data.ByteString as BS
import qualified Data.ByteString.UTF8 as BSU

data VMEnv = VMEnv
  { vmBaseDir :: FilePath, -- the script's directory: module resolution root
    vmDataFile :: FilePath, -- <script>.soldata: the persistent msg log
    vmCons :: M.Map String (Int, Int), -- constructor name -> (tid, variant)
    vmShapes :: M.Map Int [String], -- record tid -> sorted field names (for JSON)
    vmProg :: BProg,
    vmCore :: Lang.Prog, -- Core, for the JIT front-end
    vmJit :: Maybe JitCtx, -- Nothing = JIT disabled, always interpret
    vmGpu :: Maybe Gpu.GpuCtx, -- Nothing = GPU tier off/unavailable
    vmTab :: Maybe (IORef (M.Map Name TabState)), -- Nothing = tabling off
    vmHal :: M.Map Name (Int, [Value] -> IO Value),
    vmFuel :: IORef Int,
    vmPreempts :: IORef Int,
    vmTx :: IORef TxState, -- the script transaction (run-overlap policy)
    vmActors :: ActorRuntime
  }

fuelQuantum :: Int
fuelQuantum = 2000

-- fuel check at function entry: the compiler-inserted decrement's twin.
-- In the full runtime this is where the scheduler switches actors.
fuelTick :: VMEnv -> IO ()
fuelTick env = do
  f <- readIORef (vmFuel env)
  if f <= 1
    then do
      modifyIORef' (vmPreempts env) (+ 1)
      writeIORef (vmFuel env) fuelQuantum -- scheduler hook goes here
    else writeIORef (vmFuel env) (f - 1)

-- ---- auto-tabling (TablingModel.hs, made operational) ------------------
-- The model's gate, composed at the VM's dynamic dispatch:
--   compile-time eligibility (pure arithmetic Core, self-recursion ok)
--   -> probe (hash the int args) -> hit/miss -> LRU insert/evict.
-- Plus the runtime brake the model leaves to the caller: tabling is
-- enabled OPTIMISTICALLY on first entry (recursion must memoize its own
-- subcalls to win), then DROPPED post-hoc if the measured first call
-- came in under SOL_TABLE_MIN — "right conditions" means purity AND
-- observed cost, never enthusiasm.
data TabState = TIneligible | TOn !(IORef TabT)

data TabT = TabT
  { ttMap :: !(M.Map [Int64] (Value, Int)),
    ttTick :: !Int,
    ttHits :: !Int,
    ttMiss :: !Int,
    ttEvict :: !Int
  }

tabCap :: Int
tabCap = unsafePerformIO (maybe 4096 read <$> lookupEnv "SOL_TABLE_CAP")
{-# NOINLINE tabCap #-}

tabMinUs :: Double
tabMinUs = unsafePerformIO (maybe 500 read <$> lookupEnv "SOL_TABLE_MIN")
{-# NOINLINE tabMinUs #-}

-- pure-arithmetic eligibility over the fn's Core: the ONLY effects a
-- body in this fragment can have are heat.  Self-calls allowed (that is
-- the point); calls to anything else -> ineligible, conservatively.
tabEligible :: Lang.Prog -> Name -> Bool
tabEligible prog g = case M.lookup g prog of
  Just (ps, body) -> length ps <= 4 && ok (S.fromList ps) body
  Nothing -> False
  where
    -- ops from the ONE vocabulary (Bytecode.arithOps) + the pure helpers
    pureOps = S.fromList (M.keys arithOps ++ ["imod", "mod", "and2", "or2", "not"])
    ok locals c = case c of
      Lang.CInt _ -> True
      Lang.CVar v -> S.member v pureOps || v == g || S.member v locals
      Lang.CLet n a b -> ok locals a && ok (S.insert n locals) b
      Lang.CIf a b d -> ok locals a && ok locals b && ok locals d
      Lang.CTagEq _ _ a -> ok locals a
      Lang.CApp a b -> okHead locals (spineHead c) && ok locals a && ok locals b
      _ -> False
      where
        spineHead (Lang.CApp f _) = spineHead f
        spineHead x = x
        okHead bound (Lang.CVar v) = S.member v pureOps || v == g || S.member v bound
        okHead _ _ = False

dumpTabStats :: VMEnv -> IO ()
dumpTabStats env = case vmTab env of
  Nothing -> pure ()
  Just ref -> do
    m <- readIORef ref
    mapM_
      ( \(n, st) -> case st of
          TOn tref -> do
            t <- readIORef tref
            hPutStrLn stderr ("[table] " ++ n ++ ": " ++ show (ttHits t) ++ " hits / " ++ show (ttMiss t) ++ " misses / " ++ show (ttEvict t) ++ " evict (" ++ show (M.size (ttMap t)) ++ " cached)")
          TIneligible -> pure ()
      )
      (M.toList m)

execFn :: VMEnv -> Name -> [Value] -> IO Value
execFn env name args = case vmTab env of
  Nothing -> execFnRaw env name args
  Just ref -> do
    sts <- readIORef ref
    case M.lookup name sts of
      Just TIneligible -> execFnRaw env name args
      Just (TOn tref) -> probe tref
      Nothing ->
        if tabEligible (vmCore env) name
          then do
            tref <- newIORef (TabT M.empty 0 0 0 0)
            modifyIORef' ref (M.insert name (TOn tref))
            t0 <- getMonotonicTime
            v <- execFn env name args -- reenter THROUGH the table: recursion memoizes
            t1 <- getMonotonicTime
            t <- readIORef tref
            -- post-hoc brake: drop the table when the first call was BOTH
            -- fast AND shallow.  A recursive call that generated many
            -- probes is already earning its table (the memoized time is
            -- not the counterfactual time); a cheap non-recursive helper
            -- is pure overhead — drop it and stop probing forever.
            when ((t1 - t0) * 1e6 < tabMinUs && ttHits t + ttMiss t < 8) $ do
              modifyIORef' ref (M.insert name TIneligible)
              hPutStrLn stderr ("[table] " ++ name ++ ": dropped (first call " ++ show (round ((t1 - t0) * 1e6) :: Int) ++ "us, " ++ show (ttHits t + ttMiss t) ++ " probes — below SOL_TABLE_MIN)")
            pure v
          else do
            modifyIORef' ref (M.insert name TIneligible)
            execFnRaw env name args
  where
    probe tref
      | Just key <- mapM asI args = do
          t <- readIORef tref
          case M.lookup key (ttMap t) of
            Just (v, _) -> do
              writeIORef tref t {ttHits = ttHits t + 1, ttTick = ttTick t + 1, ttMap = M.insert key (v, ttTick t) (ttMap t)}
              pure v
            Nothing -> do
              v <- execFnRaw env name args
              t' <- readIORef tref
              let (m1, ev) =
                    if M.size (ttMap t') >= tabCap
                      then let lruK = fst (minimumBy (comparing (snd . snd)) (M.toList (ttMap t'))) in (M.delete lruK (ttMap t'), 1)
                      else (ttMap t', 0)
              writeIORef tref t' {ttMiss = ttMiss t' + 1, ttEvict = ttEvict t' + ev, ttTick = ttTick t' + 1, ttMap = M.insert key (v, ttTick t') m1}
              pure v
      | otherwise = execFnRaw env name args
    asI (VInt i) = Just (fromIntegral i :: Int64)
    asI _ = Nothing

execFnRaw :: VMEnv -> Name -> [Value] -> IO Value
execFnRaw env name args = do
  fuelTick env
  case M.lookup name (vmProg env) of
    Nothing -> vmPanic ("no such function: " ++ name)
    Just (Fn ar slots code) -> do
      if length args /= ar
        then vmPanic ("call " ++ name ++ ": arity mismatch")
        else do
          frame <- newIORef (M.fromList (zip [0 ..] args) :: M.Map Reg Value)
          let codeArr = code
          runLoop env frame codeArr 0

vmPanic :: String -> IO a
vmPanic m = ioError (userError ("*** SOL PANIC: " ++ m ++ " ***"))

runLoop :: VMEnv -> IORef (M.Map Reg Value) -> [Instr] -> Int -> IO Value
runLoop env frame code = go
  where
    fetch pc = case drop pc code of
      (i : _) -> i
      [] -> error "pc out of range"
    rd r = do
      m <- readIORef frame
      case M.lookup r m of
        Just v -> pure v
        Nothing -> vmPanic ("read of unwritten slot r" ++ show r)
    wr r v = modifyIORef' frame (M.insert r v)

    go pc = case fetch pc of
      LoadI r i -> wr r (VInt i) >> go (pc + 1)
      LoadS r s -> wr r (VStr s) >> go (pc + 1)
      Move d s -> rd s >>= wr d >> go (pc + 1)
      Arith2 op d a b -> do
        va <- rd a
        vb <- rd b
        wr d =<< arith op va vb
        go (pc + 1)
      Jmp l -> go l
      Jz r l ->
        rd r >>= \case
          VData t v _ | t == boolT -> if v == 0 then go l else go (pc + 1)
          other -> vmPanic ("JZ: non-bool " ++ show other)
      LabelI {} -> go (pc + 1)
      Call d g as -> do
        vs <- mapM rd as
        wr d =<< execFn env g vs
        go (pc + 1)
      HCall d g as -> do
        vs <- mapM rd as
        wr d =<< halCall env g vs
        go (pc + 1)
      MkPap d g -> do
        ar <- arityOf env g
        wr d (VPap g [] ar)
        go (pc + 1)
      Apply d f a -> do
        vf <- rd f
        va <- rd a
        wr d =<< apply env vf va
        go (pc + 1)
      Mk d t v fs -> do
        vs <- mapM rd fs
        wr d (VData t v vs)
        go (pc + 1)
      TagEq d t v s ->
        rd s >>= \case
          VData t' v' _ -> wr d (vBool (t == t' && v == v')) >> go (pc + 1)
          _ -> wr d vFalse >> go (pc + 1)
      Proj d i s ->
        rd s >>= \case
          VData _ _ fs | i < length fs -> wr d (fs !! i) >> go (pc + 1)
          other -> vmPanic ("PROJ: bad value " ++ show other)
      Ret r -> rd r
      ErrI m -> vmPanic m

arityOf :: VMEnv -> Name -> IO Int
arityOf env g = case M.lookup g (vmProg env) of
  Just fn -> pure (fnArity fn)
  Nothing -> case M.lookup g builtinArities of
    Just ar -> pure ar
    Nothing -> case M.lookup g (vmHal env) of
      Just (ar, _) -> pure ar
      Nothing
        | M.member g arithOps -> pure 2
        | otherwise -> vmPanic ("unknown symbol: " ++ g)

-- fpr_apply's twin: accumulate into a PAP; call at saturation
apply :: VMEnv -> Value -> Value -> IO Value
apply env (VPap g as 1) a = callSym env g (reverse (a : as))
apply _ (VPap g as n) a = pure (VPap g (a : as) (n - 1))
apply _ v _ = vmPanic ("APPLY: not a function: " ++ show v)

callSym :: VMEnv -> Name -> [Value] -> IO Value
callSym env g args
  | M.member g (vmProg env) = execFn env g args
  | M.member g builtinArities = builtinCall env g args
  | Just op <- M.lookup g arithOps, [a, b] <- args = arith op a b
  | Just (_, f) <- M.lookup g (vmHal env) = f args
  | otherwise = vmPanic ("call to unknown symbol: " ++ g)

-- The BStr ref table, process-global.
--
-- BStr values are `VData bstrT 0 [VInt key]` at the Sol level -- the same
-- bridge Handle uses, because an IORef cannot live in a VData field. The
-- table maps keys to buffers. It is global rather than threaded because
-- `arith` (where == lands) is reached from the VM loop without the HAL
-- environment in scope, and the table has exactly one instance per process
-- anyway.
{-# NOINLINE globalBst #-}
globalBst :: BStrTable
globalBst = unsafePerformIO (newIORef IM.empty)

arith :: ArithOp -> Value -> Value -> IO Value
arith op (VInt a) (VInt b) = case op of
  OAdd -> pure (VInt (a + b))
  OSub -> pure (VInt (a - b))
  OMul -> pure (VInt (a * b))
  -- `quot` (truncate toward zero): matches x86 idiv, A64 sdiv, C, and RISC-V DIV —
  -- the interpreter follows the hardware, not Haskell's flooring div
  ODiv -> if b == 0 then vmPanic "division by zero" else pure (VInt (a `quot` b))
  OLt -> pure (vBool (a < b))
  OLe -> pure (vBool (a <= b))
  OGt -> pure (vBool (a > b))
  OGe -> pure (vBool (a >= b))
  OEq -> pure (vBool (a == b))
  ONe -> pure (vBool (a /= b))
arith OEq a b = vBool <$> veqIO globalBst a b
arith ONe a b = fmap (vBool . not) (veqIO globalBst a b)
-- Numeric contagion: an inexact operand lifts the whole operation. Int/Int
-- stays quot (above); any VNum in the pair means true real arithmetic.
arith op (VNum a) (VNum b) = arithN op a b
arith op (VNum a) (VInt b) = arithN op a (fromIntegral b)
arith op (VInt a) (VNum b) = arithN op (fromIntegral a) b
arith op a b = vmPanic ("arith " ++ show op ++ ": bad operands " ++ show (a, b))

arithN :: ArithOp -> Double -> Double -> IO Value
arithN op a b = case op of
  OAdd -> pure (VNum (a + b))
  OSub -> pure (VNum (a - b))
  OMul -> pure (VNum (a * b))
  ODiv -> if b == 0 then vmPanic "division by zero" else pure (VNum (a / b))
  OLt -> pure (vBool (a < b))
  OLe -> pure (vBool (a <= b))
  OGt -> pure (vBool (a > b))
  OGe -> pure (vBool (a >= b))
  OEq -> pure (vBool (a == b))
  ONe -> pure (vBool (a /= b))

halCall :: VMEnv -> Name -> [Value] -> IO Value
halCall env g args
  | M.member g builtinArities = builtinCall env g args
  | otherwise = case M.lookup g (vmHal env) of
      Just (ar, f)
        | length args == ar -> f args
        | otherwise -> vmPanic ("HCALL " ++ g ++ ": arity mismatch")
      Nothing -> vmPanic ("HCALL: unknown HAL symbol " ++ g)

builtinArities :: M.Map Name Int
builtinArities =
  M.union schemeArities $
    M.fromList
      [ ("myself", 1), ("spawn", 1), ("send", 2), ("sendLinear", 2), ("sendArc", 2), ("receive", 1), ("receiveFrom", 2),
        ("spawnCap", 3), ("spawnCapOn", 4), ("spawnOn", 2), ("Sys.spawnApp", 1), ("timeNow", 1),
        ("kill", 1), ("yield", 1), ("drop", 1), ("keep", 1), ("device", 1), ("reg32", 2),
        ("Sys.poolReset", 1), ("Sys.sleepUs", 1), ("Sys.logAt", 2), ("Sys.memStats", 1), ("Sys.memInfo", 1),
        ("use", 1), ("run", 2), ("View.serve", 5),
        ("Vec.new", 1), ("Vec.range", 2), ("Vec.mmul", 5), ("Vec.push", 2), ("Vec.len", 1), ("Vec.get", 2),
        ("Vec.set", 3), ("Vec.map", 2), ("Vec.filter", 2), ("Vec.fold", 3),
        ("Vec.toList", 1), ("Vec.fromList", 1), ("Vec.free", 1),
        ("Vec.zipAdd", 2), ("Vec.zipSub", 2), ("Vec.zipMul", 2), ("Vec.dot", 2), ("Vec.scale", 2)
      ]

builtinCall :: VMEnv -> Name -> [Value] -> IO Value
builtinCall env g args
  | M.member g schemeArities = schemeCall env g args
  | g == "use" || g == "run" = modCall env g args
  | g == "View.serve" = viewServe env args
  | S.member g actorNames = actorCall env g args
  | otherwise = vecCall env g args

-- ---- gen_view: the MVU web behavior (Web.hs owns the transport) -------------
viewServe :: VMEnv -> [Value] -> IO Value
viewServe env [VInt port, fi, fu, fv, subsV] =
  serveWeb
    (fromIntegral port)
    (vmDataFile env)
    (vmShapes env)
    (vmCons env)
    [(fromIntegral ms, ev) | VData 4 0 [VInt ms, VStr ev] <- listItemsV subsV]
    Callbacks
      { cbInit = apply env fi,
        cbUpdate = \msg mdl -> apply env fu msg >>= \p -> apply env p mdl,
        cbView = apply env fv
      }
viewServe _ _ = vmPanic "View.serve: expected port init update view subs"

-- ---- the actor shim (the sketch tier; docs/PATHS.md phase 1) ---------------
--
-- QOS actor programs -- std/mvu apps included -- run INTERPRETED here on
-- green threads: spawn forks a GHC thread, an actor id is a plain Int
-- (exactly what typed FPR code stores in models and compares to 0), and
-- each mailbox is a lock+queue in arrival order with per-sender selective
-- receive -- the same visible semantics as actors.c (per-sender FIFO,
-- receiveFrom scans only that sender's messages), minus everything the
-- sketch tier does not owe: no deep copy (values are immutable here), no
-- WCET, no harts.  drop/keep are no-ops (ARC is the native runtime's);
-- Sys.poolReset/memStats are honest zeros; device/reg32 hand out an
-- mtime handle that `read` answers in the native 10MHz tick unit, so
-- MVU frame pacing works on wall clock.
--
-- Wakeup protocol: senders enqueue THEN tryPutMVar the signal, receivers
-- re-scan after every takeMVar -- a message can never be missed, only
-- signalled twice (harmless: the re-scan finds nothing and blocks again).
--
-- A panic inside a spawned actor prints the SOL PANIC line (qos.py fails
-- the run on it) and kills that actor only, like a crashed process; the
-- main thread keeps its own result path.

data ABox = ABox
  { abQ :: MVar [(Int, Value)],
    abSig :: MVar (),
    abTid :: IORef (Maybe ThreadId),
    abDone :: MVar ()
  }

data ActorRuntime = ActorRuntime
  { arReg :: IORef (IM.IntMap ABox),
    arByTid :: IORef (M.Map ThreadId Int),
    arNext :: IORef Int
  }

newActorRuntime :: IO ActorRuntime
newActorRuntime = ActorRuntime <$> newIORef IM.empty <*> newIORef M.empty <*> newIORef 1

newBox :: ActorRuntime -> IO (Int, ABox)
newBox actors = do
  i <- atomicModifyIORef' (arNext actors) (\n -> (n + 1, n))
  q <- newMVar []
  s <- newEmptyMVar
  t <- newIORef Nothing
  done <- newEmptyMVar
  let b = ABox q s t done
  atomicModifyIORef' (arReg actors) (\m -> (IM.insert i b m, ()))
  pure (i, b)

-- the calling thread's actor id, registered on first contact (the main
-- interpreter thread becomes actor 1 the first time it touches the surface)
actorSelf :: ActorRuntime -> IO Int
actorSelf actors = do
  t <- myThreadId
  m <- readIORef (arByTid actors)
  case M.lookup t m of
    Just i -> pure i
    Nothing -> do
      (i, b) <- newBox actors
      writeIORef (abTid b) (Just t)
      atomicModifyIORef' (arByTid actors) (\mm -> (M.insert t i mm, ()))
      pure i

-- spawned actors still running (their box has a thread that is not the
-- asking thread; finished actors deregister themselves). The commit
-- checkpoint asks so it can say, loudly, that effects those actors
-- produce from here land in a dead transaction.
liveSpawnedActors :: ActorRuntime -> IO [Int]
liveSpawnedActors actors = do
  me <- myThreadId
  reg <- readIORef (arReg actors)
  fmap concat . forM (IM.toList reg) $ \(i, b) -> do
    mt <- readIORef (abTid b)
    pure [i | mt /= Just me]

shutdownActorRuntime :: ActorRuntime -> IO ()
shutdownActorRuntime actors = do
  me <- myThreadId
  reg <- readIORef (arReg actors)
  spawned <- fmap concat . forM (IM.elems reg) $ \b -> do
    mt <- readIORef (abTid b)
    pure [(tid, abDone b) | Just tid <- [mt], tid /= me]
  forM_ spawned (killThread . fst)
  forM_ spawned (takeMVar . snd)
  writeIORef (arReg actors) IM.empty
  writeIORef (arByTid actors) M.empty

actorEnqueue :: ActorRuntime -> Int -> Int -> Value -> IO ()
actorEnqueue actors to from m = do
  reg <- readIORef (arReg actors)
  case IM.lookup to reg of
    Nothing -> pure () -- dead (or never-born) target: the message is lost
    Just b -> do
      modifyMVar_ (abQ b) (\q -> pure (q ++ [(from, m)]))
      _ <- tryPutMVar (abSig b) ()
      pure ()

actorTake :: ActorRuntime -> (Int -> Bool) -> IO Value
actorTake actors wants = do
  i <- actorSelf actors
  reg <- readIORef (arReg actors)
  case IM.lookup i reg of
    Nothing -> vmPanic "receive: the current actor has no mailbox"
    Just b -> loop b
  where
    loop b = do
      r <- modifyMVar (abQ b) $ \q ->
        case break (\(s, _) -> wants s) q of
          (pre, (_, m) : post) -> pure (pre ++ post, Just m)
          _ -> pure (q, Nothing)
      case r of
        Just m -> pure m
        Nothing -> takeMVar (abSig b) >> loop b

mtimeT :: Int
mtimeT = 9977 -- runtime-range tid for the shim's mtime handle

actorNames :: S.Set Name
actorNames =
  S.fromList
    [ "myself", "spawn", "send", "sendLinear", "sendArc", "receive", "receiveFrom", "kill", "yield",
      "spawnCap", "spawnCapOn", "spawnOn", "Sys.spawnApp", "timeNow",
      "drop", "keep", "device", "reg32",
      "Sys.poolReset", "Sys.sleepUs", "Sys.logAt", "Sys.memStats", "Sys.memInfo"
    ]

actorCall :: VMEnv -> Name -> [Value] -> IO Value
actorCall env "myself" [_] = VInt . fromIntegral <$> actorSelf (vmActors env)
actorCall env "spawn" [f] = do
  let actors = vmActors env
  (i, b) <- newBox actors
  mask $ \restore -> do
    start <- newEmptyMVar
    tid <- forkIO $ do
      takeMVar start
      t <- myThreadId
      atomicModifyIORef' (arByTid actors) (\mm -> (M.insert t i mm, ()))
      restore
        (do
            r <- try (apply env f (VInt (fromIntegral i)))
            case r of
              Left e
                | Just ThreadKilled <- fromException e -> pure ()
                | otherwise ->
                    putStrLn ("*** SOL PANIC [actor " ++ show i ++ "]: " ++ show (e :: SomeException) ++ " ***")
              Right _ -> pure ())
        `finally` do
          atomicModifyIORef' (arReg actors) (\m -> (IM.delete i m, ()))
          atomicModifyIORef' (arByTid actors) (\m -> (M.delete t m, ()))
          _ <- tryPutMVar (abDone b) ()
          pure ()
    writeIORef (abTid b) (Just tid)
    putMVar start ()
  pure (VInt (fromIntegral i))
-- the mailbox policy / placement / pid variants: this shim's queues are
-- unbounded Haskell channels and its actors are threads, so every one
-- of them is a plain spawn (docs/MAILBOX.md, docs/MEMORY.md)
actorCall env "spawnCap" [_, _, f] = actorCall env "spawn" [f]
actorCall env "spawnCapOn" [_, _, _, f] = actorCall env "spawn" [f]
actorCall env "spawnOn" [_, f] = actorCall env "spawn" [f]
actorCall env "Sys.spawnApp" [f] = actorCall env "spawn" [f]
actorCall _ "timeNow" [_] = VInt . round <$> getPOSIXTime
actorCall _ "Sys.memInfo" [_] = pure (foldr (\x acc -> VData listT 1 [VInt x, acc]) (VData listT 0 []) (replicate 8 0))
actorCall env "send" [VInt to, m] = do
  let actors = vmActors env
  from <- actorSelf actors
  actorEnqueue actors (fromIntegral to) from m
  pure (VData 3 0 [vUnit]) -- Ok Unit: an unbounded queue never refuses
-- sendLinear: MOVE semantics.  In this profile values are immutable
-- Haskell terms, so the move IS a send -- the verb exists for grammar
-- parity with the AOT tiers, where it transfers the message slab
-- (hal/core/actors.c a_send_linear) and the checker consumes the arg.
actorCall e "sendLinear" [to, m] = actorCall e "send" [to, m]
-- sendArc: SHARE semantics; immutable values make sharing == sending
actorCall e "sendArc" [to, m] = actorCall e "send" [to, m]
actorCall env "receive" [VInt _me] = actorTake (vmActors env) (const True)
actorCall env "receiveFrom" [VInt _me, VInt from] = actorTake (vmActors env) (== fromIntegral from)
actorCall env "kill" [VInt i] = do
  let actors = vmActors env
  reg <- readIORef (arReg actors)
  case IM.lookup (fromIntegral i) reg of
    Nothing -> pure vUnit
    Just b -> do
      mt <- readIORef (abTid b)
      atomicModifyIORef' (arReg actors) (\m -> (IM.delete (fromIntegral i) m, ()))
      case mt of
        Nothing -> pure ()
        Just tid -> killThread tid >> takeMVar (abDone b)
      pure vUnit
actorCall _ "yield" [_] = Control.Concurrent.yield >> pure vUnit
actorCall _ "drop" [_] = pure vUnit
actorCall _ "keep" [v] = pure v
actorCall _ "device" [_] = pure (VInt 0)
actorCall _ "reg32" [_, _] = pure (VData mtimeT 0 [])
actorCall _ "Sys.poolReset" [_] = pure (VInt 0)
actorCall _ "Sys.sleepUs" [VInt us] = threadDelay (fromIntegral us) >> pure vUnit
actorCall _ "Sys.logAt" [VInt h, s] = do
  str <- vsStr s
  putStrLn ("[log@" ++ show h ++ "] " ++ str)
  pure vUnit
actorCall _ "Sys.memStats" [_] = pure (VData 4 0 [VInt 0, VInt 0])
actorCall _ g as = vmPanic ("actor shim " ++ g ++ ": bad arguments " ++ show (map render as))

-- ---- content-addressed file modules (Mod.hs does the work) -----------------
modCall :: VMEnv -> Name -> [Value] -> IO Value
modCall env "use" [VStr spec] = do
  r <- resolveModule ".sol" (vmBaseDir env) spec
  case r of
    Left e -> vmPanic e
    Right (p, h, pinned) -> do
      unless pinned $
        putStrLn ("[sol] use: " ++ spec ++ " resolves to " ++ spec ++ "#" ++ h ++ " (pin this)")
      pure (VMod p h)
modCall _ "use" [v] = vmPanic ("use: expected a module spec string, got " ++ render v)
modCall env "run" [VMod p h, x] = do
  r <- runModule p h (render x)
  case r of
    Left e -> vmPanic e
    Right (out, cpaths) -> do
      -- the read-before-run shape can NEVER commit: the child's write
      -- invalidates our snapshot, the retry re-runs the child, forever
      -- (amplifying its effects). Refuse deterministically instead.
      overlap <- txChildOverlap (vmTx env) cpaths
      if null overlap
        then pure (VStr out)
        else
          vmPanic
            ( "run: the child module committed to " ++ show overlap
                ++ ", which this transaction already read, listed, or wrote —"
                ++ " that can never validate (every retry re-runs the child)."
                ++ " Read those paths AFTER run, or pass data via stdin/stdout"
            )
modCall _ "run" [v, _] = vmPanic ("run: not a module: " ++ render v)
modCall _ g _ = vmPanic (g ++ ": bad arguments")

-- ---- recursion schemes: the JIT tier ---------------------------------------
--
-- map / filter / foldl are the only calls the JIT ever sees, and only when:
--   * the list is all unboxed ints and longer than jitThreshold
--   * the element function is an unapplied top-level supercombinator whose
--     call closure is arithmetic-only Core (checked in JIT.jittable)
-- Everything else falls back to the interpreted loop below. The schemes are
-- bounded by construction (one call per element), so they need no
-- preemption; fuel is still counted — reified into the native code — and
-- the cell is reconciled with the VM's counter around the pure native call.


-- ---- typed marshalling for the JIT boundary --------------------------------

d2b :: Double -> Int64
d2b = fromIntegral . castDoubleToWord64

b2d :: Int64 -> Double
b2d = castWord64ToDouble . fromIntegral

-- classify a list for the typed tier: all-VInt rides as i64s (JI); any
-- VNum promotes every element to f64 bits — all-VNum is JD, a mixture is
-- JW (each element COULD have been an Int the interpreter would keep exact)
toTyped :: Value -> Maybe (JTy, [Int64])
toTyped v0 = do
  xs <- nums v0
  -- classify by what the elements ARE, never by what they are not: a
  -- list of NON-numbers (rows, records, strings) must bail to the
  -- interpreter.  The old "not an Int => Double" read classified a
  -- list of lists as JD and encoded every element as 0 bits -- any
  -- boxed-element map/filter/fold over the JIT threshold silently
  -- computed on zeros (the NN's row lists were the first witness).
  ety <-
    if all isI xs
      then Just JI
      else
        if all isD xs
          then Just JD
          else if all (\x -> isI x || isD x) xs then Just JW else Nothing
  pure (ety, map (enc ety) xs)
  where
    nums (VData t 1 [x, r]) | t == listT = (x :) <$> nums r
    nums (VData t 0 []) | t == listT = Just []
    nums _ = Nothing
    isI VInt {} = True
    isI _ = False
    isD VNum {} = True
    isD _ = False
    enc JI (VInt i) = fromIntegral i
    enc _ (VInt i) = d2b (fromIntegral i)
    enc _ (VNum d) = d2b d
    enc _ _ = 0

valBits :: JTy -> Value -> Int64
valBits JI (VInt a) = fromIntegral a
valBits _ (VInt a) = d2b (fromIntegral a)
valBits _ (VNum d) = d2b d
valBits _ _ = 0

bitsVal :: JTy -> Int64 -> Value
bitsVal JI r = VInt (fromIntegral r)
bitsVal _ r = VNum (b2d r)

accTyOf :: Maybe Value -> Maybe JTy
accTyOf Nothing = Just JI
accTyOf (Just (VInt _)) = Just JI
accTyOf (Just (VNum _)) = Just JD
accTyOf _ = Nothing

kindTy :: ColKind -> JTy
kindTy KInt = JI
kindTy KNum = JD
kindTy KBox = JW -- marker: unloadable; jitOKVec rejects any touch

schemeArities :: M.Map Name Int
schemeArities = M.fromList [("map", 2), ("filter", 2), ("foldl", 3)]

jitThreshold :: Int
jitThreshold = 64

schemeCall :: VMEnv -> Name -> [Value] -> IO Value
schemeCall env name args = case (name, args) of
  ("map", [f, xs]) -> viaJit "map" f xs Nothing (interpMap f xs)
  ("filter", [f, xs]) -> viaJit "filter" f xs Nothing (interpFilter f xs)
  ("foldl", [f, z, xs]) -> viaJit "foldl" f xs (Just z) (interpFold f z xs)
  _ -> vmPanic (name ++ ": bad arguments")
  where
    viaJit scheme f xs macc fallback = viaGpu scheme f xs macc fallback
    viaGpu scheme f xs macc fallback
      | scheme == "map",
        Just gc <- vmGpu env,
        Just g <- unappliedFn f,
        Just (JD, bits) <- toTyped xs,
        length bits >= Gpu.gpuMinLen,
        Just src <- Gpu.glslOfFn (vmCore env) g 0 = do
          r <- Gpu.gpuMapF64 gc src [] (map b2d' bits)
          case r of
            Just out -> do
              putStrLn ("[gpu] map<" ++ g ++ "> n=" ++ show (length bits) ++ " (f64 compute shader)")
              pure (foldr (\d acc -> VData listT 1 [VNum d, acc]) (VData listT 0 []) out)
            Nothing -> viaJit' scheme f xs macc fallback -- backend declined: JIT tier
      | otherwise = viaJit' scheme f xs macc fallback
    b2d' = castWord64ToDouble . fromIntegral
    viaJit' scheme f xs macc fallback =
      case (vmJit env, unappliedFn f, toTyped xs) of
        (Just jc, Just g, Just (ety, bits))
          | length bits >= jitThreshold,
            Just aty0 <- accTyOf macc,
            -- map/filter over MIXED lists bail: the promoted elements lose
            -- which ones the interpreter would keep as exact VInts
            not (ety == JW && scheme /= "foldl") ->
              compileScheme jc (vmCore env) scheme g ety aty0 >>= \case
                Nothing -> fallback -- not jittable: interpreter's job
                Just (addr, accTy, retTy) -> withFuelCell env $ \pfuel ->
                  if scheme == "foldl"
                    then do
                      let Just a0 = macc
                      bitsVal retTy <$> runFold addr pfuel (valBits accTy a0) bits
                    else do
                      (_, out) <- runMapFilter addr pfuel bits
                      let outTy = if scheme == "map" then retTy else ety
                      pure (foldr (\x acc -> VData listT 1 [bitsVal outTy x, acc]) (VData listT 0 []) out)
        _ -> fallback

    unappliedFn (VPap g [] _) | M.member g (vmProg env) = Just g
    unappliedFn _ = Nothing

    interpMap f = go
      where
        go (VData t 1 [x, r]) | t == listT = do
          y <- apply env f x
          rest <- go r
          pure (VData listT 1 [y, rest])
        go (VData t 0 []) | t == listT = pure (VData listT 0 [])
        go v = vmPanic ("map: not a list: " ++ render v)
    interpFilter f = go
      where
        go (VData t 1 [x, r]) | t == listT = do
          keep <- apply env f x
          rest <- go r
          case keep of
            VData bt 1 [] | bt == boolT -> pure (VData listT 1 [x, rest])
            VData bt 0 [] | bt == boolT -> pure rest
            VInt n -> pure (if n /= 0 then VData listT 1 [x, rest] else rest)
            v -> vmPanic ("filter: predicate returned non-bool: " ++ render v)
        go (VData t 0 []) | t == listT = pure (VData listT 0 [])
        go v = vmPanic ("filter: not a list: " ++ render v)
    interpFold f = go
      where
        go acc (VData t 1 [x, r]) | t == listT = do
          acc' <- apply env f acc >>= \pf -> apply env pf x
          go acc' r
        go acc (VData t 0 []) | t == listT = pure acc
        go _ v = vmPanic ("foldl: not a list: " ++ render v)


-- a scheme function is JIT-callable if it's a top-level supercombinator
-- with the right number of args REMAINING and every already-captured arg
-- is an unboxed int (delivered as the dual's extras)
jitCallable :: VMEnv -> String -> Value -> Maybe (Name, [(Int64, JTy)])
jitCallable env scheme f = case f of
  VPap g revArgs remaining
    | M.member g (vmCore env),
      remaining == (if scheme == "vecfold" then 2 else 1),
      Just is <- mapM toTV (reverse revArgs) ->
        Just (g, is)
  _ -> Nothing
  where
    -- captured scalars carry their own definite type: a VNum weight rides
    -- as f64 bits, a VInt as a plain i64 (typed inside the driver)
    toTV (VInt i) = Just (fromIntegral i, JI)
    toTV (VNum d) = Just (d2b d, JD)
    toTV _ = Nothing

-- marshal Sol Int lists <-> unboxed arrays: the builder->freeze boundary
toInts :: Value -> Maybe [Int64]
toInts (VData t 1 [VInt x, r]) | t == listT = (fromIntegral x :) <$> toInts r
toInts (VData t 0 []) | t == listT = Just []
toInts _ = Nothing

fromInts :: [Int64] -> Value
fromInts = foldr (\x acc -> VData listT 1 [VInt (fromIntegral x), acc]) (VData listT 0 [])

-- hand the native code a fuel cell; reconcile with the VM counter after.
-- Native code only decrements (accounting, per the function-entry contract);
-- exhaustion mid-scheme is impossible to act on there — which is fine,
-- because the schemes are bounded — so the refill/preempt bookkeeping
-- happens here, once, on return.
withFuelCell :: VMEnv -> (Ptr Int64 -> IO a) -> IO a
withFuelCell env body = alloca $ \p -> do
  f0 <- readIORef (vmFuel env)
  poke p (fromIntegral f0)
  r <- body p
  f1 <- peek p
  -- poisoned cells (minus any ticks after the poison): a trap is the
  -- deeper value, so test it first
  when (f1 <= fuelTrap + 1152921504606846976) (vmPanic "error raised inside a native kernel (rerun with SOL_JIT=0 for the message)")
  when (f1 <= fuelPoison) (vmPanic "division by zero")
  if f1 <= 0
    then do
      modifyIORef' (vmPreempts env) (+ 1)
      writeIORef (vmFuel env) fuelQuantum
    else writeIORef (vmFuel env) (fromIntegral f1)
  pure r

-- ---- the HAL: prims + transactional file IO -------------------------------
--
-- Every entry here is what an fpr_g_* symbol is on the metal: the ONLY
-- surface generated code can reach the outside world through. Path/Handle
-- tids are passed in because the front-end assigns user-type ids in
-- declaration order (prelude declares them first).

-- a BStr's store is an IORef, which can't ride in a VData field, so the
-- runtime uses a table of refs keyed by a fresh Int id -- the same bridge
-- Handle uses.  (This table IS the BStr representation.)
type BStrTable = IORef (IM.IntMap (IORef BStrStore))

newBStrTable :: IO BStrTable
newBStrTable = newIORef IM.empty

bstInsert :: BStrTable -> IORef BStrStore -> IO Int
bstInsert tbl ref = atomicModifyIORef' tbl $ \m ->
  let k = if IM.null m then 1 else fst (IM.findMax m) + 1
   in (IM.insert k ref m, k)

bstLookup :: BStrTable -> Int -> IO (IORef BStrStore)
bstLookup tbl k = do
  m <- readIORef tbl
  case IM.lookup k m of
    Just r  -> pure r
    Nothing -> ioError (userError ("BStr: stale ref " ++ show k ++ " (linearity violation?)"))

bstDelete :: BStrTable -> Int -> IO (IORef BStrStore)
bstDelete tbl k = do
  r <- bstLookup tbl k
  atomicModifyIORef' tbl (\m -> (IM.delete k m, ()))
  pure r

mkHal :: M.Map Name (Int, Int, Int) -> [String] -> IORef TxState -> IORef Int -> RtCounts -> M.Map Name (Int, [Value] -> IO Value)
mkHal cons scriptArgs tx preempts rt =
  M.fromList
    [ ("str", (1, \[v] -> pure (VStr (render v)))),
      -- VStr ops: accept VStr; all O(n) due to linked-list backing
      ("strcat", (2, \[a, b] -> fmap VStr (liftA2 (++) (vsStr a) (vsStr b)))),
      ("String.len", (1, \[v] -> VInt . fromIntegral . length <$> vsStr v)),
      ("strlen", (1, \[v] -> VInt . fromIntegral . length <$> vsStr v)),
      ("charAt", (2, charAtH)),
      ("substr", (3, substrH)),
      -- the O(n) string tier: one pass each, no re-slicing of the rest
      -- (Str.split / indexOf / replace / upper / lower / trim / join in
      -- the preamble dispatch here; semantics are the preamble's own:
      -- split "" = [], a trailing separator ends the list, indexOf is
      -- 1-based with 0 = miss and "" never found, replace is leftmost
      -- non-overlapping, case folding is ASCII, trim strips 32/9/10/13)
      ("strSplit", (2, \[VInt c, sv] -> vsStr sv >>= \s -> pure (strList (splitCodes (toEnum (fromIntegral c)) s)))),
      ("strIndexOf", (2, \[pv, sv] -> liftA2 (\p s -> VInt (fromIntegral (indexOfStr p s))) (vsStr pv) (vsStr sv))),
      ("strReplace", (3, \[ov, nv, sv] -> do o <- vsStr ov; n <- vsStr nv; s <- vsStr sv; pure (VStr (replaceStr o n s)))),
      ("strUpper", (1, \[v] -> VStr . map (\ch -> if ch >= 'a' && ch <= 'z' then toEnum (fromEnum ch - 32) else ch) <$> vsStr v)),
      ("strLower", (1, \[v] -> VStr . map (\ch -> if ch >= 'A' && ch <= 'Z' then toEnum (fromEnum ch + 32) else ch) <$> vsStr v)),
      ("strTrim", (1, \[v] -> VStr . trimStr <$> vsStr v)),
      ("strJoin", (2, \[sepv, lv] -> do sep <- vsStr sepv; xs <- mapM vsStr (listItems lv); pure (VStr (intercalate sep xs)))),
      -- Str.cmp: -1 / 0 / 1 by code (the sort comparator the prelude's
      -- Int-only < could not be); Str.codes: the characters as a list of
      -- codes, one pass -- a scanner walks that instead of charAt s i
      ("strCmp", (2, \[av, bv] -> liftA2 (\a b -> VInt (case compare a b of LT -> -1; EQ -> 0; GT -> 1)) (vsStr av) (vsStr bv))),
      ("strCodes", (1, \[v] -> vsStr v >>= \s -> pure (foldr (\ch acc -> VData listT 1 [VInt (fromIntegral (fromEnum ch)), acc]) (VData listT 0 []) s))),
      ("chr", (1, \[VInt c] -> pure (VStr [toEnum (fromIntegral c)]))),
      -- VBStr ops: O(1) amortised; declared as a separate HAL surface so the
      -- linearity checker treats them the same as Vec.* (the BStr 1 prelude
      -- declaration makes BStr linear; every op threads it)
      -- ---- BStr ops: the fast byte-buffer string tier ----
      -- At the Sol level, BStr looks like `BStr Int` (the Int is a ref-table
      -- key). The HAL dispatches via mkBStr/withBStr/consumeBStr.
      ("BStr.new", (1, \[_] -> newIORef (BStrStore initialBsCap 0 (BS.replicate initialBsCap 0)) >>= mkBStr)),
      ("BStr.fromStr", (1, \[v] -> vsStr v >>= \s -> do r <- newIORef =<< (let bs = BSU.fromString s; n = BS.length bs; cap = max initialBsCap (n * 2) in pure (BStrStore cap n (bs <> BS.replicate (max 0 (cap - n)) 0))); mkBStr r)),
      ("BStr.toStr", (1, \[v] -> withBStr v (\r -> VStr <$> bsContent r) >>= \res -> consumeBStr v >> pure res)),
      ("BStr.append", (2, \[sv, bv] -> withBStr bv (\r -> vsStr sv >>= bsAppendStr r) >> pure bv)),
      ("BStr.cat", (2, \[a, b] -> do
          sa <- case a of VStr s -> pure s; _ -> withBStr a bsContent
          sb <- case b of VStr s -> pure s; _ -> withBStr b bsContent
          let bs = BSU.fromString (sa ++ sb); n = BS.length bs; cap = max initialBsCap (n * 2)
          r <- newIORef (BStrStore cap n (bs <> BS.replicate (max 0 (cap - n)) 0))
          mkBStr r)),
      ("BStr.len", (1, \[v] -> withBStr v (\r -> do n <- bsCpLen r; pure (VData 4 0 [VInt (fromIntegral n), v])))),
      ("BStr.at", (2, \[v, VInt i] -> withBStr v (\r -> do c <- bsCpAt r (fromIntegral i - 1); pure (VData 4 0 [VInt (fromIntegral c), v])))),
      ("BStr.sub", (3, \[v, VInt i, VInt j] -> withBStr v (\r -> do
          s <- bsContent r
          let lo = fromIntegral i; hi = fromIntegral j
          if lo < 1 || hi > length s || lo > hi
            then vmPanic "BStr.sub: index out of range"
            else do let bs = BSU.fromString (take (hi - lo + 1) (drop (lo - 1) s)); n = BS.length bs; cap = max initialBsCap (n * 2)
                    r2 <- newIORef (BStrStore cap n (bs <> BS.replicate (max 0 (cap - n)) 0))
                    sl <- mkBStr r2
                    pure (VData 4 0 [sl, v])))),
      ("BStr.free", (1, \[v] -> consumeBStr v >> pure vUnit)),
      ("error", (1, \[v] -> vmPanic (render v))),
      -- ---- the Ok/Err tier: fallible work returns Result, chained with |>? --
      -- These are the PRIMITIVES; the panicking spellings (parseInt,
      -- readPath) are prelude sugar: `unwrap (Try.parseInt s)`. Anything
      -- fallible added to the HAL from here on returns Ok/Err and gets its
      -- panicking twin for free.
      ("Try.parseInt", (1, tryParseIntH)),
      ("Try.parseNum", (1, tryParseNumH)),
      ("Try.readPath", (1, tryReadPathH)),
      ("Proc.query", (1, procQueryH)),
      ("Proc.afterCommit", (1, procAfterCommitH)),
      ("Proc.runNow", (1, procRunNowH)),
      ("args", (1, \[_] -> pure (strList scriptArgs))),
      -- Numeric prims: the doors into inexact arithmetic. Num.div is TRUE
      -- division (always inexact); ordinary +,-,*,/ then propagate
      -- inexactness by promotion in `arith`. floor/round land back on Int.
      -- the shared grammar's float-literal splices: bit halves -> the IEEE
      -- value, entering the tower as an inexact VNum.  A whole-number
      -- literal like 2.0 (or 2f) STAYS VNum: writing the point or suffix
      -- was the author asking for the inexact side.
      ("f64frombits", (2, \[VInt hi, VInt lo] ->
          pure (VNum (castWord64ToDouble
                       ((fromIntegral hi `shiftL` 32)
                          .|. (fromIntegral lo .&. 0xFFFFFFFF)))))),
      ("f32frombits", (1, \[VInt b] ->
          pure (VNum (realToFrac (castWord32ToFloat (fromIntegral b)))))),
      ("Num.div", (2, \[a, b] -> numDivH a b)),
      ("Num.sqrt", (1, \[a] -> numSqrtH a)),
      ("Num.floor", (1, \[a] -> pure (VInt (floor (toD a))))),
      ("Num.round", (1, \[a] -> pure (VInt (round (toD a))))),
      ("!", (2, indexH)),
      -- the transactional file surface: linear Handle discipline is enforced
      -- at COMPILE TIME by the linearity checker; these just do the TRec ops
      ("open", (1, openH)),
      ("readAll", (1, readH)),
      ("writeAll", (2, writeH)),
      ("close", (1, closeH)),
      -- read/write: the ONLY other doors out. `read x` is a coeffect —
      -- x is a path (file contents / a device) or an Io query carrying its
      -- own path or command. `write p v` is an effect — v's shape (string
      -- contents vs Io intent) or p's device prefix picks the operation.
      -- Everything the prelude calls fs ops (mkdirp, rm, ls, stat, mv, sh,
      -- print, input, ...) is Sol code decoded HERE, transactionally.
      ("read", (1, \[v] -> readIoH v)),
      ("write", (2, \[pv, v] -> writeIoH pv v))
    ]
  where
    bst = globalBst
    (pathT, handleT) = (tidOf "Path", tidOf "Handle")
    bstrT = tidOf "BStr"
    processSpecT = tidOf "ProcessSpec"
    processResultT = tidOf "ProcessResult"
    mkBStr r = do k <- bstInsert bst r; pure (VData bstrT 0 [VInt (fromIntegral k)])
    withBStr (VData t 0 [VInt k]) f | t == bstrT = bstLookup bst (fromIntegral k) >>= f
    withBStr v _ = vmPanic ("BStr op: not a BStr: " ++ render v)
    consumeBStr (VData t 0 [VInt k]) | t == bstrT = bstDelete bst (fromIntegral k)
    consumeBStr v = vmPanic ("BStr.free: not a BStr: " ++ render v)
    tidOf n = maybe (-1) (\(t, _, _) -> t) (M.lookup n cons)
    conTV n = maybe (-1, -1) (\(t, v, _) -> (t, v)) (M.lookup n cons)
    isCon n t g = conTV n == (t, g)

    readIoH v
      | Just p <- unPath v = case p of
          -- stdin is a read like any other: snapshotted once, replayed
          -- to every later call and every RETRY (Txn.txInput)
          "/dev/in" -> VStr <$> txInput
          "/dev/fuel" -> VInt . fromIntegral <$> readIORef preempts
          _ -> VStr <$> txReadWhole p
    readIoH (VData t g [q])
      | isCon "Ls" t g = withP q (\p -> strList <$> txLs tx p)
      | isCon "Exists" t g = withP q (\p -> vBool <$> txExists tx p)
      | isCon "IsDir" t g = withP q (\p -> vBool <$> txIsDir tx p)
      | isCon "Stat" t g = withP q (\p -> do
          (e, sz, mt) <- txStat tx p
          pure (VData 5 0 [vBool e, VInt (fromIntegral sz), VInt (fromIntegral mt)]))
      | isCon "Sh" t g = withS q (\c -> do
          (code, out) <- txSh c
          pure (VData 4 0 [VInt (fromIntegral code), VStr out]))
      -- ---- realtime reads: outside the transaction ----
      | isCon "Now" t g = withP q (\p -> do
          noteEscape rt "readNow"
            ("re-reads " ++ p ++ " from disk; not snapshotted, so this value "
              ++ "is not validated at commit (transactional: readPath)")
          VStr . maybe "" id <$> rtRead p)
      | isCon "NowSh" t g = withS q (\c -> do
          noteEscape rt "shNow"
            ("streams `" ++ c ++ "` live and re-runs on every retry "
              ++ "(transactional: shq, which runs once inside the commit)")
          -- shNow answers an exit code, so it cannot refuse the way
          -- Proc.runNow does; it still says when it is running ahead of
          -- the transaction's own queued effects
          pending <- txPendingBrief tx
          unless (null pending) $
            hPutStrLn stderr ("[sol] ORDER: " ++ pendingOrderBrief ("shNow `" ++ c ++ "`") "shq" pending)
          VInt . fromIntegral <$> rtShell c)
    -- the actor shim's mtime handle: native 10MHz tick unit on wall clock
    readIoH (VData t 0 []) | t == mtimeT = VInt . round . (* 1e7) <$> getMonotonicTime
    readIoH (VData t g [])
      | isCon "NowLine" t g = do
          noteEscape rt "readLineNow"
            "reads one line of stdin now; re-reads on retry (transactional: input)"
          VStr <$> rtLine
    readIoH v = vmPanic ("read: cannot decode " ++ render v)

    writeIoH pv v = case unPath pv of
      Just "/dev/out" -> putStrLn (render v) >> hFlush stdout >> pure vUnit
      Just "/dev/sh" -> withS v (\c -> txShq tx c >> pure vUnit)
      Just "/dev/clock" -> case v of
        VInt ms -> threadDelay (fromIntegral ms * 1000) >> pure vUnit
        bad -> vmPanic ("write /dev/clock: expected ms Int, got " ++ render bad)
      Just p -> case v of
        VStr s -> txWriteWhole p s
        VData t g []
          | isCon "Dir" t g -> txMkdirp tx p >> pure vUnit
          | isCon "Rm" t g -> do
              -- refuse at issue time, not silently at replay: removeFile
              -- can never remove a directory, so queueing it is a lie
              isD <- txIsDir tx p
              if isD
                then vmPanic ("rm: " ++ p ++ " is a directory — use rmdir")
                else txRm tx p >> pure vUnit
          | isCon "RmDir" t g -> txRmdir tx p >> pure vUnit
        -- ---- realtime writes: land on disk before commit ----
        VData t g [sv]
          | isCon "NowSet" t g -> rtOut p sv "writeNow" rtWrite
          | isCon "NowAdd" t g -> rtOut p sv "appendNow" rtAppend
        bad -> vmPanic ("write " ++ p ++ ": cannot decode " ++ render bad)
      Nothing -> vmPanic ("write: expected a path or string, got " ++ render pv)


    -- a realtime write: happens now, survives a rollback, and revokes any
    -- claim this transaction had on the path (otherwise a script that both
    -- reads and appendNow's the same file invalidates itself and retries
    -- until it gives up)
    rtOut p sv kind op = do
      let s = case sv of VStr x -> x; other -> render other
      noteEscape rt kind
        ("writes " ++ p ++ " immediately; it is on disk before commit and "
          ++ "stays there if the transaction rolls back (transactional: writePath)")
      dropped <- op tx p s
      when dropped $
        hPutStrLn stderr
          ("[sol] REALTIME: " ++ p ++ " was already read in this transaction — "
            ++ "dropping it from the read set; the transaction no longer "
            ++ "guarantees anything about that path")
      pure vUnit

    toD (VInt i) = fromIntegral i
    toD (VNum d) = d
    toD v = unsafePerformIO (vmPanic ("Numeric op: not a number: " ++ render v))

    numDivH a b =
      let (x, y) = (toD a, toD b)
       in if y == 0 then vmPanic "Num.div: division by zero" else pure (VNum (x / y))
    numSqrtH a =
      let x = toD a
       in if x < 0 then vmPanic "Num.sqrt: negative" else pure (VNum (sqrt x))

    -- whole-file read/write = the handle quartet composed on the caller's
    -- behalf; identical txn semantics to open/readAll|writeAll/close
    txReadWhole p = do
      h <- txOpen tx p
      s <- txHRead tx h
      txClose tx h
      pure s
    txWriteWhole p s = do
      h <- txOpen tx p
      txHWrite tx h s
      txClose tx h
      pure vUnit
    unPath (VData t 0 [VStr p]) | t == pathT = Just p
    unPath (VStr p) = Just p
    unPath _ = Nothing

    withP (VData t 0 [VStr p]) k | t == pathT = k p
    withP (VStr p) k = k p
    withP bad _ = vmPanic ("expected a path or string, got " ++ render bad)

    withS (VStr c) k = k c
    withS bad _ = vmPanic ("expected a command string, got " ++ render bad)

    strList = foldr (\x acc -> VData listT 1 [VStr x, acc]) (VData listT 0 [])
    unHandle (VData t 0 [VInt h]) | t == handleT = Just (fromIntegral h)
    unHandle _ = Nothing
    mkHandle h = VData handleT 0 [VInt (fromIntegral h)]

    openH [v] = case unPath v of
      Just p -> mkHandle <$> txOpen tx p
      Nothing -> vmPanic ("open: not a Path: " ++ render v)
    openH _ = vmPanic "open: arity"

    readH [v] = case unHandle v of
      Just h -> do
        s <- txHRead tx h
        pure (VData 4 0 [VStr s, v]) -- (contents, handle) — hand the handle back
      Nothing -> vmPanic ("readAll: not a Handle: " ++ render v)
    readH _ = vmPanic "readAll: arity"

    writeH [v, VStr s] = case unHandle v of
      Just h -> txHWrite tx h s >> pure v -- returns the (rebound) handle
      Nothing -> vmPanic ("writeAll: not a Handle: " ++ render v)
    writeH _ = vmPanic "writeAll: bad args"

    closeH [v] = case unHandle v of
      Just h -> txClose tx h >> pure vUnit
      Nothing -> vmPanic ("close: not a Handle: " ++ render v)
    closeH _ = vmPanic "close: arity"

    -- Result values: Ok/Err are builtin constructors (tid 3)
    vOk v = VData 3 0 [v]
    vErr m = VData 3 1 [VStr m]

    tryParseIntH [v] = do
      s <- vsStr v
      case reads (dropWhile (== ' ') s) :: [(Integer, String)] of
        [(n, rest)] | all (`elem` " \n\t") rest -> pure (vOk (VInt n))
        _ -> pure (vErr ("parseInt: not an integer: " ++ show s))
    tryParseIntH _ = vmPanic "Try.parseInt: arity"

    -- Try.parseNum: the Numeric surface's reader -- an integer stays an
    -- exact VInt, a decimal / exponent form becomes a VNum. JSON and CSV
    -- numbers land here; "1e3" and "-0.5" are numbers, "nan"/"0x10" are not.
    tryParseNumH [v] = do
      s <- vsStr v
      let t = dropWhile (== ' ') s
          tail' = all (`elem` " \n\t")
          -- Haskell's reads wants a digit after '-' and before '.', as JSON does
      case reads t :: [(Integer, String)] of
        [(n, rest)] | tail' rest -> pure (vOk (VInt n))
        _ -> case reads t :: [(Double, String)] of
          [(d, rest)] | tail' rest -> pure (vOk (VNum d))
          _ -> pure (vErr ("parseNum: not a number: " ++ show s))
    tryParseNumH _ = vmPanic "Try.parseNum: arity"

    tryReadPathH [v] = withP v $ \p -> do
      r <- txTryRead tx p
      pure $ case r of
        TxText s -> vOk (VStr s)
        TxMissing -> vErr ("readPath: no such file: " ++ p)
        TxNonText -> vErr ("readPath: not a UTF-8 text file: " ++ p)
        TxReadError e -> vErr ("readPath: " ++ p ++ ": " ++ e)
    tryReadPathH _ = vmPanic "Try.readPath: arity"

    procQueryH [v] = decodeProcessSpec v >>= runProcessH
    procQueryH _ = vmPanic "Proc.query: arity"

    procAfterCommitH [v] = do
      spec <- decodeProcessSpec v
      txProcessAfterCommit tx spec
      pure vUnit
    procAfterCommitH _ = vmPanic "Proc.afterCommit: arity"

    procRunNowH [v] = do
      spec <- decodeProcessSpec v
      -- ORDER, not just atomicity: everything this transaction has queued
      -- happens at COMMIT, so an immediate process would run before all of
      -- it -- publishing a state the script has already described
      -- differently (a `Git.commit |> Git.push` in one script pushed the
      -- PRE-commit head and answered Ok). Refuse instead, in the Result the
      -- caller already handles.
      pending <- txPendingBrief tx
      if not (null pending)
        then pure (vErr (pendingOrderMsg ("Proc.runNow " ++ displayProcess spec) "Proc.afterCommit" pending))
        else do
          noteEscape rt "Proc.runNow"
            ("runs " ++ displayProcess spec ++ " immediately; it survives rollback "
              ++ "and runs again on every retry (deferred: Proc.afterCommit)")
          runProcessH spec
    procRunNowH _ = vmPanic "Proc.runNow: arity"

    runProcessH spec = do
      result <- runProcessSpec spec
      pure $ case result of
        Left err -> vErr ("process " ++ displayProcess spec ++ ": " ++ err)
        Right (code, out, err) ->
          vOk (VData processResultT 0 [VInt (fromIntegral code), VStr out, VStr err])

    decodeProcessSpec (VData t 0 [argvV, VStr cwdV, envV, VStr stdinV, VInt timeoutV])
      | t == processSpecT = do
          argv <- stringValues "argv" argvV
          envPairs <- envValues envV
          pure ProcessSpec
            { psArgv = argv,
              psCwd = if null cwdV then Nothing else Just cwdV,
              psEnv = envPairs,
              psStdin = stdinV,
              psTimeoutMs = if timeoutV <= 0 then Nothing else Just (fromIntegral timeoutV)
            }
    decodeProcessSpec bad = vmPanic ("process: expected ProcessSpec, got " ++ render bad)

    stringValues label = go
      where
        go (VData t 1 [VStr x, rest]) | t == listT = (x :) <$> go rest
        go (VData t 0 []) | t == listT = pure []
        go bad = vmPanic ("process " ++ label ++ ": expected List String, got " ++ render bad)

    envValues = go
      where
        go (VData t 1 [VData 4 0 [VStr key, VStr value], rest]) | t == listT =
          ((key, value) :) <$> go rest
        go (VData t 0 []) | t == listT = pure []
        go bad = vmPanic ("process env: expected List (String, String), got " ++ render bad)

    charAtH [sv, VInt i]
      | isStrVal sv = do
          s <- vsStr sv
          let n = fromIntegral i
          if n >= 1 && n <= length s
            then pure (VInt (fromIntegral (fromEnum (s !! (n - 1)))))
            else vmPanic "charAt: index out of range"
    charAtH _ = vmPanic "charAt: bad args"
    -- clamping semantics, mirrored from the AOT runtime's g_substr:
    -- 1-based offset, out-of-range never panics, it narrows to ""
    substrH [sv, VInt o0, VInt l0]
      | isStrVal sv = do
          s <- vsStr sv
          let o1 = max 1 (fromIntegral o0 :: Int)
              l1 = max 0 (fromIntegral l0 :: Int)
              (o, l) =
                if o1 - 1 >= length s
                  then (1, 0)
                  else (o1, min l1 (length s - (o1 - 1)))
          pure (VStr (take l (drop (o - 1) s)))
    substrH _ = vmPanic "substr: bad args"
    listItems :: Value -> [Value]
    listItems (VData t 1 [x, r]) | t == listT = x : listItems r
    listItems _ = []
    splitCodes :: Char -> String -> [String]
    splitCodes _ "" = []
    splitCodes c s = case break (== c) s of
      (pre, []) -> [pre]
      (pre, _ : rest) -> pre : splitCodes c rest
    indexOfStr :: String -> String -> Int
    indexOfStr "" _ = 0
    indexOfStr p s = go 1 s
      where
        go _ [] = 0
        go i t@(_ : r) = if startsWithStr p t then i else go (i + 1) r
    startsWithStr :: String -> String -> Bool
    startsWithStr [] _ = True
    startsWithStr _ [] = False
    startsWithStr (a : as) (b : bs) = a == b && startsWithStr as bs
    replaceStr :: String -> String -> String -> String
    replaceStr "" _ s = s
    replaceStr o n s = go s
      where
        go [] = []
        go t@(ch : r) = if startsWithStr o t then n ++ go (drop (length o) t) else ch : go r
    trimStr :: String -> String
    trimStr = dropWhileEnd' isSp . dropWhile isSp
      where
        isSp ch = ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
        dropWhileEnd' f = reverse . dropWhile f . reverse

    indexH [xs, VInt i] = idx xs i
      where
        idx (VVec r) k = getVec r (fromIntegral k - 1) -- O(1); consumes the vector (linearity) — Vec.get keeps it
        idx (VData t 1 [x, _]) 1 | t == listT = pure x
        idx (VData t 1 [_, r]) k | t == listT = idx r (k - 1)
        idx _ _ = vmPanic "!: index out of range"
    indexH _ = vmPanic "!: bad args"


-- IO-capable equality: needed for VBStr comparisons.
veqIO :: BStrTable -> Value -> Value -> IO Bool
veqIO bst a b = do
  sa <- strOf a; sb <- strOf b
  case (sa, sb) of
    (Just x, Just y) -> pure (x == y)
    _ -> pure (veq a b)
  where
    strOf (VStr s) = pure (Just s)
    strOf (VData _ 0 [VInt k]) = do
      m <- readIORef bst
      case IM.lookup (fromIntegral k) m of
        Just r -> Just <$> bsContent r
        Nothing -> pure Nothing
    strOf _ = pure Nothing

getEnvDebug :: Bool
getEnvDebug = unsafePerformIO (fmap (== Just "1") (lookupEnv "SOL_JIT_DEBUG"))
{-# NOINLINE getEnvDebug #-}

-- ---- the Vector builtins ----------------------------------------------------
--
-- Vector is LINEAR (prelude declares `Vector 1`), so in-place mutation is
-- sound: push/set mutate the store and hand the same reference back as the
-- "new" vector; the old binding is statically dead. All arg orders put the
-- vector LAST for |> pipelines: `v |> Vec.push 3 |> Vec.map inc`.
--
-- Vec.map / Vec.filter / Vec.fold are the DUAL schemes: over the JIT
-- threshold with an arithmetic element function they compile against the
-- SoA layout (element access becomes column loads — see JIT.compileVecScheme)
-- and run on the lent column pointers with zero marshalling. Otherwise they
-- RECONSTRUCT each element from the columns and apply the function in the
-- interpreter — the documented slower path, same one explicit pattern
-- matching and `!`/Vec.get take.

vecCall :: VMEnv -> Name -> [Value] -> IO Value
vecCall env name args = case (name, args) of
  ("Vec.new", [_]) -> newVec
  -- bulk construction at NATIVE speed: the push-per-element fill loop is
  -- interpreted bytecode and dominates ML-scale pipelines; range + a
  -- JIT/GPU map is the fast spelling of "generate n samples"
  ("Vec.range", [VInt lo, VInt hi]) -> vecRange (fromIntegral lo) (fromIntegral hi)
  ("Vec.push", [x, VVec r]) -> pushVec r x >> pure (VVec r)
  ("Vec.len", [VVec r]) -> do n <- lenVec r; pure (VData 4 0 [VInt (fromIntegral n), VVec r])
  ("Vec.get", [VInt i, VVec r]) -> do
    x <- getVec r (fromIntegral i - 1) -- 1-indexed like list !
    pure (VData 4 0 [x, VVec r])
  ("Vec.set", [VInt i, x, VVec r]) -> setVec r (fromIntegral i - 1) x >> pure (VVec r)
  ("Vec.free", [VVec _]) -> pure vUnit -- ForeignPtr finalizers reclaim
  -- the operator surface (VecOps in the prelude): elementwise + - *,
  -- the dot product, and scalar scaling -- both operands are consumed
  ("Vec.zipAdd", [VVec a, VVec b]) -> vecZip OAdd a b
  ("Vec.zipSub", [VVec a, VVec b]) -> vecZip OSub a b
  ("Vec.zipMul", [VVec a, VVec b]) -> vecZip OMul a b
  ("Vec.dot", [VVec a, VVec b]) -> vecDot a b
  ("Vec.scale", [k, VVec v]) -> vecScale k v
  ("Vec.toList", [VVec r]) -> do
    xs <- toListVec r
    pure (foldr (\x acc -> VData listT 1 [x, acc]) (VData listT 0 []) xs)
  ("Vec.fromList", [xs]) -> do
    v <- newVec
    let VVec r = v
        go (VData t 1 [x, rest]) | t == listT = pushVec r x >> go rest
        go (VData t 0 []) | t == listT = pure ()
        go bad = vmPanic ("Vec.fromList: not a list: " ++ render bad)
    go xs
    pure v
  ("Vec.map", [f, VVec r]) -> vecScheme env "vecmap" f Nothing r
  ("Vec.filter", [f, VVec r]) -> vecScheme env "vecfilter" f Nothing r
  ("Vec.fold", [f, z, VVec r]) -> vecScheme env "vecfold" f (Just z) r
  ("Vec.mmul", [VInt r, VInt k, VInt c, VVec va, VVec vb]) ->
    vecMatmul (fromIntegral r) (fromIntegral k) (fromIntegral c) va vb
  _ -> vmPanic (name ++ ": bad arguments (is the vector argument last?)")

-- ---- native matmul: lib/matrix's cells-column product ----------------------
-- a: ra x ka row-major cells, b: ka x cb row-major cells -> out ra x cb,
-- both operands threaded back (the matrices stay linear).  The FAST path
-- (both cells columns unboxed f64) is an unboxed triple loop whose inner
-- accumulation is mDot's exact fold shape -- k DESCENDING, seeded by the
-- exact-zero base -- so the result is BIT-IDENTICAL to the interpreted
-- list algebra it replaces.  Every other layout takes the GENERAL path:
-- the same cell loop over reconstructed Values through the VM's own
-- `arith`, so exact-Integer products stay exact bignums and mixed-type
-- cells panic exactly where the interpreter would.
vecMatmul :: Int -> Int -> Int -> IORef VecStore -> IORef VecStore -> IO Value
vecMatmul ra ka cb sra srb = do
  sa <- readIORef sra
  sb <- readIORef srb
  when (vLen sa /= ra * ka || vLen sb /= ka * cb) $
    vmPanic ("Vec.mmul: cells/dims mismatch (a: " ++ show (vLen sa) ++ " cells vs " ++ show ra ++ "x" ++ show ka
             ++ ", b: " ++ show (vLen sb) ++ " cells vs " ++ show ka ++ "x" ++ show cb ++ ")")
  out <- case (vRep sa, vCols sa, vRep sb, vCols sb) of
    (RScalar KNum, [CD _ fpa], RScalar KNum, [CD _ fpb]) -> do
      when getEnvDebug $ putStrLn ("[mmul] native f64 " ++ show ra ++ "x" ++ show ka ++ " * " ++ show ka ++ "x" ++ show cb)
      fpo <- mallocForeignPtrArray (max 1 (ra * cb))
      withForeignPtr fpa $ \pa -> withForeignPtr fpb $ \pb -> withForeignPtr fpo $ \po ->
        forM_ [0 .. ra - 1] $ \i ->
          forM_ [0 .. cb - 1] $ \j -> do
            let go k acc
                  | k < 0 = pure acc
                  | otherwise = do
                      x <- peekElemOff pa (i * ka + k)
                      y <- peekElemOff pb (k * cb + j)
                      go (k - 1) (x * y + acc)
            s <- go (ka - 1) (0 :: Double)
            pokeElemOff po (i * cb + j) s
      VVec <$> newIORef (VecStore (ra * cb) [CD (max 1 (ra * cb)) fpo] (RScalar KNum))
    _ -> do
      o <- newVec
      let VVec ro = o
      forM_ [0 .. ra - 1] $ \i ->
        forM_ [0 .. cb - 1] $ \j -> do
          let go k acc
                | k < 0 = pure acc
                | otherwise = do
                    x <- getVec sra (i * ka + k)
                    y <- getVec srb (k * cb + j)
                    xy <- arith OMul x y
                    acc' <- arith OAdd xy acc
                    go (k - 1) acc'
          s <- go (ka - 1) (VInt 0)
          pushVec ro s
      pure o
  pure (VData 5 0 [out, VVec sra, VVec srb])

-- elementwise zip of two columns (f64 fast path when both are unboxed
-- KNum columns; the exact/boxed path goes through `arith`, so integer
-- vectors stay exact bignums)
vecZip :: ArithOp -> IORef VecStore -> IORef VecStore -> IO Value
vecZip op sra srb = do
  sa <- readIORef sra
  sb <- readIORef srb
  let n = vLen sa
  when (vLen sb /= n) $ vmPanic ("Vec zip: lengths differ (" ++ show n ++ " vs " ++ show (vLen sb) ++ ")")
  case (vRep sa, vCols sa, vRep sb, vCols sb) of
    (RScalar KNum, [CD _ fpa], RScalar KNum, [CD _ fpb]) -> do
      fpo <- mallocForeignPtrArray (max 1 n)
      withForeignPtr fpa $ \pa -> withForeignPtr fpb $ \pb -> withForeignPtr fpo $ \po ->
        forM_ [0 .. n - 1] $ \i -> do
          x <- peekElemOff pa i
          y <- peekElemOff pb i
          pokeElemOff po i (case op of OAdd -> x + y; OSub -> x - y; _ -> x * y)
      VVec <$> newIORef (VecStore n [CD (max 1 n) fpo] (RScalar KNum))
    _ -> do
      o <- newVec
      let VVec ro = o
      forM_ [0 .. n - 1] $ \i -> do
        x <- getVec sra i
        y <- getVec srb i
        arith op x y >>= pushVec ro
      pure o

vecDot :: IORef VecStore -> IORef VecStore -> IO Value
vecDot sra srb = do
  sa <- readIORef sra
  sb <- readIORef srb
  let n = vLen sa
  when (vLen sb /= n) $ vmPanic ("Vec.dot: lengths differ (" ++ show n ++ " vs " ++ show (vLen sb) ++ ")")
  case (vRep sa, vCols sa, vRep sb, vCols sb) of
    (RScalar KNum, [CD _ fpa], RScalar KNum, [CD _ fpb]) ->
      withForeignPtr fpa $ \pa -> withForeignPtr fpb $ \pb -> do
        -- k descending from the exact-zero base: the same accumulation
        -- order as Vec.mmul's inner loop, so a 1xN * Nx1 product agrees
        let go k acc
              | k < 0 = pure acc
              | otherwise = do
                  x <- peekElemOff pa k
                  y <- peekElemOff pb k
                  go (k - 1) (x * y + acc)
        VNum <$> go (n - 1) (0 :: Double)
    _ -> do
      let go k acc
            | k < 0 = pure acc
            | otherwise = do
                x <- getVec sra k
                y <- getVec srb k
                xy <- arith OMul x y
                arith OAdd xy acc >>= go (k - 1)
      go (n - 1) (VInt 0)

vecScale :: Value -> IORef VecStore -> IO Value
vecScale k srv = do
  sv <- readIORef srv
  let n = vLen sv
  case (k, vRep sv, vCols sv) of
    (VNum kd, RScalar KNum, [CD _ fpv]) -> do
      fpo <- mallocForeignPtrArray (max 1 n)
      withForeignPtr fpv $ \pv -> withForeignPtr fpo $ \po ->
        forM_ [0 .. n - 1] $ \i -> peekElemOff pv i >>= pokeElemOff po i . (kd *)
      VVec <$> newIORef (VecStore n [CD (max 1 n) fpo] (RScalar KNum))
    _ -> do
      o <- newVec
      let VVec ro = o
      forM_ [0 .. n - 1] $ \i -> getVec srv i >>= arith OMul k >>= pushVec ro
      pure o

vecScheme :: VMEnv -> String -> Value -> Maybe Value -> IORef VecStore -> IO Value
vecScheme env scheme f macc r = do
  st <- readIORef r
  n <- lenVec r
  case (vmJit env, jitCallable env scheme f) of
    (Just _, Just (g, ex)) | getEnvDebug -> putStrLn ("[jit-debug] " ++ scheme ++ " f=" ++ g ++ " extras=" ++ show (length ex) ++ " n=" ++ show n ++ " layout=" ++ maybe "?" (\(_, _, sg) -> sg) (layoutInfo st))
    (Just _, Nothing) | getEnvDebug -> putStrLn ("[jit-debug] " ++ scheme ++ " fn not JIT-callable: " ++ render f)
    _ -> pure ()
  -- GPU tier: fires ONLY when every gate passes — availability, purity
  -- (the helper translates to GLSL exactly when it is in the safe
  -- arithmetic fragment), exactness (single f64 column: GLSL doubles do
  -- the same IEEE arithmetic as the JIT), and size (n >= SOL_GPU_MIN:
  -- below the SSBO round-trip crossover the JIT wins).  Declines fall
  -- through to the JIT, which falls through to the interpreter.
  gpu <- case (vmGpu env, jitCallable env scheme f, layoutInfo st) of
    (Just gc, Just (g, ex), Just (_, [KNum], _))
      | scheme == "vecmap",
        n >= Gpu.gpuMinLen,
        -- captured scalars ride double uniforms; only f64 captures keep
        -- the bit-identical contract (an exact-Int capture could be used
        -- in exact-int arithmetic the shader would silently double-ize)
        all ((== JD) . snd) ex,
        Just src <- Gpu.glslOfFn (vmCore env) g (length ex) ->
          withColPtrs st $ \colpp -> do
            colp <- peek colpp -- single column
            bits <- peekArray n colp
            res <- Gpu.gpuMapF64 gc src (map (b2d . fst) ex) (map b2d bits)
            case res of
              Nothing -> pure Nothing
              Just out -> do
                putStrLn ("[gpu] vecmap<" ++ g ++ "> n=" ++ show n
                          ++ (if null ex then "" else " +" ++ show (length ex) ++ " uniform capture(s)")
                          ++ " (f64 compute; gates: pure+f64+n>=" ++ show Gpu.gpuMinLen ++ ")")
                Just <$> vecFromNums out
    _ -> pure Nothing
  jitted <- case gpu of
   Just v -> pure (Just v)
   Nothing -> case (vmJit env, jitCallable env scheme f, layoutInfo st, accTyOf macc) of
    (Just jc, Just (g, extras), Just (scalar, ks, sig), Just aty0)
      | n >= jitThreshold ->
          compileVecScheme jc (vmCore env) scheme g scalar (map kindTy ks) sig (map snd extras) aty0 >>= \case
            -- a map whose helper RETURNS a record has no scalar dual;
            -- try the multi-output vecmapr path (native SoA
            -- construction) before conceding to the interpreter
            Nothing
              | scheme == "vecmap" ->
                  compileVecMapR jc (vmCore env) g scalar (map kindTy ks) sig (map snd extras) >>= \case
                    Nothing -> pure Nothing
                    Just (addr, tid, ftys) -> fmap Just $ withColPtrs st $ \cols -> withFuelCell env $ \pfuel ->
                      vecFromColsM n tid [if t == JI then KInt else KNum | t <- ftys] $ \outs ->
                        runVecMapR addr pfuel (map fst extras) cols n outs
            Nothing -> pure Nothing
            Just (addr, accTy, retTy) -> fmap Just $ withColPtrs st $ \cols -> withFuelCell env $ \pfuel ->
              case scheme of
                "vecfold" -> do
                  let Just a0 = macc
                  bitsVal retTy <$> runVecFold addr pfuel (map fst extras) cols n (valBits accTy a0)
                "vecmap" -> do
                  (_, out) <- runVecMapFilter addr pfuel (map fst extras) cols n
                  if retTy == JI then vecFromInts out else vecFromNums (map b2d out)
                _ -> do
                  (_, idxs) <- runVecMapFilter addr pfuel (map fst extras) cols n
                  gatherRows r (map fromIntegral idxs)
    _ -> pure Nothing
  case jitted of
    Just v -> finish v
    Nothing -> interp n >>= finish
  where

    finish v = case scheme of
      "vecfold" -> pure (VData 4 0 [v, VVec r]) -- (acc, vector)
      _ -> pure v
    -- interpreted duals: reconstruct each row from the columns, apply f
    interp n = case scheme of
      "vecmap" -> do
        out <- newVec
        let VVec r' = out
        mapM_ (\i -> getVec r i >>= apply env f >>= pushVec r') [0 .. n - 1]
        pure out
      "vecfilter" -> do
        keep <- filterIdx 0 n []
        gatherRows r (reverse keep)
      "vecfold" -> do
        let Just z = macc
        foldGo z 0 n
      _ -> vmPanic ("unknown vec scheme " ++ scheme)
      where
        filterIdx i lim acc
          | i >= lim = pure acc
          | otherwise = do
              x <- getVec r i
              kv <- apply env f x
              let kept = case kv of
                    VData bt 1 [] | bt == boolT -> True
                    VData bt 0 [] | bt == boolT -> False
                    VInt k -> k /= 0
                    _ -> False
              filterIdx (i + 1) lim (if kept then i : acc else acc)
        foldGo acc i lim
          | i >= lim = pure acc
          | otherwise = do
              x <- getVec r i
              pf <- apply env f acc
              acc' <- apply env pf x
              foldGo acc' (i + 1) lim
