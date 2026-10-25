-- M3's liveness and allocation (docs/2026-10-2N-TYPED-IR-M3.md) on a
-- synthetic target small enough to force every case by hand: a budget of
-- two callee-saved registers (s1, s2), two caller-saved ones (c1, c2),
-- two scratch registers (t1, t2), two argument registers (a0, a1) that a
-- call clobbers with the rest, a stack pointer, one float register.
--
-- The checks: live ranges over block parameters, a loop and a call point;
-- values across a call take the budget, the overflow spills; spill slots
-- are shared only across disjoint ranges with the same managed status;
-- fixed operands are staged by a parallel copy (a swap goes through the
-- scratch); a tied definition copies its use unless the use dies there;
-- a dead definition stores nothing; float operands are refused by name;
-- the post-allocation oracle refuses a stream with a caller-saved
-- register live across a call; the output is deterministic.  A symbolic
-- simulator of the physical stream (registers hold the names of the values
-- they carry) is the independent check that every value reaches the
-- register the instruction fixed it to and survives the calls between.
-- Run: cabal exec -- runghc -w -icompiler tests/AllocIR.hs
import Codegen.Allocate
import Codegen.Frame
import Codegen.Liveness
import qualified Codegen.Call as Call
import qualified Codegen.Calling as Calling
import Codegen.Selected
import qualified Codegen.Opcode as Opcode
import qualified Codegen.Annotation as Annotation
import Control.Monad (unless, forM_)
import Data.List (isInfixOf, sort)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M
import qualified Data.Set as S

check :: String -> Bool -> IO ()
check name yes = unless yes (error ("FAIL: " ++ name))

refused :: String -> String -> Either String a -> IO ()
refused name needle r = case r of
  Left msg | needle `isInfixOf` msg -> pure ()
  Left msg -> error ("FAIL: " ++ name ++ ": refused for another reason: " ++ msg)
  Right _ -> error ("FAIL: " ++ name ++ ": accepted")

r :: String -> Phys
r = Phys

s1, s2, c1, c2, t1, t2, a0, a1, sp, f0 :: Phys
[s1, s2, c1, c2, t1, t2, a0, a1, sp, f0] = map r ["s1", "s2", "c1", "c2", "t1", "t2", "a0", "a1", "sp", "f0"]

classOf :: Phys -> Maybe RegClass
classOf p
  | p == f0 = Just FPR
  | p `elem` [s1, s2, c1, c2, t1, t2, a0, a1, sp] = Just GPR
  | otherwise = Nothing

v :: Int -> VReg
v = VReg

gpr :: Int -> Operand
gpr n = OV (v n) (Any GPR)

clobbered :: [Phys]
clobbered = [c1, c2, t1, t2, a0, a1]

cfg :: S.Set VReg -> AllocConfig
cfg managed =
  AllocConfig
    { acCalleeSaved = [s1, s2],
      acCallerSaved = [c1, c2, a0, a1], -- the argument registers are allocatable too, as on the real targets
      acScratch = [t1, t2],
      acPreserved = [sp],
      acArrival = \ps -> [plain "params" (zipWith (\p q -> OV p (Fix q)) ps [a0, a1]) []],
      acLoad = \p ref -> plain "ld" [OP p] [OF ref 0],
      acStore = \p ref -> plain "st" [] [OP p, OF ref 0],
      acMove = \d s -> plain "mv" [OP d] [OP s],
      acSlot = \n x -> frameObj n 8 8 (SpillSlot n) (S.member x managed),
      acEarlyDef = const False,
      acClassOf = classOf,
      acSelfLoop = Nothing
    }

plainCfg :: AllocConfig
plainCfg = cfg S.empty

-- the test vocabulary
add :: Int -> Int -> Int -> SInstr
add d a b = plain "add" [gpr d] [gpr a, gpr b]

addTied :: Int -> Int -> Int -> SInstr
addTied d a b = plain "addt" [OV (v d) (Tied 0)] [gpr a, gpr b]

-- x86-64's variable shift: the result tied to the value, the count fixed
-- (here in c1, the first caller-saved register the scan prefers)
shiftTied :: Int -> Int -> Int -> SInstr
shiftTied d a b = plain "shl" [OV (v d) (Tied 0)] [gpr a, OV (v b) (Fix c1)]

call :: String -> [Int] -> Int -> SInstr
call f args d =
  (plain "call" [OV (v d) (Fix a0)] (OCode (CodeSymbol f) : zipWith (\x p -> OV (v x) (Fix p)) args [a0, a1]))
    {siClobbers = filter (/= a0) clobbered, siCalls = [Call (CodeSymbol f) (CalleeEntry Calling.TicksFuel)], siFlags = FlagsDef}

ret :: Int -> SInstr
ret x = (plain "ret" [] [OV (v x) (Fix a0)]) {siControl = Return}

jump :: String -> SInstr
jump l = (plain "jump" [] [OL (Label l)]) {siControl = JumpTo (Label l)}

-- the entry sequence and a self tail transfer, as the targets shape them
entry :: SInstr
entry = (plain "entry.check.tick" [] []) {siAnnotation=EntryLabels (Label "allocator-entry"),siImplicitDefs = [t1], siClobbers = clobbered, siFlags = FlagsDef, siCalls = [Call.runtimeEvent Call.GrowStackEntry, Call.runtimeEvent Call.FuelEntry]}

tailSelf :: [Int] -> SInstr
tailSelf args = (plain "tailjump" [] (OCode (CodeSymbol "fpr_fn_probe") : zipWith (\x p -> OV (v x) (Fix p)) args [a0, a1])) {siClobbers = clobbered, siControl = Return, siCalls = [Call (CodeSymbol "fpr_fn_probe") (CalleeEntry Calling.TicksFuel)]}

branchz :: Int -> String -> SInstr
branchz x l = (plain "bz" [] [gpr x, OL (Label l)]) {siControl = CondTo [Label l]}

mv :: Int -> Int -> SInstr
mv d s = plain "mv" [gpr d] [gpr s]

fn :: [VReg] -> [Item] -> SFn
fn = SFn "probe"

-- The symbolic simulator: registers and slots hold the names of the
-- values they carry; a virtual value is named by its operation over the
-- names it read; every physical operand register is checked against the
-- virtual value the instruction expected there (fixed or not), a call
-- destroys its clobbers afterwards, and the return's register must hold
-- the returned value.  Only straight-line streams are simulated.
simulate :: SFn -> [Item] -> Either String ()
simulate original physical = step (M.fromList [(a0, "v0"), (a1, "v1")]) M.empty (M.fromList [(v 0, "v0"), (v 1, "v1")]) physInstrs virtualInstrs
  where
    physInstrs = [i | I i <- physical]
    virtualInstrs = [i | I i <- sfBody original]
    -- the physical stream has copies between the original instructions:
    -- each original instruction is paired with its physical twin by operation
    step _ _ _ [] _ = Right ()
    step regs slots venv (p : ps) vs
      | siOp p == "mv", [OP d] <- siDefs p, [OP s] <- siUses p = step (M.insert d (reg s) regs) slots venv ps vs
      | siOp p == "ld", [OP d] <- siDefs p, [OF ref 0] <- siUses p = step (M.insert d (M.findWithDefault "<empty slot>" ref slots) regs) slots venv ps vs
      | siOp p == "st", [OP s, OF ref 0] <- siUses p = step regs (M.insert ref (reg s) slots) venv ps vs
      | siOp p == "params" = step regs slots venv ps vs -- the arrival is the allocator's, not in the virtual stream
      | otherwise = case vs of
          [] -> Left ("simulate: a physical instruction without a virtual twin: " ++ siOp p)
          (vi : vs') -> do
            unless (siOp vi == siOp p) (Left ("simulate: " ++ siOp p ++ " does not match " ++ siOp vi))
            forM_ (zip (siUses vi) (siUses p)) $ \(vo, po) -> case (vo, po) of
              (OV x _, OP q) -> unless (reg q == venv M.! x) (Left ("simulate: " ++ siOp p ++ " expected " ++ venv M.! x ++ " in " ++ show q ++ ", found " ++ reg q))
              _ -> pure ()
            let value = siOp p ++ "(" ++ unwords [case o of OV x _ -> venv M.! x; OCode s -> codeName s; _ -> "?" | o <- siUses vi] ++ ")"
                venv' = foldr (\o m -> case o of OV d _ -> M.insert d value m; _ -> m) venv (siDefs vi)
                regs1 = foldr (\q m -> M.insert q "<junk>" m) regs (siClobbers p ++ siImplicitDefs p)
                regs2 = foldr (\o m -> case o of OP q -> M.insert q value m; _ -> m) regs1 (siDefs p)
            step regs2 slots venv' ps vs'
      where
        reg q = M.findWithDefault "<undefined>" q regs

physicalLines :: Allocation -> [String]
physicalLines a = [siOp i ++ " " ++ unwords (map show (siDefs i)) ++ " <- " ++ unwords (map show (siUses i)) | I i <- alBody a]

main :: IO ()
main = do
  -- liveness on a loop with a block parameter and a call inside
  let loopFn =
        fn [v 0, v 1]
          [ I (mv 2 0), I (jump "loop"),
            ILabel (Label "loop"),
            I (branchz 2 "out"),
            I (call "f" [1] 3),
            I (add 4 2 3),
            I (mv 2 4),
            I (jump "loop"),
            ILabel (Label "out"),
            I (ret 2) ]
      stream = map I (acArrival plainCfg [v 0, v 1]) ++ sfBody loopFn
      lv = analyseLiveness stream
      iv n = lvIntervals lv M.! v n
      blocks = lvBlocks lv
  -- a conditional transfer ends a block: entry, the loop's test, its body, out
  check "four blocks: entry, test, body, out" (length blocks == 4 && sbSuccs (blocks !! 0) == [1] && sort (sbSuccs (blocks !! 1)) == [2, 3] && sbSuccs (blocks !! 2) == [1] && sbSuccs (blocks !! 3) == [])
  check "a parameter used only in the loop is live from its arrival to the loop's back edge" (ivStart (iv 1) == 0 && ivEnd (iv 1) == 2 * 7 + 1)
  check "the loop variable is defined twice and live around the loop" (length (ivDefs (iv 2)) == 2 && ivStart (iv 2) == 2 && ivEnd (iv 2) == 2 * 8)
  check "the call result lives from the call to the add" (ivStart (iv 3) == 2 * 4 && ivEnd (iv 3) == 2 * 5)
  let (inn, out) = lvLive lv IM.! (2 * 4)
  check "at the call: the parameter and the loop variable are live in and out, the result only out" (IS.member 1 inn && IS.member 2 inn && IS.member 1 out && IS.member 2 out && IS.member 3 out && not (IS.member 3 inn))
  al <- either (error . ("FAIL: loop: " ++)) pure (allocateFn plainCfg loopFn)
  check "the two values across the call take the budget, nothing spills" (sort (alSaved al) == [s1, s2] && stSpilled (alStats al) == 0 && stCrossing (alStats al) == 2)
  either (error . ("FAIL: loop oracle: " ++)) pure (checkAllocation plainCfg "loop" (alBody al))
  -- pressure: three values across a call with a budget of two
  let pressure =
        fn [v 0, v 1]
          [ I (add 2 0 1), I (add 3 0 2), I (add 4 1 2),
            I (call "g" [0] 5),
            I (add 6 2 3), I (add 7 6 4), I (add 8 7 5),
            I (ret 8) ]
  pa <- either (error . ("FAIL: pressure: " ++)) pure (allocateFn plainCfg pressure)
  check "one of the three crossing values spills to one slot" (stSpilled (alStats pa) == 1 && stSlots (alStats pa) == 1 && stCrossing (alStats pa) == 3 && length (alSlots pa) == 1)
  check "the spilled value is stored once and reloaded once" (stSpillStores (alStats pa) == 1 && stReloads (alStats pa) == 1)
  either (error . ("FAIL: pressure oracle: " ++)) pure (checkAllocation plainCfg "pressure" (alBody pa))
  either (error . ("FAIL: pressure simulation: " ++)) pure (simulate pressure (alBody pa))
  -- slot sharing: two spilled values with disjoint ranges share a slot
  let twoCalls =
        fn [v 0, v 1]
          [ I (add 2 0 1), I (add 3 0 2), I (add 4 1 2),
            I (call "g" [0] 5),
            I (add 6 2 3), I (add 7 6 4), I (add 8 7 5),
            I (add 9 8 0), I (add 10 9 1), I (add 11 10 8),
            I (call "h" [8] 12),
            I (add 13 9 10), I (add 14 13 11), I (add 15 14 12),
            I (ret 15) ]
  ta <- either (error . ("FAIL: two calls: " ++)) pure (allocateFn plainCfg twoCalls)
  -- both parameters are used after the first call too, so five values
  -- cross it and three spill; after the second call one more spills and
  -- takes the slot the first one released
  check "spills share slots across disjoint ranges" (stSpilled (alStats ta) == 4 && stSlots (alStats ta) == 3)
  either (error . ("FAIL: two-call simulation (the shared slot must never mix the two values): " ++)) pure (simulate twoCalls (alBody ta))
  tm <- either (error . ("FAIL: managed: " ++)) pure (allocateFn (cfg (S.fromList [v 2, v 3, v 4])) twoCalls)
  check "a managed and an unmanaged value never share a slot" (stSpilled (alStats tm) == 4 && stSlots (alStats tm) == 4 && length (filter foManaged (alSlots tm)) == 3)
  -- fixed operands: a swap of the two argument registers goes through the scratch
  let swap = fn [v 0, v 1] [I (call "g" [1, 0] 2), I (ret 2)]
  sa <- either (error . ("FAIL: swap: " ++)) pure (allocateFn plainCfg swap)
  either (error . ("FAIL: swap simulation (the swapped arguments must arrive in the right registers): " ++)) pure (simulate swap (alBody sa))
  check "the parameters stay in their arrival registers (the hint), so the staging is a two-cycle through a scratch register" (stCopies (alStats sa) == 3 && stValues (alStats sa) == 3)
  -- the parallel-copy resolver itself: a two-cycle and a three-cycle go
  -- through a scratch register, a chain does not, and a register move
  -- never overwrites a pending source
  let moves ms = either (error . ("FAIL: copies: " ++)) pure (resolveCopies plainCfg "copies" ms)
      apply regs i = case (siOp i, siDefs i, siUses i) of
        ("mv", [OP d], [OP s]) -> M.insert d (M.findWithDefault "?" s regs) regs
        _ -> error "copies: not a move"
      start = M.fromList [(a0, "A"), (a1, "B"), (c1, "C")]
  two <- moves [(PR a0, PR a1), (PR a1, PR a0)]
  check "a two-cycle swaps through a scratch register" (length two == 3 && M.toList (M.restrictKeys (foldl apply start two) (S.fromList [a0, a1])) == [(a0, "B"), (a1, "A")])
  three <- moves [(PR a0, PR a1), (PR a1, PR c1), (PR c1, PR a0)]
  check "a three-cycle rotates through a scratch register" (length three == 4 && M.toList (M.restrictKeys (foldl apply start three) (S.fromList [a0, a1, c1])) == [(a0, "B"), (a1, "C"), (c1, "A")])
  chain <- moves [(PR c2, PR a0), (PR a0, PR a1)]
  check "a chain is ordered without a scratch register" (length chain == 2 && M.toList (M.restrictKeys (foldl apply start chain) (S.fromList [a0, c2])) == [(a0, "B"), (c2, "A")])
  refused "two copies into one register" "two copies into one place" (resolveCopies plainCfg "copies" [(PR a0, PR a1), (PR a0, PR c1)])
  -- tied definitions: a copy unless the use dies there
  let tiedLive = fn [v 0, v 1] [I (addTied 2 0 1), I (add 3 2 0), I (ret 3)]
      tiedDies = fn [v 0, v 1] [I (addTied 2 0 1), I (add 3 2 1), I (ret 3)]
  tl <- either (error . ("FAIL: tied live: " ++)) pure (allocateFn plainCfg tiedLive)
  td <- either (error . ("FAIL: tied dies: " ++)) pure (allocateFn plainCfg tiedDies)
  either (error . ("FAIL: tied simulation (a tied use that lives on must be copied first and survive): " ++)) pure (simulate tiedLive (alBody tl))
  either (error . ("FAIL: tied-dies simulation: " ++)) pure (simulate tiedDies (alBody td))
  check "a tied use that lives on is copied first" (stCopies (alStats tl) >= 1)
  let tiedInstr a = head [i | I i <- alBody a, siOp i == "addt"]
  check "a tied use that dies shares the destination register: no copy" (case (siDefs (tiedInstr td), siUses (tiedInstr td)) of ([OP d], [OP s, _]) -> d == s; _ -> False)
  -- a dead definition: nothing is stored, nothing is saved for it
  let dead = fn [v 0, v 1] [I (add 2 0 1), I (add 3 1 1), I (ret 2)]
  da <- either (error . ("FAIL: dead: " ++)) pure (allocateFn plainCfg dead)
  check "a dead definition has no range, no slot and no store" (stValues (alStats da) == 3 && stSpillStores (alStats da) == 0 && M.notMember (v 3) (alLocs da))
  -- A supplied FP bank may carry a value across a call; word and FP
  -- classes remain separate, and the physical oracle checks preservation.
  let fpCfg = plainCfg {acCalleeSaved=f0:acCalleeSaved plainCfg}
      fpFn = fn [] [I (plain "fconst" [OV (v 0) (Any FPR)] []),
                    I ((plain "call" [] [OCode (CodeSymbol "g")]) {siClobbers=clobbered,siCalls=[Call (CodeSymbol "g") (CalleeEntry Calling.TicksFuel)]}),
                    I (plain "bits" [gpr 1] [OV (v 0) (Any FPR)]), I (ret 1)]
  fpa <- either error pure (allocateFn fpCfg fpFn)
  check "FP values across calls use the supplied preserved bank" (M.lookup (v 0) (alLocs fpa)==Just (InReg f0))
  either error pure (checkAllocation fpCfg "fp" (alBody fpa))
  -- refusals
  refused "a float operand" "float registers are not allocated" (allocateFn plainCfg (fn [v 0, v 1] [I (plain "fadd" [OV (v 2) (Any FPR)] [OV (v 0) (Any FPR)]), I (ret 2)]))
  refused "the oracle: a caller-saved register live across a call"
    "live across a call outside the preserved set"
    (checkAllocation plainCfg "bad" [I (plain "params" [OP a0, OP a1] []), I (plain "mv" [OP c1] [OP a1]), I ((plain "call" [OP a0] [OCode (CodeSymbol "g"), OP a0]) {siClobbers = [c2, t1, t2, a1], siCalls = [Call (CodeSymbol "g") (CalleeEntry Calling.TicksFuel)]}), I (plain "add" [OP a0] [OP a0, OP c1]), I ((plain "ret" [] [OP a0]) {siControl = Return})])
  refused "the oracle: a clobbered register read afterwards"
    "clobbered and live afterwards"
    (checkAllocation plainCfg "bad2" [I (plain "params" [OP a0, OP a1] []), I ((plain "call" [OP a0] [OCode (CodeSymbol "g"), OP a0]) {siClobbers = filter (/= a0) clobbered, siCalls = [Call (CodeSymbol "g") (CalleeEntry Calling.TicksFuel)]}), I (plain "add" [OP a0] [OP a0, OP a1]), I ((plain "ret" [] [OP a0]) {siControl = Return})])
  -- the loop form: a self tail call that swaps its two parameters becomes
  -- copies into the parameters' registers and a jump to the label between
  -- the stack check and the tick; both parameters live around the loop,
  -- so they take the budget; without the switch the transfer stays
  let swapLoop = fn [v 0, v 1] [ILabel (Label "b0"), I entry, I (branchz 0 "out"), I (add 2 0 1), I (tailSelf [1, 2]), ILabel (Label "out"), I (ret 1)]
      loopCfg = plainCfg {acSelfLoop = Just (CodeSymbol "fpr_fn_probe")}
  la <- either (error . ("FAIL: loop form: " ++)) pure (allocateFn loopCfg swapLoop)
  let ops = [siOp i | I i <- alBody la]
  check "the transfer became copies and a jump to the loop label" (stLoops (alStats la) == 1 && "jump.loop" `elem` ops && "tailjump" `notElem` ops && Label "m3loop" `elem` itemLabels (alBody la))
  check "the entry sequence is split around the loop label" (ops !! 1 == "entry.check" && ops !! 2 == "entry.tick" || take 3 (dropWhile (/= "entry.check") ops) == ["entry.check", "entry.tick", "bz"])
  check "both parameters hold the budget around the loop" (sort (alSaved la) == [s1, s2] && stSpilled (alStats la) == 0)
  either (error . ("FAIL: loop form oracle: " ++)) pure (checkAllocation loopCfg "loop form" (alBody la))
  let entryParts=[i | I i<-alBody la,siOp i `elem` ["entry.check","entry.tick"]]
  check "self-loop splitting preserves typed entry ownership with disjoint internal labels"
    (map siAnnotation entryParts==replicate 2 (EntryLabels (Label "allocator-entry"))
      && Annotation.checkAnnotations Annotation.AlwaysRestores "split-entry" (map I entryParts)==Right ())
  forM_ ["copy","reload","spill"] $ \spelling->do
    let renamed=swapLoop {sfBody=map (\item->case item of
          I i | siOpcode i==Opcode.Common Opcode.EntryCheckTick->I i {siAnnotation=EntryLabels (Label spelling)}
          _->item) (sfBody swapLoop)}
    annotated<-either error pure (allocateFn loopCfg renamed)
    check ("entry spelling cannot forge allocator statistics: "++spelling)
      (alStats annotated==alStats la)
  na <- either (error . ("FAIL: no loop form: " ++)) pure (allocateFn plainCfg swapLoop)
  check "without the switch the self tail call stays a transfer" (stLoops (alStats na) == 0 && "tailjump" `elem` [siOp i | I i <- alBody na])
  let indexedCfg = loopCfg {acArrival = \ps ->
        plain "params" (zipWith (\p q -> OV p (Fix q)) (take 2 ps) [a0,a1]) [] :
        [plain "load.spill" [OV p (Any GPR)] [OI n] | (p,n) <- zip (drop 2 ps) [0..]]}
      cell n x = I (plain "store.spill" [] [gpr x,OI n])
      indexedLoop = fn (map v [0..3])
        [I entry,I (branchz 0 "done"),cell 0 3,cell 1 2,I (tailSelf [1,0]),ILabel (Label "done"),I (ret 0)]
  ia <- either (error . ("FAIL: indexed-cell loop: "++)) pure (allocateFn indexedCfg indexedLoop)
  check "indexed hart cells participate in a self loop" (stLoops (alStats ia)==1 && "store.spill" `notElem` [siOp i|I i<-alBody ia])
  either (error . ("FAIL: indexed-cell loop oracle: "++)) pure (checkAllocation indexedCfg "indexed-cell loop" (alBody ia))
  refused "missing staged indexed argument" "staged cell argument"
    (allocateFn indexedCfg indexedLoop {sfBody=filter (/=cell 1 2) (sfBody indexedLoop)})
  -- determinism
  pb <- either (error . ("FAIL: pressure again: " ++)) pure (allocateFn plainCfg pressure)
  check "allocation is deterministic" (alBody pa == alBody pb && alSaved pa == alSaved pb)
  -- a tied definition never takes a register its instruction fixes for
  -- another operand: the result would be c1 (the first preference), the
  -- count is fixed in c1; with the value dying there too, the result
  -- reusing the value's register would let the count overwrite the value
  let shiftLive = fn [v 0, v 1] [I (shiftTied 2 0 1), I (add 3 2 0), I (ret 3)]
      shiftDies = fn [v 0, v 1] [I (add 4 0 1), I (shiftTied 2 4 1), I (add 3 2 1), I (ret 3)]
      shiftOf a = head [i | I i <- alBody a, siOp i == "shl"]
  forM_ [("value lives on", shiftLive), ("value dies there", shiftDies)] $ \(what, f) -> do
    a <- either (error . (("FAIL: tied shift (" ++ what ++ "): ") ++)) pure (allocateFn plainCfg f)
    either (error . (("FAIL: tied shift simulation (" ++ what ++ "): ") ++)) pure (simulate f (alBody a))
    check ("a tied shift's destination is not its fixed count's register (" ++ what ++ ")")
      (case (siDefs (shiftOf a), siUses (shiftOf a)) of ([OP d], [OP x, OP c]) -> d /= c1 && c == c1 && d == x; _ -> False)
    either (error . (("FAIL: tied shift oracle (" ++ what ++ "): ") ++)) pure (checkAllocation plainCfg "shift" (alBody a))
  putStrLn "AllocIR: live ranges over block parameters, loops and calls; budget, spills and shared slots; staged fixed operands through a swap; tied copies; a tied destination never on a fixed operand's register; dead definitions; float refusal; the physical-liveness oracle; determinism: PASS"
