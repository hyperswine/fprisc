-- Expose lowered self-tail branches to CFG optimizers. The external entry
-- keeps the stack check and first fuel tick; each back edge keeps its tick
-- after argument evaluation. As in Allocate.loopForm, the frame is constant
-- and needs no repeated stack-growth check. This is a lowering decision,
-- before the evaluator/simplifier boundary, not a tick-removing optimization.
module Codegen.LoopForm (formSelfLoop) where

import Codegen.IR
import Codegen.Policy
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- Only the canonical entry and direct unconditional self-tail branches
-- produced by Lower are admitted. Mutual recursion, indirect transfers and
-- unusual entry edges retain the existing backend path.
formSelfLoop :: Policy -> Fn -> Fn
formSelfLoop policy fn
  | not (polEarlyLoops policy) = fn
  | [entry] <- [b | b <- blocks, bId b == fnEntry fn]
  , not (null backs)
  , all directEntryEdge blocks
  , take (length prefix) (bInstrs entry) == prefix
  , all (\(Instr _ op) -> op /= OStackCheck) (drop (length prefix) (bInstrs entry))
  = let params = bParams entry
        arrivals = zipWith (\n (_,t) -> (VId n,t)) [nextV..] params
        -- A parameter passed unchanged on EVERY back edge is its arrival
        -- value on every iteration. Keep it outside the carried tuple so
        -- invariant motion can see the defining block dominate the loop.
        invariant = [all (\b -> case bTerm b of TBr _ args -> args !! i == v; _ -> False) backs
                    | (i,(v,_)) <- zip [0..] params]
        aliases = M.fromList [(v,a) | ((v,_),(a,_),True) <- zip3 params arrivals invariant]
        rename v = M.findWithDefault v v aliases
        carried xs = [x | (x,False) <- zip xs invariant]
        pre = Block (BId nextB) arrivals prefix (TBr (fnEntry fn) (carried (map fst arrivals)))
        rewrite b =
          let self = case bTerm b of TBr target _ -> target == fnEntry fn; _ -> False
              ops = if bId b == fnEntry fn then drop (length prefix) (bInstrs b) else bInstrs b
              term = case bTerm b of
                TBr target args | self -> TBr target (carried args)
                other -> other
          in b { bParams = if bId b == fnEntry fn then carried (bParams b) else bParams b,
                 bInstrs = [Instr d (mapOpUses rename op) | Instr d op <- ops ++ [Instr Nothing OSafepoint | self && polFuel policy]],
                 bTerm = mapTermUses rename term }
    in fn {fnEntry = bId pre, fnBlocks = pre : map rewrite blocks}
  | otherwise = fn
  where
    blocks = fnBlocks fn
    entryArity = length (concat [bParams e | e <- blocks, bId e == fnEntry fn])
    prefix = [Instr Nothing OStackCheck | polStackCheck policy /= StackStatic]
          ++ [Instr Nothing OSafepoint | polFuel policy]
    backs = [b | b <- blocks, TBr target args <- [bTerm b], target == fnEntry fn,
                 length args == entryArity]
    backIds = S.fromList (map bId backs)
    directEntryEdge b = case bTerm b of
      TBr target _ | target == fnEntry fn -> S.member (bId b) backIds
      t -> all ((/= fnEntry fn) . fst) (termSuccs t)
    nextB = 1 + maximum (0 : [n | b <- blocks, BId n <- [bId b]])
    nextV = 1 + maximum (0 : [n | b <- blocks, (VId n,_) <- bParams b]
                          ++ [n | b <- blocks, Instr (Just (VId n,_)) _ <- bInstrs b])
