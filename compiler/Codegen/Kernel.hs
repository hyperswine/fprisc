-- Column kernels are ordinary typed CFGs. No target registers or assembly
-- enter this module. The only memory operations follow descriptor guards;
-- the hosted/loaded-app profiles have non-moving storage across safepoints.
module Codegen.Kernel (Kernel(..), Stage(..), kernelCallbacks, lowerKernel) where

import Codegen.IR
import Codegen.Target.Common (mangleName)
import Codegen.Policy
import Codegen.Verify
import Codegen.Simplify (simplifyFn)
import KernelKinds (Kind(..))
import Control.Monad.State.Strict
import Control.Monad (forM, forM_, unless, foldM)
import qualified Data.Map.Strict as M

-- Capture indices address the original, boxed entry arguments. An optional
-- accumulator also occupies an entry argument, before the vector.
data Stage = Stage String Name [Int] deriving Show
data Kernel = Kernel
  { kernelSymbol :: String, kernelCaptures :: [Kind], kernelElement :: Kind,
    kernelAccumulator :: Maybe (Int, Kind), kernelStages :: [Stage]
  } deriving Show

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
  unless (kernelElement k `elem` [KI,KD] && all (`elem` [KI,KD,KB]) (kernelCaptures k))
    (Left "typed column kernels currently support Int/F64 elements and Int/F64/Bool captures")
  unless (policyWidth policy == W64 || (kernelElement k == KI && all (/= KD) (kernelCaptures k)))
    (Left "RV32 float columns use boxed values")
  unless (not (null stages) && all (\(Stage op _ _) -> op `elem` ["map","filter","fold"]) stages)
    (Left "unsupported typed kernel stages")
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
      want <- constant (if kernelElement k == KI then 1 else 3)
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
      end (TBr loop [zero,zero,acc0])
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
