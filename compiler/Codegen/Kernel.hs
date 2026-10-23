-- Column kernels are ordinary typed CFGs. No target registers or assembly
-- enter this module. The only memory operations follow descriptor guards;
-- the hosted/loaded-app profiles have non-moving storage across safepoints.
module Codegen.Kernel (Kernel(..), Stage(..), RecordKernel(..), RecordOp(..), MapAsKernel(..), SimdExpr(..), kernelCallbacks, lowerKernel, lowerRecordKernel, lowerMapAsKernel) where

import Codegen.IR
import Codegen.Target.Common (mangleName)
import Codegen.Policy
import Codegen.Verify
import Codegen.Simplify (simplifyFn)
import KernelKinds (Kind(..))
import Control.Monad.State.Strict
import Control.Monad (forM, forM_, unless, when, foldM)
import qualified Data.Map.Strict as M

-- Capture indices address the original, boxed entry arguments. An optional
-- accumulator also occupies an entry argument, before the vector.
data Stage = Stage String Name [Int] deriving Show
data Kernel = Kernel
  { kernelSymbol :: String, kernelCaptures :: [Kind], kernelElement :: Kind,
    kernelAccumulator :: Maybe (Int, Kind), kernelStages :: [Stage],
    kernelSimd :: Maybe (SimdExpr, Int), -- a map's two-lane body with same-kind captures (NEON/SSE2) and its callback entry ticks
    kernelRvvSum :: Bool -- a capture-free Int sum fold strip-mined on RISC-V V
  } deriving Show

-- the runtime's column kind descriptor byte (vec.c: 'i' 1, 'd' 3, 's' 7, boxed 0)
kindByteOf :: Kind -> Integer
kindByteOf k = case k of KI -> 1; KD -> 3; KS -> 7; KB -> 0

callbackSymbol :: Name -> String
callbackSymbol n = "fpr_tkfn_" ++ mangleName n

kernelCallbacks :: Program -> Program
kernelCallbacks program = M.map convert program
  where
    callee c | calleeKind c == Local, M.member (calleeName c) program = c {calleeKind = Generated (callbackSymbol (calleeName c))}
             | otherwise = c
    operation (OArith o a b) = OKernelArith o a b
    operation (OCall c args) = OCall (callee c) args
    operation op = op
    term (TTailCall c args) = TTailCall (callee c) args
    term t = t
    convert fn = fn {fnName = "$vkernel:" ++ callbackSymbol (fnName fn),
      fnBlocks = [b {bInstrs = [Instr d (operation op) | Instr d op <- bInstrs b], bTerm = term (bTerm b)} | b <- fnBlocks fn]}

data Build = Build Int Int BId [(VId,Ty)] [Instr] [Block]
type B = State Build
fresh :: Ty -> B (VId,Ty)
fresh ty = do Build v b cur ps ins bs <- get; put (Build (v+1) b cur ps ins bs); pure (VId v,ty)
label :: B BId
label = do Build v b cur ps ins bs <- get; put (Build v (b+1) cur ps ins bs); pure (BId b)
value :: Ty -> Op -> B VId
value ty op = do d <- fresh ty; instruction (Instr (Just d) op); pure (fst d)
instruction :: Instr -> B ()
instruction i = modify (\(Build v b cur ps ins bs) -> Build v b cur ps (i:ins) bs)
effect :: Op -> B ()
effect = instruction . Instr Nothing
end :: Term -> B ()
end term = modify (\(Build v b cur ps ins bs) -> Build v b cur ps [] (Block cur ps (reverse ins) term:bs))
begin :: BId -> [(VId,Ty)] -> B ()
begin cur ps = modify (\(Build v b _ _ _ bs) -> Build v b cur ps [] bs)
constant :: Integer -> B VId
constant = value TInt . OConstInt
assertGuard :: BId -> VId -> B ()
assertGuard fallback pred = do next <- label; end (TCondBr pred next [] fallback []); begin next []
load :: Ty -> VId -> Int -> B VId
load ty a off = value ty (OLoad ty a off)

-- Inline one lowered callback, including its fuel ticks, branches and traps.
-- Calls inside it keep their original convention; recursion is not expanded.
-- Each return (including a tail call) joins through a typed result parameter.
-- Large callbacks retain an ordinary generated call instead.
callback :: Program -> Name -> [VId] -> B VId
callback program name args
  | Just fn <- M.lookup name program,
    sum (map (length . bInstrs) (fnBlocks fn)) <= 80 = do
      defs <- forM (concatMap blockDefs (fnBlocks fn)) $ \(v,t) -> do (v',_) <- fresh t; pure (v,v')
      bids <- forM (fnBlocks fn) $ \b -> do l <- label; pure (bId b,l)
      join <- label
      result <- fresh TVal
      let vs = M.fromList defs; ls = M.fromList bids
          v x = vs M.! x; l x = ls M.! x
      end (TBr (l (fnEntry fn)) args)
      forM_ (fnBlocks fn) $ \b -> do
        begin (l (bId b)) [(v x,t) | (x,t) <- bParams b]
        forM_ (bInstrs b) $ \(Instr d op) ->
          unless (op == OStackCheck) (instruction (Instr (fmap (\(x,t) -> (v x,t)) d) (mapOpUses v op)))
        case mapTermUses v (bTerm b) of
          TRet x -> end (TBr join [x])
          TTailCall c xs -> value TVal (OCall c xs) >>= \x -> end (TBr join [x])
          TBr b xs -> end (TBr (l b) xs)
          TCondBr p t ts f fs -> end (TCondBr p (l t) ts (l f) fs)
          TUnreachable msg -> end (TUnreachable msg)
      begin join [result]
      pure (fst result)
  | otherwise = value TVal (OCall (Callee name (Generated (callbackSymbol name)) (replicate (length args) TVal) TVal) args)

lowerKernel :: Policy -> Program -> Kernel -> Either String Fn
lowerKernel policy callbacks k = do
  validatePolicy policy
  unless (kernelElement k `elem` [KI,KD,KS] && all (`elem` [KI,KD,KS,KB]) (kernelCaptures k))
    (Left "typed column kernels currently support Int/F64/F32 elements and Int/F64/F32/Bool captures")
  unless (policyWidth policy == W64 || (kernelElement k == KI && all (`notElem` [KD,KS]) (kernelCaptures k)))
    (Left "RV32 float columns use boxed values")
  unless (not (null stages) && all (\(Stage op _ _) -> op `elem` ["map","filter","fold"]) stages)
    (Left "unsupported typed kernel stages")
  case kernelSimd k of
    Just (expr,_) -> do
      unless ([op | Stage op _ _ <- stages] == ["map"] && all (== kernelElement k) (kernelCaptures k) && kernelElement k `elem` [KI,KD] && policyWidth policy == W64)
        (Left "a SIMD pair body needs a single map over Int or F64 with matching captures on a 64-bit word")
      unless (all (\n -> n >= 0 && n < length (kernelCaptures k)) (simdCaptures expr))
        (Left "SIMD capture index outside the kernel captures")
      checked (simdExprOk (kernelElement k == KI) expr)
    Nothing -> pure ()
  when (kernelRvvSum k) $
    unless ([op | Stage op _ _ <- stages] == ["fold"] && kernelCaptures k == [KI] && kernelElement k == KI && kernelAccumulator k == Just (0,KI))
      (Left "an RVV sum strip needs a capture-free Int fold")
  let ps = [(VId i,TVal) | i <- [0..length (kernelCaptures k)]]
      initial = Build (length ps) 1 (BId 0) ps [] []
      Build _ _ _ _ _ blocks = execState (build (map fst ps)) initial
      fn = Fn ("$vkernel:" ++ kernelSymbol k) (map (('a':) . show) [0..length ps-1]) TVal (BId 0) (reverse blocks)
  checked (verifyProgramWidth (policyWidth policy) (M.insert (fnName fn) fn callbacks))
  -- Simplification removes tag/untag pairs across the inlined callbacks.
  (simplified, _) <- checked (simplifyFn callbacks fn)
  checked (verifyProgramWidth (policyWidth policy) (M.insert (fnName fn) simplified callbacks))
  pure simplified
  where
    checked = either (Left . ("compiler error: " ++)) Right
    stages = kernelStages k
    w = if policyWidth policy == W32 then 4 else 8
    elemTy = if kernelElement k == KI then TInt else TVal
    build args = do
      effect OStackCheck
      effect OSafepoint
      fallback <- label
      -- Integer captures/accumulator have runtime guards, like the legacy
      -- kernel; float captures rely on the checked callback signature.
      forM_ (zip args (kernelCaptures k)) $ \(a,ty) -> case ty of
        KI -> value TPred (OIsInt a) >>= assertGuard fallback
        KB -> do
          p <- value TPred (OTagTest 1 0 a)
          yes <- label; checkTrue <- label
          end (TCondBr p yes [] checkTrue [])
          begin checkTrue []
          value TPred (OTagTest 1 1 a) >>= assertGuard fallback
          end (TBr yes []); begin yes []
        _ -> pure ()
      let vec = last args
      value TPred (OTagTest 9006 (if kernelElement k == KI then 1 else 4) vec) >>= assertGuard fallback
      addr <- value TAddr (OAddress vec)
      kinds <- load TAddr addr (8+4*w)
      kind <- value TInt (OLoadByte kinds 0)
      want <- constant (kindByteOf (kernelElement k))
      value TPred (OCmp Eq kind want) >>= assertGuard fallback
      count <- load TInt addr 8
      zero <- constant 0; one <- constant 1
      acc0 <- maybe (value TVal (ONullary 0 0)) (pure . (args !!) . fst) (kernelAccumulator k)
      done <- label; setup <- label; loop <- label; body <- label; next <- label
      resultAcc <- fresh TVal; resultKept <- fresh TInt
      empty <- value TPred (OCmp Eq count zero)
      end (TCondBr empty done [acc0,zero] setup [])
      begin setup []
      cols <- load TAddr addr (8+5*w)
      col <- load TAddr cols 0
      base <- load TAddr col w
      i <- fresh TInt; kept <- fresh TInt; acc <- fresh TVal
      (iStart,accStart) <- case (kernelSimd k, kernelRvvSum k) of
        (Just simd,_) -> simdPrefix args base count zero acc0 simd
        (_,True) -> rvvPrefix base count zero acc0
        _ -> pure (zero,acc0)
      end (TBr loop [iStart,iStart,accStart])
      begin loop [i,kept,acc]
      more <- value TPred (OCmp Lt (fst i) count)
      end (TCondBr more body [] done [fst acc,fst kept])
      begin body []
      cursor <- value TAddr (OIndex base (fst i))
      raw <- load elemTy cursor 0
      element <- if elemTy == TInt then value TVal (OTag raw) else pure raw
      nextKept <- fresh TInt; nextAcc <- fresh TVal
      let step (el,a) (Stage op f caps) = do
            out <- callback callbacks f (map (args !!) caps ++ (if op == "fold" then [a,el] else [el]))
            case op of
              "filter" -> do
                keep <- value TPred (OTruth out)
                pass <- label
                end (TCondBr keep pass [] next [fst kept,a])
                begin pass []
                pure (el,a)
              "fold" -> pure (el,out)
              _ -> pure (out,a)
      (el,a) <- foldM step (element,fst acc) stages
      -- A standalone fold does not mutate its input. A fused pipeline
      -- compacts the final mapped values and preserves their order.
      unless (all (\(Stage op _ _) -> op == "fold") stages) $ do
        dest <- value TAddr (OIndex base (fst kept))
        output <- if elemTy == TInt then value TInt (OUntag el) else pure el
        effect (OStore elemTy dest 0 output)
      kept' <- value TInt (OKernelArith Add (fst kept) one)
      end (TBr next [kept',a])
      begin next [nextKept,nextAcc]
      i' <- value TInt (OKernelArith Add (fst i) one)
      end (TBr loop [i',fst nextKept,fst nextAcc])
      begin done [resultAcc,resultKept]
      unless (all (\(Stage op _ _) -> op == "fold") stages) (effect (OStore TInt addr 8 (fst resultKept)))
      result <- case kernelAccumulator k of
        Nothing -> pure vec
        Just _ -> value TVal (OMake 4 0 [fst resultAcc,vec])
      end (TRet result)
      begin fallback []
      -- Preserve the whole original vector and boxed arguments until guards
      -- pass. A failed guard executes the generic passes in source order.
      let generic v (Stage op f caps) = do
            fun <- value TVal (OFunValue f)
            closure <- foldM (\h arg -> value TVal (OApply h [args !! arg])) fun caps
            let inputs = [closure] ++ (case (op,kernelAccumulator k) of
                  ("fold",Just (n,_)) -> [args !! n,v]
                  _ -> [v])
            value TVal (OCall (Callee ("Vec."++op) (Foreign ("fpr_vec_"++op)) (replicate (length inputs) TVal) TVal) inputs)
      foldM generic vec stages >>= end . TRet
    -- the SIMD pair loop ahead of the scalar loop: two lanes a step while two
    -- remain, each step charged both elements' entry ticks (the legacy kernel's
    -- specFuelN); the scalar loop takes the tail from where the pairs stopped
    simdPrefix args base count zero acc0 (expr,ticks) = do
      caps <- forM (take (length (kernelCaptures k)) args) $ \a ->
        if kernelElement k == KI then value TInt (OUntag a) else pure a
      pairLoop <- label; pairBody <- label; after <- label
      i2 <- fresh TInt
      end (TBr pairLoop [zero])
      begin pairLoop [i2]
      remaining <- value TInt (OKernelArith Sub count (fst i2))
      two <- constant 2
      enough <- value TPred (OCmp Ge remaining two)
      end (TCondBr enough pairBody [] after [])
      begin pairBody []
      effect (OSafepointN (2*(ticks+1)))
      cursor <- value TAddr (OIndex base (fst i2))
      effect (OSimdPair (kernelElement k == KI) expr caps cursor)
      i2' <- value TInt (OKernelArith Add (fst i2) two)
      end (TBr pairLoop [i2'])
      begin after []
      pure (fst i2, acc0)
    -- the RISC-V V strip loop for an Int sum: up to 64 lanes a strip, the
    -- lanes loaded and bound-checked (rvvLaneBound) and the accumulator kept
    -- away from the Int limits (rvvAccBound), so no prefix of the strip can
    -- overflow and the reduction is exactly the scalar fold; any strip that
    -- fails a bound hands the REST of the vector to the scalar loop, whose
    -- checked adds trap in source order
    rvvPrefix base count zero acc0 = do
      vl0 <- value TInt ORvvVlMax
      cap <- constant 64
      useVl <- label; useCap <- label; haveMax <- label
      vmax <- fresh TInt
      capLt <- value TPred (OCmp Lt vl0 cap)
      end (TCondBr capLt useVl [] useCap [])
      begin useVl []; end (TBr haveMax [vl0])
      begin useCap []; end (TBr haveMax [cap])
      begin haveMax [vmax]
      stripLoop <- label; stripBody <- label; pickRem <- label; pickMax <- label; picked <- label
      c1 <- label; c2 <- label; fast <- label; after <- label
      i3 <- fresh TInt; acc3 <- fresh TVal; n <- fresh TInt; iOut <- fresh TInt; accOut <- fresh TVal
      end (TBr stripLoop [zero,acc0])
      begin stripLoop [i3,acc3]
      remaining <- value TInt (OKernelArith Sub count (fst i3))
      more <- value TPred (OCmp Gt remaining zero)
      end (TCondBr more stripBody [] after [fst i3,fst acc3])
      begin stripBody []
      effect OSafepoint
      small <- value TPred (OCmp Lt remaining (fst vmax))
      end (TCondBr small pickRem [] pickMax [])
      begin pickRem []; end (TBr picked [remaining])
      begin pickMax []; end (TBr picked [fst vmax])
      begin picked [n]
      cursor <- value TAddr (OIndex base (fst i3))
      ok <- value TPred (ORvvLanes cursor (fst n))
      rawAcc <- value TInt (OUntag (fst acc3))
      hi <- constant (rvvAccBound (policyWidth policy)); lo <- constant (negate (rvvAccBound (policyWidth policy)))
      below <- value TPred (OCmp Lt rawAcc hi)
      above <- value TPred (OCmp Gt rawAcc lo)
      end (TCondBr ok c1 [] after [fst i3,fst acc3])
      begin c1 []
      end (TCondBr below c2 [] after [fst i3,fst acc3])
      begin c2 []
      end (TCondBr above fast [] after [fst i3,fst acc3])
      begin fast []
      total <- value TInt (ORvvSumLoaded rawAcc)
      tagged <- value TVal (OTag total)
      i3' <- value TInt (OKernelArith Add (fst i3) (fst n))
      end (TBr stripLoop [i3',tagged])
      begin after [iOut,accOut]
      pure (fst iOut, fst accOut)


-- A record plan describes the dualized callbacks, never architecture details.
-- Columns are (index, kind); map outputs cover the complete record. The map
-- entry retains the planner's capture slot even for a capture-free callback.
data RecordOp
  = RecordFold Name Kind
  | RecordFilter Name
  | RecordMap [(Name, [Int], [Int])]
  deriving Show
data RecordKernel = RecordKernel
  { recordSymbol :: String, recordOriginal :: Name,
    recordCaptures :: [Kind], recordHasCapture :: Bool,
    recordShape :: (Int,Int), recordColumns :: [(Int,Kind)],
    recordOperation :: RecordOp,
    recordGpuPairSum :: Bool -- a capture-free Int fold of acc + column 0 + column 1: offered to the GPU hook first (vec.c fpr_gpu_vec_fold_pair_sum)
  } deriving Show

lowerRecordKernel :: Policy -> Program -> RecordKernel -> Either String Fn
lowerRecordKernel policy callbacks k = do
  validatePolicy policy
  unless (not (null columns) && all ((>=0) . fst) columns)
    (Left "invalid typed record column plan")
  case operation of
    RecordMap fields -> unless
      (map fst columns == [0..length fields-1] && all (\(_,ps,cs) -> all (>=0) ps && all (`elem` map fst columns) cs) fields)
      (Left "invalid typed record map field plan")
    _ -> pure ()
  unless (all (`elem` [KI,KD,KS]) (map snd columns ++ accumulatorKinds) &&
          all (`elem` [KI,KD,KS,KB]) (recordCaptures k))
    (Left "typed record kernels currently support Int/F64/F32 columns and Int/F64/F32/Bool captures")
  when (recordGpuPairSum k) $
    unless (null (recordCaptures k) && map fst columns == [0,1] && accumulatorKinds == [KI] && all ((== KI) . snd) columns)
      (Left "the GPU pair sum needs a capture-free Int fold over columns 0 and 1")
  unless (policyWidth policy == W64 || all (`notElem` [KD,KS]) (map snd columns ++ accumulatorKinds ++ recordCaptures k))
    (Left "RV32 float record columns use boxed values")
  let argc = case operation of RecordMap _ -> 2; _ -> length (recordCaptures k) + length accumulatorKinds + 1
      ps = [(VId i,TVal) | i <- [0..argc-1]]
      Build _ _ _ _ _ blocks = execState (build (map fst ps)) (Build argc 1 (BId 0) ps [] [])
      fn = Fn ("$vkernel:" ++ recordSymbol k) (map (('a':) . show) [0..argc-1]) TVal (BId 0) (reverse blocks)
  checked (verifyProgramWidth (policyWidth policy) (M.insert (fnName fn) fn callbacks))
  (simplified,_) <- checked (simplifyFn callbacks fn)
  checked (verifyProgramWidth (policyWidth policy) (M.insert (fnName fn) simplified callbacks))
  pure simplified
  where
    checked = either (Left . ("compiler error: " ++)) Right
    columns = recordColumns k
    operation = recordOperation k
    accumulatorKinds = case operation of RecordFold _ ty -> [ty]; _ -> []
    w = if policyWidth policy == W32 then 4 else 8
    indexed a i = value TAddr (OIndex a i)
    at a n = constant (fromIntegral n) >>= indexed a
    guardKind fallback a ty = case ty of
      KI -> value TPred (OIsInt a) >>= assertGuard fallback
      KB -> do
        yes <- label; other <- label
        p <- value TPred (OTagTest 1 0 a)
        end (TCondBr p yes [] other [])
        begin other []
        value TPred (OTagTest 1 1 a) >>= assertGuard fallback
        end (TBr yes []); begin yes []
      _ -> pure ()
    equal fallback a n = do
      b <- constant (fromIntegral n)
      value TPred (OCmp Eq a b) >>= assertGuard fallback
    baseAt cols idx = do
      slot <- indexed cols idx
      col <- load TAddr slot 0
      load TAddr col w
    readColumn bases i (n,ty) = do
      cursor <- indexed (bases M.! n) i
      if ty == KI then load TInt cursor 0 >>= value TVal . OTag
                  else load TVal cursor 0
    build args = do
      effect OStackCheck
      effect OSafepoint
      fallback <- label
      let vec = last args
          capCount = length (recordCaptures k)
      forM_ (zip args (recordCaptures k ++ accumulatorKinds)) $ \(a,ty) -> guardKind fallback a ty
      value TPred (OTagTest 9006 3 vec) >>= assertGuard fallback
      addr <- value TAddr (OAddress vec)
      let (tid,var) = recordShape k
      when (tid >= 0) $ do
        load TInt addr (8+w) >>= \v -> equal fallback v tid
        load TInt addr (8+2*w) >>= \v -> equal fallback v var
      ncols <- load TInt addr (8+3*w)
      required <- constant (fromIntegral (maximum (map fst columns)+1))
      value TPred (OCmp Ge ncols required) >>= assertGuard fallback
      kinds <- load TAddr addr (8+4*w)
      forM_ columns $ \(n,ty) -> do
        -- Byte offsets are bounded in the IR; indexing keeps wide records
        -- independent of target load-immediate limits.
        ptr <- at kinds (n `div` w)
        kind <- value TInt (OLoadByte ptr (n `mod` w))
        equal fallback kind (kindByteOf ty)
      count <- load TInt addr 8
      zero <- constant 0; one <- constant 1
      acc0 <- case operation of RecordFold _ _ -> pure (args !! capCount); _ -> value TVal (ONullary 0 0)
      setup <- label; loop <- label; body <- label; done <- label; next <- label
      resultAcc <- fresh TVal; resultKept <- fresh TInt
      empty <- value TPred (OCmp Eq count zero)
      end (TCondBr empty done [acc0,zero] setup [])
      begin setup []
      cols <- load TAddr addr (8+5*w)
      bases <- M.fromList <$> forM columns (\(n,_) -> do idx <- constant (fromIntegral n); b <- baseAt cols idx; pure (n,b))
      i <- fresh TInt; kept <- fresh TInt; acc <- fresh TVal
      -- the GPU hook answers a tagged Int when it took the fold, 0 when it declined
      when (recordGpuPairSum k) $ do
        seed <- value TInt (OUntag acc0)
        answer <- value TVal (OCall (Callee "fpr_gpu_vec_fold_pair_sum_tagged" (Foreign "fpr_gpu_vec_fold_pair_sum_tagged") [TAddr,TAddr,TInt,TInt] TVal)
                                [bases M.! 0, bases M.! 1, count, seed])
        taken <- value TPred (OIsInt answer)
        cpu <- label
        end (TCondBr taken done [answer,zero] cpu [])
        begin cpu []
      end (TBr loop [zero,zero,acc0])
      begin loop [i,kept,acc]
      more <- value TPred (OCmp Lt (fst i) count)
      end (TCondBr more body [] done [fst acc,fst kept])
      begin body []
      effect OSafepoint
      values <- M.fromList <$> forM columns (\col@(n,_) -> do v <- readColumn bases (fst i) col; pure (n,v))
      nextKept <- fresh TInt; nextAcc <- fresh TVal
      case operation of
        RecordFold f _ -> do
          a <- callback callbacks f (take capCount args ++ [fst acc] ++ map ((values M.!) . fst) columns)
          end (TBr next [fst kept,a])
        RecordMap fields -> do
          -- Compute EVERY result from the original row before the first
          -- store. Updating a column early changes cross-field expressions.
          outputs <- forM fields $ \(f,projs,reads) -> do
            caps <- mapM (\n -> value TVal (OField n (args !! 0))) projs
            callback callbacks f (caps ++ map (values M.!) reads)
          forM_ (zip columns outputs) $ \((n,ty),out) -> do
            dest <- indexed (bases M.! n) (fst i)
            raw <- if ty == KI then value TInt (OUntag out) else pure out
            effect (OStore (if ty == KI then TInt else TVal) dest 0 raw)
          end (TBr next [fst kept,fst acc])
        RecordFilter f -> do
          out <- callback callbacks f (map ((values M.!) . fst) columns)
          keep <- value TPred (OTruth out)
          copy <- label; copyLoop <- label; copyBody <- label; copied <- label
          end (TCondBr keep copy [] next [fst kept,fst acc])
          begin copy []
          same <- value TPred (OCmp Eq (fst i) (fst kept))
          end (TCondBr same copied [] copyLoop [zero])
          j <- fresh TInt
          begin copyLoop [j]
          moreCols <- value TPred (OCmp Lt (fst j) ncols)
          end (TCondBr moreCols copyBody [] copied [])
          begin copyBody []
          -- The width is dynamic, so keep this inner loop fuel-bounded too.
          effect OSafepoint
          base <- baseAt cols (fst j)
          src <- indexed base (fst i); dst <- indexed base (fst kept)
          word <- load TVal src 0
          effect (OStore TVal dst 0 word)
          j' <- value TInt (OKernelArith Add (fst j) one)
          end (TBr copyLoop [j'])
          begin copied []
          kept' <- value TInt (OKernelArith Add (fst kept) one)
          end (TBr next [kept',fst acc])
      begin next [nextKept,nextAcc]
      i' <- value TInt (OKernelArith Add (fst i) one)
      end (TBr loop [i',fst nextKept,fst nextAcc])
      begin done [resultAcc,resultKept]
      result <- case operation of
        RecordFold _ _ -> value TVal (OMake 4 0 [fst resultAcc,vec])
        RecordFilter _ -> effect (OStore TInt addr 8 (fst resultKept)) >> pure vec
        RecordMap _ -> pure vec
      end (TRet result)
      begin fallback []
      fun <- value TVal (OFunValue (recordOriginal k))
      let caps = case operation of RecordMap _ -> [args !! 0 | recordHasCapture k]; _ -> take capCount args
      closure <- foldM (\h a -> value TVal (OApply h [a])) fun caps
      let (op,inputs) = case operation of
            RecordFold _ _ -> ("fold",[closure,args !! capCount,vec])
            RecordFilter _ -> ("filter",[closure,vec])
            RecordMap _ -> ("map",[closure,vec])
      value TVal (OCall (Callee ("Vec."++op) (Foreign ("fpr_vec_"++op)) (replicate (length inputs) TVal) TVal) inputs) >>= end . TRet


-- Vec.mapAs layout f v: a layout-changing map. The output vector is built
-- by the runtime (Vec.new or Vec.newAs layout, then one push per element),
-- the callback is the ORDINARY tagged function (its own messages, its own
-- fuel tick), and the input is freed at the end: the legacy
-- `Vec.mapAs direct scalar kernel`. Int, boxed and float inputs are read as
-- one word; an Int word is tagged on the way in. No callback is cloned.
data MapAsKernel = MapAsKernel
  { mapAsSymbol :: String, mapAsOriginal :: Name, mapAsCaptures :: Int, mapAsLayout :: String }
  deriving Show

lowerMapAsKernel :: Policy -> MapAsKernel -> Either String Fn
lowerMapAsKernel policy k = do
  validatePolicy policy
  unless (mapAsCaptures k >= 0 && mapAsCaptures k <= 7) (Left "typed mapAs kernels take at most seven captures")
  let argc = mapAsCaptures k + 1
      ps = [(VId i,TVal) | i <- [0..argc-1]]
      Build _ _ _ _ _ blocks = execState (build (map fst ps)) (Build argc 1 (BId 0) ps [] [])
      fn = Fn ("$vkernel:" ++ mapAsSymbol k) (map (('a':) . show) [0..argc-1]) TVal (BId 0) (reverse blocks)
  checked (verifyProgramWidth (policyWidth policy) (M.singleton (fnName fn) fn))
  (simplified,_) <- checked (simplifyFn M.empty fn)
  checked (verifyProgramWidth (policyWidth policy) (M.singleton (fnName fn) simplified))
  pure simplified
  where
    checked = either (Left . ("compiler error: " ++)) Right
    w = if policyWidth policy == W32 then 4 else 8
    hal name arity = Callee name (Foreign ("fpr_g_" ++ mangleName name ++ "_call" ++ show arity)) (replicate arity TVal) TVal
    build args = do
      effect OStackCheck
      effect OSafepoint
      fallback <- label
      let caps = init args; vec = last args
      -- an Int (1), boxed (2) or float (4) column; a record vector goes generic
      isInt <- value TPred (OTagTest 9006 1 vec)
      ready <- label; boxedTest <- label; floatTest <- label
      end (TCondBr isInt ready [] boxedTest [])
      begin boxedTest []
      isBoxed <- value TPred (OTagTest 9006 2 vec)
      end (TCondBr isBoxed ready [] floatTest [])
      begin floatTest []
      value TPred (OTagTest 9006 4 vec) >>= assertGuard fallback
      end (TBr ready [])
      begin ready []
      addr <- value TAddr (OAddress vec)
      count <- load TInt addr 8
      out0 <- if null (mapAsLayout k)
        then do unit <- value TVal (ONullary 0 0); value TVal (OCall (hal "Vec.new" 1) [unit])
        else do spec <- value TVal (OString (mapAsLayout k)); value TVal (OCall (hal "Vec.newAs" 1) [spec])
      zero <- constant 0; one <- constant 1
      setup <- label; loop <- label; body <- label; done <- label
      tagIt <- label; rawIt <- label; joined <- label
      resultOut <- fresh TVal
      empty <- value TPred (OCmp Eq count zero)
      end (TCondBr empty done [out0] setup [])
      begin setup []
      cols <- load TAddr addr (8+5*w)
      col0 <- load TAddr cols 0
      base <- load TAddr col0 w
      i <- fresh TInt; out <- fresh TVal
      end (TBr loop [zero,out0])
      begin loop [i,out]
      more <- value TPred (OCmp Lt (fst i) count)
      end (TCondBr more body [] done [fst out])
      begin body []
      effect OSafepoint
      cursor <- value TAddr (OIndex base (fst i))
      end (TCondBr isInt tagIt [] rawIt [])
      begin tagIt []
      raw <- load TInt cursor 0
      tagged <- value TVal (OTag raw)
      end (TBr joined [tagged])
      begin rawIt []
      word <- load TVal cursor 0
      end (TBr joined [word])
      element <- fresh TVal
      begin joined [element]
      mapped <- value TVal (OCall (Callee (mapAsOriginal k) Local (replicate (length args) TVal) TVal) (caps ++ [fst element]))
      out' <- value TVal (OCall (hal "Vec.push" 2) [mapped,fst out])
      i' <- value TInt (OKernelArith Add (fst i) one)
      end (TBr loop [i',out'])
      begin done [resultOut]
      _ <- value TVal (OCall (hal "Vec.free" 1) [vec])
      end (TRet (fst resultOut))
      begin fallback []
      fun <- value TVal (OFunValue (mapAsOriginal k))
      closure <- foldM (\h a -> value TVal (OApply h [a])) fun caps
      spec <- value TVal (OString (mapAsLayout k))
      value TVal (OCall (hal "Vec.mapAs" 3) [spec,closure,vec]) >>= end . TRet
