{-# LANGUAGE LambdaCase #-}
-- Codegen.Allocate: a linear-scan register allocator over the selected
-- stream (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md, milestone M3), replacing
-- M2's conservative placement (Codegen.Place) in the native pipeline.
--
-- The contract it keeps (docs/2026-10-21-NATIVE-IR-CONTRACTS.md, "Scheduler,
-- hart and stack boundary"; docs/2026-10-19-REGISTER-ALLOCATION.md 3.2/3.3):
--
--   * a value that is live across an instruction with a call (a generated
--     call, a C primitive, the fuel tick, the stack check, a slow path's
--     primitive) is in a register of the target's callee-saved budget (the
--     set the scheduler's context switch preserves: x19..x27 on AArch64,
--     rbx and r12..r15 on x86-64) or in a frame slot, never anywhere else;
--     a value that crosses no such point may take a caller-saved register;
--   * no float register is ever allocated (M3 has no float values; the
--     register says the context switch saves none, so a float pool would
--     have to be caller-saved only, which a later milestone decides);
--   * a value never sits in a register an instruction inside its live range
--     names for another purpose (a fixed operand, an implicit use or
--     definition, a clobber); fixed operands are met by copies around the
--     instruction, resolved as parallel copies so staging the arguments of
--     a call or a tail transfer can permute registers safely;
--   * a tied definition (x86-64's two-address forms) is realised by copying
--     the tied use into the destination register first, which is skipped
--     when the use dies there and shares the register;
--   * a spilled value lives in a frame slot for its whole range; two
--     spilled values share a slot only when their ranges do not overlap
--     and the slots agree in size, alignment and managed status (an
--     escaping slot is never shared, Codegen.Frame);
--   * registers of the callee-saved budget that the function uses are
--     reported so the target saves exactly those in its prologue;
--   * a self tail call (a tail transfer to the function's own symbol) is,
--     when the target asks for it, a loop: a parallel copy of the
--     arguments into the parameters, then a jump to a label placed after
--     the stack check and before the fuel tick, so the frame and the saved
--     registers are kept and the tick still runs once per iteration (the
--     legacy FPR_SELF_LOOPS form, docs/2026-10-19-REGISTER-ALLOCATION.md
--     3.4); the entry sequence's two calls keep their declared clobbers.
--
-- The scan is the classic one (Poletto and Sarkar) with an access-count
-- spill choice: intervals in start order, the first free allowed
-- register, otherwise the active interval with the fewest accesses
-- (definitions and uses: what a spill costs in stores and reloads) is
-- evicted to a slot when it has fewer than the new one, else the new one
-- is spilled.  It is an initial allocator: no interval
-- splitting, no use-density weighting, no coalescing beyond the tied and
-- dying-use cases.  Those are named in the M3 page as the next steps.
--
-- `checkAllocation` is the independent oracle: it recomputes liveness over
-- PHYSICAL registers in the output stream and refuses a stream in which a
-- clobbered register is live out of its clobbering instruction, or a
-- register outside the preserved set is live across a call.
module Codegen.Allocate
  ( AllocConfig (..), Allocation (..), Stats (..), Loc (..), Place (..),
    allocateFn, checkAllocation, statsLine, resolveCopies,
  ) where

import Codegen.Frame
import Codegen.Liveness
import Codegen.Selected
import Control.Monad (forM_, unless, when)
import Data.List (foldl', nub, sortOn, (\\))
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S

data Loc = InReg Phys | InSlot FrameRef deriving (Eq, Ord, Show)

data AllocConfig = AllocConfig
  { acCalleeSaved :: [Phys], -- the scheduler-preserved budget, in preference order
    acCallerSaved :: [Phys], -- allocatable caller-saved registers, in preference order
    acScratch :: [Phys], -- never allocated: reloads of spilled operands, dead definitions, copy cycles (at least two)
    acPreserved :: [Phys], -- what survives a call beyond the budget: the frame pointer, the stack pointer, the hart register
    acArrival :: [VReg] -> [SInstr], -- how the parameters arrive: fixed definitions in the argument registers, loads of the cells
    acLoad :: Phys -> FrameRef -> SInstr, -- register <- slot; flag-neutral
    acStore :: Phys -> FrameRef -> SInstr, -- slot <- register; flag-neutral
    acMove :: Phys -> Phys -> SInstr, -- destination <- source; flag-neutral
    acSlot :: Int -> VReg -> FrameObj, -- slot n for a value like v (size, alignment, managed status)
    acEarlyDef :: SInstr -> Bool, -- the expansion may write a definition before it has read every use
    acClassOf :: Phys -> Maybe RegClass,
    acSelfLoop :: Maybe String -- the function's own symbol: a tail transfer to it becomes a loop
  }

data Stats = Stats
  { stValues :: Int, -- virtual registers with a live range
    stInRegister :: Int,
    stSpilled :: Int,
    stSlots :: Int, -- spill slots after sharing
    stReloads :: Int, -- loads of spilled operands
    stSpillStores :: Int, -- stores of spilled definitions
    stCopies :: Int, -- register-to-register moves inserted
    stCrossing :: Int, -- values live across a call
    stLoops :: Int -- self tail calls turned into loops
  }
  deriving (Eq, Show)

statsLine :: Stats -> String
statsLine s =
  "values=" ++ show (stValues s) ++ " regs=" ++ show (stInRegister s) ++ " spills=" ++ show (stSpilled s)
    ++ " slots=" ++ show (stSlots s) ++ " reloads=" ++ show (stReloads s) ++ " stores=" ++ show (stSpillStores s)
    ++ " copies=" ++ show (stCopies s) ++ " crossing=" ++ show (stCrossing s) ++ " loops=" ++ show (stLoops s)

data Allocation = Allocation
  { alBody :: [Item], -- the physical stream: the arrival, the copies, the loads and stores; no virtual operand remains
    alSaved :: [Phys], -- the callee-saved registers used, in budget order
    alSlots :: [FrameObj], -- the spill slots, in creation order
    alLocs :: M.Map VReg Loc, -- where each live value is
    alStats :: Stats
  }

-- a copy's end point
data Place = PR Phys | PS FrameRef deriving (Eq, Ord, Show)

allocateFn :: AllocConfig -> SFn -> Either String Allocation
allocateFn cfg fn = do
  let here = "allocate " ++ sfName fn ++ ": "
  (looped, nloops) <- loopForm cfg here fn
  let stream = map I (acArrival cfg (sfParams fn)) ++ looped
      lv = analyseLiveness stream
      instrs = lvInstrs lv
      byPos = IM.fromList instrs
      ivs = lvIntervals lv
  -- no float values: refused by name rather than placed wrongly
  forM_ instrs $ \(_, i) -> forM_ (instrVRegs i) $ \(v, c) -> case c of
    Any FPR -> Left (here ++ show v ++ ": float registers are not allocated in M3")
    Fix p | acClassOf cfg p == Just FPR -> Left (here ++ show v ++ ": float registers are not allocated in M3")
    _ -> pure ()
  when (length (acScratch cfg) < 2) (Left (here ++ "fewer than two scratch registers"))
  let liveAt p = fromMaybe (IS.empty, IS.empty) (IM.lookup p (lvLive lv))
      vn (VReg n) = n
      -- how v relates to the instruction at p: live across it, born there,
      -- dying there (its last use), or not involved
      isLiveIn v p = IS.member (vn v) (fst (liveAt p))
      isLiveOut v p = IS.member (vn v) (snd (liveAt p))
      definedAt v p = maybe False (\i -> v `elem` instrDefs i) (IM.lookup p byPos)
      usedAt v p = maybe False (\i -> v `elem` instrUses i) (IM.lookup p byPos)
      crosses v p = isLiveIn v p && isLiveOut v p && not (definedAt v p)
      earlyAt p = maybe False (acEarlyDef cfg) (IM.lookup p byPos)
      -- The registers v may not take because of the instruction at p.
      -- Across it: everything the instruction names.  Born there: what
      -- the instruction writes beyond v's own fixed register (its
      -- clobbers are destroyed before the definition exists), plus what it
      -- reads when the expansion may write early.  Dying
      -- there: what the instruction reads implicitly, plus what it writes
      -- when the expansion may write early (the fixed registers of its
      -- other operands are met by the parallel copy before it, and its
      -- clobbers and definitions happen after the reads).
      -- A tied definition is written early too: the parallel copy before
      -- the instruction puts its use into the destination register at the
      -- same moment the fixed operands are staged, so the destination may
      -- not be a register the instruction fixes or reads (x86-64's
      -- variable shift: the result tied to the value, the count fixed in
      -- %rcx; given %rcx, the two copies collided, or, when the value died
      -- in %rcx and the result reused it, the count overwrote the value).
      tiedAt v i = not (null [() | OV d (Tied _) <- siDefs i, d == v])
      forbiddenAt v p i
        | crosses v p = reservedAt i
        | definedAt v p && isLiveOut v p =
            S.fromList
              ( siImplicitDefs i -- not the clobbers: they happen before the definition exists (a call's result is copied out afterwards)
                  ++ [r | OV d (Fix r) <- siDefs i, d /= v] ++ [r | OP r <- siDefs i]
                  ++ (if earlyAt p || tiedAt v i then siImplicitUses i ++ [r | OV _ (Fix r) <- siUses i] ++ [r | OP r <- siUses i] else [])
              )
        | usedAt v p =
            S.fromList
              ( siImplicitUses i ++ [r | OP r <- siUses i]
                  ++ (if earlyAt p then siImplicitDefs i ++ [r | OV _ (Fix r) <- siDefs i] ++ [r | OP r <- siDefs i] else [])
              )
        | otherwise = S.empty
      -- The constraints walk only the reserving instructions (those that
      -- name a physical register) inside the value's interval, grouped by
      -- their reservation set, and stop as soon as a group's whole set is
      -- in: the cost is the number of reserving instructions a range spans,
      -- never the total size of the live sets.
      reserving = [(p, i, r) | (p, i) <- instrs, let r = reservedAt i, not (S.null r)]
      groups = M.toList (M.fromListWith (flip (++)) [(r, [(p, i)]) | (p, i, r) <- reserving])
      within iv = takeWhile ((<= ivEnd iv) . fst) . dropWhile ((< ivStart iv) . fst)
      forbidden v iv = S.unions [collect r (within iv ps) S.empty | (r, ps) <- groups]
        where
          collect _ [] acc = acc
          collect r ((p, i) : rest) acc
            | acc == r = acc
            | otherwise = collect r rest (S.union acc (forbiddenAt v p i))
      callPositions = [(p, i) | (p, i) <- instrs, not (null (siCalls i))]
      clobberPositions = [(p, i) | (p, i) <- instrs, not (null (siClobbers i))]
      crossesCallV v = case M.lookup v ivs of
        Just iv -> any (\(p, _) -> crosses v p) (within iv callPositions)
        Nothing -> False
      crossesClobberV v = case M.lookup v ivs of
        Just iv -> any (\(p, _) -> crosses v p) (within iv clobberPositions)
        Nothing -> False
      prefs v iv =
        let forb = forbidden v iv
            callee = filter (`S.notMember` forb) (acCalleeSaved cfg)
            caller = filter (`S.notMember` forb) (acCallerSaved cfg)
         in if crossesCallV v then callee else if crossesClobberV v then callee ++ caller else caller ++ callee
      tiedOtherUses v p = case IM.lookup p byPos of
        Just i | not (null [() | OV d (Tied _) <- siDefs i, d == v]) ->
          let k = head [k' | OV d (Tied k') <- siDefs i, d == v]
           in [u | (j, OV u _) <- zip [0 :: Int ..] (siUses i), j /= k]
        _ -> []
      order = sortOn (\(v, iv) -> (ivStart iv, ivEnd iv, v)) (M.toList ivs)
      -- the scan
      scan (active, assign) (v, iv) =
        let start = ivStart iv
            live = [a | a@(_, aiv, _) <- active, ivEnd aiv >= start]
            reusable (u, uiv, _) =
              ivEnd uiv == start && even start && definedAt v start
                && not (earlyAt start) && u `notElem` tiedOtherUses v start
            busy = [r | a@(_, _, r) <- live, not (reusable a)]
            -- a value born in a fixed register or dying into one prefers
            -- that register: the copy around the instruction disappears
            hints = [r | Just i <- [IM.lookup start byPos], OV d (Fix r) <- siDefs i, d == v]
              ++ [r | Just i <- [IM.lookup (ivEnd iv) byPos], OV u (Fix r) <- siUses i, u == v]
            allowed0 = filter (`notElem` busy) (prefs v iv)
            cands = filter (`elem` hints) allowed0 ++ filter (`notElem` hints) allowed0
         in case cands of
              (r : _) -> ([a | a@(_, aiv, _) <- live, ivEnd aiv > start || not (reusable a)] ++ [(v, iv, r)], M.insert v (Just r) assign)
              [] ->
                -- evict the cheapest active interval (fewest accesses, then
                -- the furthest end) when it is cheaper than the new one and
                -- holds a register the new one may take; else spill the new one
                let allowed = S.fromList (prefs v iv)
                    cost aiv = length (ivDefs aiv) + length (ivUses aiv)
                    victims = [a | a@(_, aiv, r) <- live, cost aiv < cost iv, S.member r allowed]
                 in case sortOn (\(_, aiv, _) -> (cost aiv, negate (ivEnd aiv))) victims of
                      ((u, _, r) : _) ->
                        ([a | a@(u', _, _) <- live, u' /= u] ++ [(v, iv, r)], M.insert u Nothing (M.insert v (Just r) assign))
                      [] -> (live, M.insert v Nothing assign)
      (_, assigned) = foldl' scan ([], M.empty) order
      spilled = [(v, iv) | (v, iv) <- order, M.lookup v assigned == Just Nothing]
      -- slots: shared when the ranges do not overlap and the objects agree
      -- (size, alignment, managed status; never an escaping one); per
      -- kind, the free slot that was released earliest is taken first
      kindOf o = (foSize o, foAlign o, foManaged o, foEscapes o)
      slotStep (slots, queues, homes) (v, iv) =
        let want = acSlot cfg 0 v
            key = kindOf want
            queue = M.findWithDefault M.empty key queues
         in case M.lookupMin queue of
              Just ((lastEnd, n), o) | lastEnd <= ivStart iv, not (foEscapes o) ->
                let queue' = M.insert (ivEnd iv, n) o (M.delete (lastEnd, n) queue)
                 in (slots, M.insert key queue' queues, M.insert v (foRef o) homes)
              _ ->
                let n = length slots
                    o = (acSlot cfg n v) {foRef = FrameRef n, foKind = SpillSlot n}
                 in (slots ++ [o], M.insert key (M.insert (ivEnd iv, n) o queue) queues, M.insert v (foRef o) homes)
      (slotObjs, _, homes) = foldl' slotStep ([], M.empty, M.empty) spilled
      locOf v = case M.lookup v assigned of
        Just (Just r) -> Just (InReg r)
        Just Nothing -> Just (InSlot (homes M.! v))
        Nothing -> Nothing -- dead: defined, never used
  -- the rewrite, labels kept in place
  let walk _ [] = pure []
      walk p (ILabel l : rest) = (ILabel l :) <$> walk p rest
      walk p (I i : rest) = do
        items <- rewrite cfg here locOf p i
        (items ++) <$> walk (p + 2 :: Int) rest
  body <- walk 0 stream
  let noted n = length [() | I x <- body, siNote x == n]
      stats =
        Stats
          { stValues = M.size ivs,
            stInRegister = length [() | Just (Just _) <- map (`M.lookup` assigned) (M.keys ivs)],
            stSpilled = length spilled,
            stSlots = length slotObjs,
            stReloads = noted "reload",
            stSpillStores = noted "spill",
            stCopies = noted "copy",
            stCrossing = length [() | v <- M.keys ivs, crossesCallV v],
            stLoops = nloops
          }
      saved = [r | r <- acCalleeSaved cfg, Just r `elem` M.elems assigned]
  pure
    Allocation
      { alBody = body,
        alSaved = saved,
        alSlots = slotObjs,
        alLocs = M.fromList [(v, l) | v <- M.keys ivs, Just l <- [locOf v]],
        alStats = stats
      }

-- The loop form of the self tail calls.  A tail transfer whose symbol is
-- the function's own and whose fixed arguments are as many as the
-- parameters becomes a parallel copy into the parameters (a cycle broken
-- with a fresh virtual register) and a jump to the loop label, which sits
-- after the entry block's stack check and before its tick: the frame is
-- constant, so the check runs once; the tick runs once per iteration, as
-- the re-entry did.  The combined entry pseudo is split into its two
-- halves for that, each keeping its implicit definitions and clobbers.
loopForm :: AllocConfig -> String -> SFn -> Either String ([Item], Int)
loopForm cfg here fn = case acSelfLoop cfg of
  Nothing -> pure (sfBody fn, 0)
  Just self
    | null (selfCalls self) -> pure (sfBody fn, 0)
    | otherwise -> do
        when (loopLabel `elem` itemLabels (sfBody fn)) (Left (here ++ "the loop label is already defined"))
        body <- splitEntry (sfBody fn)
        rewritten <- rewriteCalls self [] body
        pure (rewritten, length (selfCalls self))
  where
    loopLabel = Label "m3loop"
    params = sfParams fn
    -- the parameters that arrive through a cell (x86-64's seventh and
    -- eighth): the arrival loads them from a symbol, and the selector
    -- stages the matching arguments of a self call into that symbol just
    -- before the transfer (`store.cell`): those stores carry the arguments
    cells = [(p, sym) | i <- acArrival cfg params, OV p _ <- siDefs i, OS sym <- siUses i]
    nfixed = length params - length cells
    isSelf self i = siOp i == "tailjump" && take 1 (siUses i) == [OS self] && length [() | OV _ (Fix _) <- siUses i] == nfixed
    selfCalls self = [i | I i <- sfBody fn, isSelf self i]
    isCellStore i sym = null (siDefs i) && null (siCalls i) && siControl i == Next && case siUses i of
      [OV _ _, OS s] -> s == sym
      _ -> False
    maxV = maximum (0 : [n | VReg n <- params] ++ [n | I i <- sfBody fn, (VReg n, _) <- instrVRegs i]) + 1
    -- the entry pseudo is the first instruction of the body (after the
    -- entry block's label); the label goes between its halves
    splitEntry items = case break isInstr items of
      (labels, I e : rest)
        | siOp e == "entry.check.tick" ->
            pure (labels ++ [I (half e "entry.check" [c | c <- siCalls e, not (callSafepoint c)]), ILabel loopLabel, I (half e "entry.tick" [c | c <- siCalls e, callSafepoint c])] ++ rest)
        | siOp e == "entry.tick" -> pure (labels ++ [ILabel loopLabel, I e] ++ rest)
        | siOp e == "entry.check" -> pure (labels ++ [I e, ILabel loopLabel] ++ rest)
      _ -> Left (here ++ "a self tail call in a function without an entry sequence")
    isInstr = \case I _ -> True; _ -> False
    half e op calls = e {siOp = op, siCalls = calls}
    vmove d src = (acMove cfg (Phys "") (Phys "")) {siDefs = [OV d (Any GPR)], siUses = [OV src (Any GPR)]}
    -- walk with the items already emitted (reversed) at hand, so a self
    -- call can take back the cell stores just before it
    rewriteCalls _ acc [] = pure (reverse acc)
    rewriteCalls self acc (I i : rest)
      | isSelf self i = do
          let fixedArgs = [v | OV v (Fix _) <- siUses i]
              takeCells [] done = pure ([], done)
              takeCells ((_, sym) : more) done = case done of
                (I st : before) | isCellStore st sym -> do
                  (vs, remaining) <- takeCells more before
                  pure ([v | OV v _ <- siUses st] ++ vs, remaining)
                _ -> Left (here ++ "a self tail call without the staged cell argument " ++ sym)
          (cellArgs, acc1) <- takeCells (reverse cells) acc
          let args = fixedArgs ++ reverse cellArgs
          when (length args /= length params) (Left (here ++ "a self tail call with the wrong number of arguments"))
          let items = map I (parallel (zip params args)) ++ [I ((plain "jump.loop" [] [OL loopLabel]) {siControl = JumpTo loopLabel})]
          rewriteCalls self (reverse items ++ acc1) rest
    rewriteCalls self acc (it : rest) = rewriteCalls self (it : acc) rest
    -- block parameters are assigned in parallel: a cycle is broken with a
    -- fresh virtual register (as the selectors' parallelMoves does)
    parallel = go . filter (uncurry (/=))
      where
        go [] = []
        go ms = case [m | m@(d, _) <- ms, d `notElem` map snd ms] of
          ((d, src) : _) -> vmove d src : go (filter (/= (d, src)) ms)
          [] ->
            let (d, src) = head ms
                t = VReg maxV
             in vmove t src : go ((d, t) : [(d2, if s2 == src then t else s2) | (d2, s2) <- tail ms])

-- one instruction: the copies before it, the instruction over physical
-- registers, the copies after it
rewrite :: AllocConfig -> String -> (VReg -> Maybe Loc) -> Pos -> SInstr -> Either String [Item]
rewrite cfg here locOf _ i = do
  let scratch = acScratch cfg
      earlyDef = acEarlyDef cfg i
      uses = siUses i
      -- the tied definition, if any: its use operand and the destination register
      tied = [(d, k) | OV d (Tied k) <- siDefs i]
  when (length tied > 1) (Left (here ++ siOp i ++ ": two tied definitions"))
  let tiedUse = case tied of
        [(_, k)] -> case uses !! k of
          OV u _ -> Just u
          _ -> Nothing
        _ -> Nothing
      locUse u = case locOf u of
        Just l -> Right l
        Nothing -> Left (here ++ siOp i ++ ": " ++ show u ++ " is used but has no live range")
  -- registers for the spilled uses, the tied destination first
  (rd, scratch1) <- case tied of
    [(d, _)] -> case locOf d of
      Just (InReg r) -> pure (Just r, scratch)
      _ -> case scratch of
        (s : rest) -> pure (Just s, rest)
        [] -> Left (here ++ siOp i ++ ": no scratch register for the tied definition")
    _ -> pure (Nothing, scratch)
  tiedLoc <- maybe (pure Nothing) (fmap Just . locUse) tiedUse
  let step (acc, pool, pre) o = case o of
        OV u c
          | Just u == tiedUse, Just r <- rd -> pure (acc ++ [OP r], pool, pre) -- the tied use travels in the destination
          | otherwise -> do
              l <- locUse u
              case c of
                Fix r -> pure (acc ++ [OP r], pool, pre ++ [(PR r, toPlace l)])
                Any _ -> case l of
                  InReg r -> pure (acc ++ [OP r], pool, pre)
                  InSlot s -> case pool of
                    (sc : rest) -> pure (acc ++ [OP sc], rest, pre ++ [(PR sc, PS s)])
                    [] -> Left (here ++ siOp i ++ ": no scratch register free for a reload")
                Tied _ -> Left (here ++ siOp i ++ ": a tied use operand")
        _ -> pure (acc ++ [o], pool, pre)
  (uses', pool1, pre0) <- foldlM step ([], scratch1, []) uses
  -- the tied destination is written before the instruction reads its
  -- other operands: it may share a register with none of them (checked
  -- here, independently of the scan's constraint and of resolveCopies)
  case (rd, tied) of
    (Just r, [(_, k)]) -> do
      -- an operand that is the tied use's own value travels in the
      -- destination (`x * x`): that sharing is the point, not a collision
      let other j = j /= k && case uses !! j of
            OV u _ -> Just u /= tiedUse
            _ -> True
      when (r `elem` ([q | (j, OP q) <- zip [0 :: Int ..] uses', other j] ++ siImplicitUses i)) $
        Left (here ++ siOp i ++ ": the tied destination " ++ show r ++ " is also another operand's register")
    _ -> pure ()
  -- the tied copy: the use into its destination (a load when spilled)
  let preTied = case (rd, tiedLoc) of
        (Just r, Just l) | toPlace l /= PR r -> [(PR r, toPlace l)]
        _ -> []
      pre = preTied ++ pre0
      useScratch = [s | OP s <- uses', s `elem` scratch] ++ [r | Just r <- [rd], r `elem` scratch]
      defPool = filter (\r -> Just r /= rd) (if earlyDef then scratch \\ useScratch else pool1 ++ (scratch \\ pool1))
  -- definitions
  let dstep (acc, pool, post) o = case o of
        OV d c -> case c of
          Tied _ -> case rd of
            Just r -> pure (acc ++ [OP r], pool, post ++ [(PS s, PR r) | Just (InSlot s) <- [locOf d]])
            Nothing -> Left (here ++ siOp i ++ ": tied without a destination")
          Fix r -> pure (acc ++ [OP r], pool, post ++ case locOf d of
            Just (InReg r') | r' /= r -> [(PR r', PR r)]
            Just (InSlot s) -> [(PS s, PR r)]
            _ -> [])
          Any _ -> case locOf d of
            Just (InReg r) -> pure (acc ++ [OP r], pool, post)
            Just (InSlot s) -> case pool of
              (sc : rest) -> pure (acc ++ [OP sc], rest, post ++ [(PS s, PR sc)])
              [] -> Left (here ++ siOp i ++ ": no scratch register free for a spilled definition")
            Nothing -> case pool of -- dead: written and dropped
              (sc : rest) -> pure (acc ++ [OP sc], rest, post)
              [] -> Left (here ++ siOp i ++ ": no scratch register free for a dead definition")
        _ -> pure (acc ++ [o], pool, post)
  (defs', _, post) <- foldlM dstep ([], defPool, []) (siDefs i)
  preItems <- resolveCopies cfg here pre
  postItems <- resolveCopies cfg here post
  -- an instruction that leaves the function defines nothing (checked in M2 placement too)
  case siControl i of
    Return | not (null post) -> Left (here ++ siOp i ++ ": a return or tail transfer defines a value")
    _ -> pure ()
  unless (all neutral (preItems ++ postItems)) (Left (here ++ "a copy changes flags, control flow or calls"))
  let placed = i {siDefs = defs', siUses = uses'}
      -- a selected move whose two sides share a register (the source dies
      -- there) is nothing
      identity = case (siDefs placed, siUses placed) of
        ([OP d], [OP s']) -> d == s' && siOp placed == siOp (acMove cfg d s') && siFlags placed == FlagsNone && null (siCalls placed) && siControl placed == Next
        _ -> False
  pure (map I preItems ++ [I placed | not identity] ++ map I postItems)
  where
    toPlace = \case InReg r -> PR r; InSlot s -> PS s
    neutral x = siFlags x == FlagsNone && siControl x == Next && null (siCalls x)
    foldlM f z xs = foldl' (\m x -> m >>= \acc -> f acc x) (Right z) xs

-- parallel copies: stores first (their sources are read before any
-- register is written), then register destinations in an order where a
-- destination is not a pending source, cycles broken through a scratch
-- register that is neither a source nor a destination
resolveCopies :: AllocConfig -> String -> [(Place, Place)] -> Either String [SInstr]
resolveCopies cfg here raw = do
  let moves = nub [m | m@(d, s) <- raw, d /= s]
      dests = map fst moves
  when (length (nub dests) /= length dests) (Left (here ++ "two copies into one place"))
  forM_ moves $ \case
    (PS _, PS _) -> Left (here ++ "a slot-to-slot copy")
    _ -> pure ()
  let stores = [(acStore cfg r s) {siNote = "spill"} | (PS s, PR r) <- moves]
      regMoves = [(d, s) | (PR d, s) <- moves]
  rest <- schedule regMoves
  pure (stores ++ rest)
  where
    schedule [] = pure []
    schedule pending =
      let sources = [s | (_, PR s) <- pending]
       in case [m | m@(d, _) <- pending, d `notElem` sources] of
            (m@(d, s) : _) -> (emit d s :) <$> schedule (filter (/= m) pending)
            [] ->
              -- every destination is a source: a cycle (sources are all registers)
              let (_, s) = head pending
                  used = S.fromList ([d' | (d', _) <- pending] ++ sources)
               in case [t | t <- acScratch cfg, S.notMember t used] of
                    (t : _) -> case s of
                      PR sr ->
                        let pending' = [(d', if s' == PR sr then PR t else s') | (d', s') <- pending]
                         in (emit t (PR sr) :) <$> schedule pending'
                      PS _ -> Left (here ++ "internal: a slot in a copy cycle")
                    [] -> Left (here ++ "no scratch register free to break a copy cycle")
    emit d (PR s) = (acMove cfg d s) {siNote = "copy"}
    emit d (PS s) = (acLoad cfg d s) {siNote = "reload"}

-- The independent oracle over the physical stream: liveness of physical
-- registers, then (1) no clobbered register is live out of the
-- instruction that clobbers it, (2) nothing outside the preserved set is
-- live across an instruction with a call, (3) no float register is live
-- across a call.  The arrival's registers are the function's live-in set
-- and are expected; a register live into the function that no instruction
-- defines is reported unless it is preserved (the hart register, sp, fp).
checkAllocation :: AllocConfig -> String -> [Item] -> Either String ()
checkAllocation cfg name items = do
  let key = M.fromList (zip regs [0 ..])
      regs = nub ([p | I i <- items, p <- physOf i] ++ acPreserved cfg ++ acCalleeSaved cfg)
      physOf i = [p | OP p <- siDefs i ++ siUses i] ++ siImplicitDefs i ++ siImplicitUses i ++ siClobbers i
      k p = key M.! p
      usesOf i = map k ([p | OP p <- siUses i] ++ siImplicitUses i)
      defsOf i = map k ([p | OP p <- siDefs i] ++ siImplicitDefs i ++ siClobbers i)
      sets = instrLiveSets usesOf defsOf items
      preserved = IS.fromList (map k (acCalleeSaved cfg ++ acPreserved cfg))
      name' p = head [r | (r, n) <- M.toList key, n == p]
  forM_ (zip [0 :: Int ..] sets) $ \(n, (i, _, out)) -> do
    let where' = "checkAllocation " ++ name ++ " #" ++ show n ++ " " ++ siOp i ++ ": "
    forM_ (siClobbers i) $ \p -> when (IS.member (k p) out && not (any (\o -> o == OP p) (siDefs i))) $
      Left (where' ++ show p ++ " is clobbered and live afterwards")
    unless (null (siCalls i)) $ do
      let across = [p | p <- IS.toList out, IS.notMember p (IS.fromList (defsOf i)), IS.notMember p preserved]
      unless (null across) $ Left (where' ++ "live across a call outside the preserved set: " ++ show (map name' across))
      let floats = [p | p <- IS.toList out, acClassOf cfg (name' p) == Just FPR]
      unless (null floats) $ Left (where' ++ "a float register is live across a call")
  -- registers live into the function: the arrival's and the preserved ones only
  case sets of
    ((_, inn, _) : _) -> do
      let arrival = IS.fromList [k p | I i <- take 1 items, OP p <- siDefs i]
          stray = [name' p | p <- IS.toList inn, IS.notMember p preserved, IS.notMember p arrival]
      unless (null stray) $ Left ("checkAllocation " ++ name ++ ": read before written: " ++ show stray)
    [] -> pure ()
