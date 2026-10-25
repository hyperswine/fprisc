-- The selected-instruction vocabulary of M2 (docs/2026-10-21-TYPED-IR-M2-A64.md):
-- the constraint model carries x86-64's needs from its first commit, so
-- these shapes are written in it here, before any x86-64 selection exists:
-- tied two-address arithmetic, the fixed division registers, the shift
-- count in %rcx, the %rax result against the %rdi first argument at a
-- call, the call-alignment pseudo and the a6/a7 TLS argument cells.  The
-- validity rules refuse each malformation by name, conservative placement
-- honours the constraints, the bound analysis finds the missing safepoint,
-- and the AArch64 pipeline runs end to end on a hand-written function.
-- Run: cabal exec -- runghc -w -icompiler tests/SelectedIR.hs
import Codegen.Bounds
import Codegen.Frame
import Codegen.IR
import Codegen.Place
import Codegen.Policy (m2Policy, StackPolicy (..), Policy (..), Profile (..))
import Codegen.Target.Common (shallowEntry, noTune, shrinkWrap)
import qualified Codegen.Opcode as Opcode
import qualified Codegen.Opcode.A64 as AOp
import qualified Codegen.Opcode.RV as ROp
import qualified Codegen.Target.A64.Forms as AForms
import qualified Codegen.Target.RV.Forms as RForms
import Codegen.Target.X64.Forms (checkForms)
import Codegen.Selected
import qualified Codegen.Annotation as Annotation
import qualified Codegen.Target.X64 as X64
import Codegen.Target.A64
import Control.Monad (unless, forM_)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

check :: String -> Bool -> IO ()
check name yes = unless yes (error ("FAIL: " ++ name))

refused :: String -> String -> Either String a -> IO ()
refused name needle r = case r of
  Left msg | needle `isInfixOf` msg -> pure ()
  Left msg -> error ("FAIL: " ++ name ++ ": refused for another reason: " ++ msg)
  Right _ -> error ("FAIL: " ++ name ++ ": accepted")

-- the x86-64 register file as a backend would declare it
x64 :: RegisterFile
x64 = RegisterFile classOf [Phys "rsp", Phys "rbp"]
  where
    gprs = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp"] ++ ["r" ++ show n | n <- [8 .. 15 :: Int]]
    classOf (Phys r)
      | r `elem` gprs = Just GPR
      | "xmm" `isPrefixOf` r = Just FPR
      | otherwise = Nothing

r :: String -> Phys
r = Phys

v :: Int -> VReg
v = VReg

gpr :: Int -> Operand
gpr n = OV (v n) (Any GPR)

sysvClobbers :: [Phys]
sysvClobbers = map r ["rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"]

fn :: [Item] -> SFn
fn = SFn "probe" [v 0, v 1]

-- two-address arithmetic: the destination is the first use's register
tiedAdd :: SInstr
tiedAdd = (plain "addq" [OV (v 2) (Tied 0)] [gpr 0, gpr 1]) {siFlags = FlagsDef}

-- idivq: the dividend in rax (rdx holds its sign extension), the quotient
-- in rax and the remainder in rdx, the divisor anywhere else
idiv :: SInstr
idiv = (plain "idivq" [OV (v 3) (Fix (r "rax")), OV (v 4) (Fix (r "rdx"))] [OV (v 0) (Fix (r "rax")), gpr 1])
  {siImplicitUses = [r "rdx"], siFlags = FlagsDef}

-- shlq %cl, %reg: the count in rcx, the value tied
shl :: SInstr
shl = (plain "shlq" [OV (v 5) (Tied 0)] [gpr 0, OV (v 1) (Fix (r "rcx"))]) {siFlags = FlagsDef}

-- a generated call: first argument in rdi, result in rax, the SysV
-- caller-saved set destroyed, the callee's entry ticks
callF :: SInstr
callF = (plain "call" [OV (v 6) (Fix (r "rax"))] [OS "fpr_fn_f", OV (v 0) (Fix (r "rdi")), OV (v 1) (Fix (r "rsi"))])
  {siClobbers = sysvClobbers, siFlags = FlagsDef, siCalls = [Call "fpr_fn_f" True False]}

-- the stack alignment around a call and the a6/a7 cells of a wide call
align :: SInstr
align = (plain "x64.callalign" [] []) {siImplicitDefs = [r "rsp"]}

storeA6 :: SInstr
storeA6 = plain "x64.store.cell" [] [gpr 0, OS "fpr_x64_a6"]

main :: IO ()
main = do
  let nativeTick=(plainOpcode (Opcode.Common Opcode.EntryTick) [] [])
        {siAnnotation=EntryLabels (Label "annotation-entry"),siFlags=FlagsDef,
         siCalls=[Call "fpr_fuel_exhausted" True False]}
      annotations=Annotation.checkAnnotations Annotation.AlwaysRestores "annotation-test"
      save=(plainOpcode (Opcode.A64 AOp.Save) [] []) {siAnnotation=SaveGroup 0}
      move=(plainOpcode (Opcode.A64 AOp.Move) [OP (Phys "x19")] [OP (Phys "x0")])
        {siAllocation=Just RegisterCopy}
      reload=(plainOpcode (Opcode.A64 AOp.FrameLoad) [OP (Phys "x19")] [OF (FrameRef 0) 0])
        {siAllocation=Just Reload}
  check "typed entry labels and allocator events satisfy native contracts"
    (checkForms "annotation-test" [I nativeTick]==Right ()
      && AForms.checkForms a64RegisterFile "annotation-test" [I move,I reload,I save]==Right ())
  refused "entry labels are required by native entry expansion" "annotation does not match"
    (checkForms "annotation-test" [I nativeTick {siAnnotation=NoAnnotation}])
  refused "entry labels cannot annotate ordinary computation" "annotation does not match"
    (AForms.checkForms a64RegisterFile "annotation-test" [I move {siAnnotation=EntryLabels (Label "copy")}])
  refused "implicit entry labels cannot capture a local block label" "captures or duplicates"
    (annotations [I nativeTick,ILabel (Label "annotation-entry_fuel")])
  refused "entry expansions cannot share a fuel label" "captures or duplicates"
    (annotations [I nativeTick,I nativeTick])
  refused "native save operations require a typed group index" "annotation does not match"
    (AForms.checkForms a64RegisterFile "annotation-test" [I save {siAnnotation=NoAnnotation}])
  refused "save group must belong to the actual frame" "outside this frame"
    (Annotation.checkSaveGroups "annotation-test" 1 [I save {siAnnotation=SaveGroup 1}])
  check "save group resolves within the checked frame"
    (Annotation.checkSaveGroups "annotation-test" 1 [I save]==Right ())
  refused "allocator reload accounting cannot attach to a copy" "allocation event"
    (AForms.checkForms a64RegisterFile "annotation-test" [I move {siAllocation=Just Reload}])
  refused "allocator events require physical operands" "allocation event"
    (AForms.checkForms a64RegisterFile "annotation-test" [I move {siDefs=[gpr 0]}])
  refused "an always-restore backend cannot inherit a shrink-wrap exit marker" "annotation does not match"
    (checkForms "annotation-test" [I ((plainOpcode (Opcode.X64 Opcode.Ret) [] [OP (Phys "rax")])
      {siControl=Return,siAnnotation=SkipRestores})])
  let aOp op=plainOpcode (Opcode.A64 op)
      aFloat=(aOp (AOp.FloatBinary Opcode.FloatRegisters Opcode.Float64 FAdd)
        [OV (v 2) (Any FPR)] [OV (v 0) (Any FPR),OV (v 1) (Any FPR)])
      aBranch=(aOp (AOp.Branch Opcode.UnsignedBelow) [] [OL (Label "out")])
        {siFlags=FlagsUse,siControl=CondTo [Label "out"]}
      aForms=AForms.checkForms a64RegisterFile "forms"
      rvFile=RegisterFile (\(Phys p)->if p `elem` ["a0","a1","a2"] then Just GPR else Nothing) []
      rvOp op=plainOpcode (Opcode.RV op)
      rvAdd=rvOp ROp.Add [gpr 2] [gpr 0,gpr 1]
      rvForms=RForms.checkForms rvFile "forms"
  check "A64 word/FP boundaries and RV typed operations accept correct banks"
    (aForms [I aFloat,I aBranch]==Right () && rvForms [I rvAdd]==Right ())
  refused "A64 pooled arithmetic cannot receive a word operand" "register bank"
    (aForms [I aFloat {siUses=[gpr 0,OV (v 1) (Any FPR)]}])
  refused "A64 branch metadata preserves its target" "control effect"
    (aForms [I aBranch {siControl=Next}])
  refused "A64 entry metadata cannot lose its fuel event" "call metadata"
    (aForms [I ((plainOpcode (Opcode.Common Opcode.EntryTick) [] []) {siAnnotation=EntryLabels (Label "a64-tick"),siFlags=FlagsDef})])
  refused "A64 cannot render synthetic text" "opcode/operand"
    (aForms [I (plain "mov" [gpr 2] [gpr 0])])
  refused "A64 cannot render another ISA's instruction" "opcode/operand"
    (aForms [I rvAdd])
  refused "RV cannot render synthetic text" "opcode/operand"
    (rvForms [I (plain "mv" [gpr 2] [gpr 0])])
  refused "RV cannot render another ISA's instruction" "opcode/operand"
    (rvForms [I aFloat])
  refused "RV has no condition flag bank" "condition flags"
    (rvForms [I rvAdd {siFlags=FlagsDef}])
  refused "RV load operands cannot lose their offset" "opcode/operand"
    (rvForms [I (rvOp ROp.Load32 [gpr 2] [gpr 0])])
  refused "RV float tree nodes remain within scratch registers" "opcode/operand"
    (rvForms [I (rvOp (ROp.TreeNode Opcode.Float32 FAdd) [] [OI 7])])
  refused "RV call result must arrive in a0" "register bank"
    (rvForms [I ((rvOp ROp.Call [OV (v 2) (Fix (Phys "a1"))] [OS "callee"])
      {siCalls=[Call "callee" False True]})])
  refused "x64 cannot render an A64 operation" "opcode/operand"
    (checkForms "forms" [I aFloat])
  let typedMove=plainOpcode (Opcode.X64 Opcode.Move) [gpr 2] [gpr 0]
      typedCompare=plainOpcode (Opcode.X64 (Opcode.FloatCompare Opcode.Float32 Ne)) [gpr 2] [gpr 0,gpr 1]
      typedBranch=(plainOpcode (Opcode.X64 (Opcode.Branch Opcode.UnsignedBelow)) [] [OL (Label "typed-out")])
        {siFlags=FlagsUse,siControl=CondTo [Label "typed-out"]}
  check "x64 constructors retain explicit width, predicate and branch condition"
    (checkForms "typed" [I typedMove,I typedCompare {siFlags=FlagsDef},I typedBranch]==Right ())
  refused "x64 rejects the transitional mnemonic vocabulary" "opcode/operand form"
    (checkForms "typed" [I (plain "movq" [gpr 2] [gpr 0])])
  refused "x64 catches a selected operand-count mismatch" "opcode/operand form"
    (checkForms "typed" [I typedMove {siUses=[]}])
  refused "x64 catches a selected operand-kind mismatch" "opcode/operand form"
    (checkForms "typed" [I typedMove {siUses=[OI 0]}])
  refused "x64 float comparison retains its flag effect" "flag effect"
    (checkForms "typed" [I typedCompare])
  refused "x64 branch labels agree with control metadata" "control effect"
    (checkForms "typed" [I typedBranch {siControl=Next}])
  refused "x64 scratch tree indices remain inside the physical bank" "opcode/operand form"
    (checkForms "typed" [I (plainOpcode (Opcode.X64 (Opcode.TreeLeaf Opcode.Float64)) [] [gpr 0,OI 8])])
  let typedDivide=(plainOpcode (Opcode.X64 Opcode.Divide) [OV (v 2) (Fix (r "rax"))]
        [OV (v 0) (Fix (r "rax")),gpr 1]) {siImplicitDefs=[r "rdx"],siFlags=FlagsDef}
      typedAdd=(plainOpcode (Opcode.X64 Opcode.Add) [OV (v 2) (Tied 0)] [gpr 0,gpr 1]) {siFlags=FlagsDef}
  check "x64 division and two-address contracts accept their real constraints"
    (checkForms "typed" [I typedDivide,I typedAdd]==Right ())
  refused "x64 division requires its fixed dividend/result bank" "register constraint"
    (checkForms "typed" [I typedDivide {siDefs=[gpr 2]}])
  refused "x64 division declares its hidden remainder register" "register constraint"
    (checkForms "typed" [I typedDivide {siImplicitDefs=[]}])
  refused "x64 arithmetic cannot lose its two-address tie" "register constraint"
    (checkForms "typed" [I typedAdd {siDefs=[gpr 2]}])
  refused "x64 call metadata cannot silently disappear from bound accounting" "call metadata"
    (checkForms "typed" [I ((plainOpcode (Opcode.X64 Opcode.Call) [] [OS "target"]) {siFlags=FlagsDef})])
  let typedEntry=I ((plainOpcode (Opcode.Common Opcode.EntryCheckTick) [] [])
        {siAnnotation=EntryLabels (Label "typed-entry"),siFlags=FlagsDef,siCalls=[Call "fpr_stack_grow" False True,Call "fpr_fuel_exhausted" True False]})
  check "shared shallow-entry rewriting retains the typed opcode"
    (case shallowEntry StackCheckLegacyShallow 32 [typedEntry] of
      (True,[I i])->siOpcode i==Opcode.Common Opcode.EntryTick && checkForms "typed" [I i]==Right ()
      _->False)
  let entry = I ((plain "entry.check.tick" [] []) {siCalls = [Call "fpr_stack_grow" False True, Call "fpr_fuel_exhausted" True False]})
      callItem = I callF
      tailItem = I callF {siControl = Return}
      shallow = shallowEntry StackCheckLegacyShallow
  check "shallow keeps the fuel event" (case shallow 1024 [entry] of
    (True, [I i]) -> siOp i == "entry.tick" && map callTarget (siCalls i) == ["fpr_fuel_exhausted"]
    _ -> False)
  check "shallow rejects a large frame" (shallow 1040 [entry] == (False, [entry]))
  check "shallow keeps generated and generic call checks" (shallow 32 [entry, callItem] == (False, [entry, callItem]))
  let apply = I callF {siCalls = [Call "fpr_applyN" False True]}
  check "generic apply without a bound reset still keeps its check" (shallow 32 [entry, apply] == (False, [entry, apply]))
  check "shallow admits a tail exit" (fst (shallow 32 [entry, tailItem]))
  check "every-entry policy stays exact" (shallowEntry StackCheckEveryEntry 32 [entry] == (False, [entry]))
  let good = fn [I tiedAdd, I idiv, I shl, I align, I storeA6, I callF, ILabel (Label "out"), I ((plain "jmp" [] [OL (Label "out")]) {siControl = JumpTo (Label "out")})]
  check "the x86-64 shapes are valid" (checkFn x64 good == Right ())
  refused "tied to a missing operand" "does not exist" (checkFn x64 (fn [I (plain "addq" [OV (v 2) (Tied 5)] [gpr 0])]))
  refused "tied to an immediate" "not a virtual register" (checkFn x64 (fn [I (plain "addq" [OV (v 2) (Tied 1)] [gpr 0, OI 1])]))
  refused "tied across classes" "different classes" (checkFn x64 (fn [I (plain "addsd" [OV (v 2) (Tied 0)] [OV (v 1) (Any FPR)]), I (plain "movq" [OV (v 2) (Any GPR)] [gpr 0])]))
  refused "a tied use" "a use operand is tied" (checkFn x64 (fn [I (plain "addq" [] [OV (v 0) (Tied 0)])]))
  refused "fixed to the stack pointer" "reserved" (checkFn x64 (fn [I (plain "movq" [OV (v 2) (Fix (r "rsp"))] [gpr 0])]))
  refused "fixed to a register that is not one" "not a register" (checkFn x64 (fn [I (plain "movq" [OV (v 2) (Fix (r "x9"))] [gpr 0])]))
  refused "a result both defined and clobbered" "clobbers it" (checkFn x64 (fn [I callF {siClobbers = r "rax" : sysvClobbers}]))
  refused "a call without clobbers" "without clobbers" (checkFn x64 (fn [I callF {siClobbers = []}]))
  refused "two uses fixed to one register" "two uses fix" (checkFn x64 (fn [I idiv {siUses = [OV (v 0) (Fix (r "rax")), OV (v 1) (Fix (r "rax"))]}]))
  refused "a branch to an undefined label" "undefined label" (checkFn x64 (fn [I ((plain "je" [] [OL (Label "nowhere")]) {siControl = CondTo [Label "nowhere"]})]))
  refused "a value never defined" "never defined" (checkFn x64 (fn [I (plain "movq" [gpr 2] [gpr 7])]))
  refused "a fixed use never defined" "never defined" (checkFn x64 (fn [I (plain "movq" [gpr 2] [OV (v 7) (Fix (r "rax"))])]))
  refused "one value in two classes" "two register classes" (checkFn x64 (fn [I (plain "movq" [gpr 2] [gpr 0]), I (plain "movsd" [OV (v 2) (Any FPR)] [OV (v 1) (Any FPR)])]))
  refused "a label defined twice" "defined twice" (checkFn x64 (fn [ILabel (Label "l"), ILabel (Label "l")]))
  -- conservative placement under the x86-64 constraints
  let pl = Placement
        { plScratch = \c -> if c == GPR then [r "r10", r "r11", r "rbx"] else [r "xmm1"],
          plLoad = \p ref -> plain "load" [OP p] [OF ref 0],
          plStore = \p ref -> plain "store" [] [OP p, OF ref 0],
          plSlot = \(VReg n) -> frameObj n 8 8 (SpillSlot n) False }
  (placed, objs) <- either (error . ("FAIL: placement: " ++)) pure (placeInSlots pl (fn [I tiedAdd, I idiv, I shl, I callF]))
  let instrs = [i | I i <- sfBody placed]
      ops = map siOp instrs
      noVirtual = null [() | i <- instrs, (_, _) <- instrVRegs i]
  check "placement leaves no virtual operand" noVirtual
  check "every virtual register has one slot" (length objs == 7 && length (S.fromList (map foRef objs)) == 7)
  check "a use is loaded before and a definition stored after" (take 4 ops == ["load", "load", "addq", "store"])
  let [addq] = [i | i <- instrs, siOp i == "addq"]
  check "a tied definition reuses its use's register" (case (siDefs addq, siUses addq) of ([OP d], OP a : _) -> d == a; _ -> False)
  let [idivq] = [i | i <- instrs, siOp i == "idivq"]
  check "fixed operands take their registers" (siDefs idivq == [OP (r "rax"), OP (r "rdx")] && head (siUses idivq) == OP (r "rax"))
  check "a scratch register never collides with a fixed or implicit one" (siUses idivq !! 1 `elem` [OP (r "r10"), OP (r "r11"), OP (r "rbx")])
  let [shlq] = [i | i <- instrs, siOp i == "shlq"]
  check "the shift count is loaded into rcx" (siUses shlq !! 1 == OP (r "rcx") && siDefs shlq == [head (siUses shlq)])
  let [callq] = [i | i <- instrs, siOp i == "call"]
  check "the call's arguments are in rdi and rsi, its result in rax" (siUses callq == [OS "fpr_fn_f", OP (r "rdi"), OP (r "rsi")] && siDefs callq == [OP (r "rax")])
  refused "placement runs out of scratch" "no scratch register" (placeInSlots pl {plScratch = const []} (fn [I tiedAdd]))
  refused "flag-clobbering slot loads" "slot transfer changes flags"
    (placeInSlots pl {plLoad = \p ref -> (plain "badload" [OP p] [OF ref 0]) {siFlags = FlagsDef}} (fn [I tiedAdd]))
  refused "flag-clobbering slot stores" "slot transfer changes flags"
    (placeInSlots pl {plStore = \p ref -> (plain "badstore" [] [OP p, OF ref 0]) {siFlags = FlagsDef}} (fn [I tiedAdd]))
  -- frame layout: the legacy shape, 16-aligned, objects below the link area
  let ly = layout 16 16 [frameObj 0 8 8 (SpillSlot 0) True, frameObj 1 8 8 (SpillSlot 1) True, frameObj 2 8 8 (SpillSlot 2) False]
  check "slots follow the link area downward" (M.toList (lyOffset ly) == [(FrameRef 0, -24), (FrameRef 1, -32), (FrameRef 2, -40)])
  check "the frame is a multiple of 16" (lyBytes ly == 48)
  -- the bound: a loop without a safepoint is UNBOUNDED, with one it is finite
  let ins c f rs cc = TIns c f rs cc
      loopNoTick = [TLabel "top", ins 3 FNext False 0, ins 1 (FJump "top") False 0]
      loopTick = [TLabel "top", ins 3 FNext False 0, ins 9 FNext True 1, ins 1 (FJump "top") False 0]
      straight = [ins 2 FNext False 0, ins 5 FNext True 0, ins 4 FNext False 1, ins 1 FExit False 0]
  check "a cycle without a safepoint is UNBOUNDED" (rSegMax (analyse loopNoTick) == Nothing)
  check "a cycle through a safepoint is bounded by its length" (rSegMax (analyse loopTick) == Just 13 && rCCalls (analyse loopTick) == 1)
  check "a straight function: the entry run and the exit tail" (analyse straight == Report (Just 7) (Just 5) 1)
  let bypassTick = [TLabel "top", ins 1 (FCond ["top"]) False 0, ins 9 FNext True 1, ins 1 FExit False 0]
      forkTick = [ins 1 (FCond ["out"]) False 0, ins 5 FNext True 0,
                  TLabel "out", ins 4 FNext False 0, ins 1 FExit False 0]
  check "a conditional back-edge before a reset is UNBOUNDED" (rSegMax (analyse bypassTick) == Nothing)
  check "a conditional exit bypassing a reset retains its exit tail" (analyse forkTick == Report (Just 6) (Just 6) 0)
  check "an undefined bound target is not silently dropped" (rSegMax (analyse [ins 1 (FJump "missing") False 0]) == Nothing)
  check "duplicate bound labels are refused" (rSegMax (analyse [TLabel "same", TLabel "same"]) == Nothing)
  -- the AArch64 pipeline end to end on a hand-written IR function:
  -- one (n) = n < 2 ? n : n - 1, with the entry sequence
  let one = Fn "one" ["n"] TVal (BId 0)
        [ Block (BId 0) [(VId 0, TVal)]
            [ Instr Nothing OStackCheck, Instr Nothing OSafepoint,
              Instr (Just (VId 1, TInt)) (OUntag (VId 0)),
              Instr (Just (VId 2, TInt)) (OConstInt 2),
              Instr (Just (VId 3, TPred)) (OCmp Lt (VId 1) (VId 2)) ]
            (TCondBr (VId 3) (BId 1) [] (BId 2) []),
          Block (BId 1) [] [] (TRet (VId 0)),
          Block (BId 2) []
            [ Instr (Just (VId 4, TInt)) (OConstInt 1),
              Instr (Just (VId 5, TInt)) (OArith Sub (VId 1) (VId 4)),
              Instr (Just (VId 6, TVal)) (OTag (VId 5)) ]
            (TRet (VId 6)) ]
      cfg = A64Config MachO HartX28 m2Policy (S.singleton "one") False True False noTune
  refused "A64 cannot consume RV32 policy" "64-bit word policy" (emitFnA64 cfg {cfgPolicy = m2Policy {polProfile = Rv32}} one)
  refused "X64 cannot consume RV32 policy" "64-bit word policy" (X64.emitFnX64 (X64.X64Config (m2Policy {polProfile = Rv32}) S.empty False True False noTune X64.HartTls) one)
  nf <- either (error . ("FAIL: a64: " ++)) pure (emitFnA64 cfg one)
  let text = unlines (nfLines nf)
      has s = s `isInfixOf` text
  check "the function is exported under its generated symbol" (has ".globl _fpr_fn_one" && has "_fpr_fn_one:")
  check "the parameter is moved to a saved register before the entry calls (M3)" (has "stur x19, [x29, #-24]\n    mov x19, x0\n" && has "bl _fpr_stack_grow" && has "bl _fpr_fuel_exhausted")
  check "the saved register comes back before every return" (length (filter (== "    ldur x19, [x29, #-24]") (lines text)) == 2 && has "saved=x19 ")
  check "the hart is read from x28" (has "mov x9, x28")
  check "the subtraction's slow path re-enters the primitive with retagged operands, tagged straight into the argument registers" (has "bl _fpr_prim_fn__x2d" && has "orr x0, x9, #1\n" && has "orr x1, x9, #1\n    bl _fpr_prim_fn__x2d")
  check "the result is tagged straight into x0 before the epilogue" (has "orr x0, x9, #1\n    ldur x19, [x29, #-24]\n")
  check "the epilogue restores sp from the frame pointer" (has "ldur x29, [x29, #-16]\n    mov sp, x9\n    ret")
  check "the bound is finite and named native-insns-v1" (rSegMax (nfReport nf) /= Nothing && has "# native-insns-v1: one segmax=")
  let elf = A64Config ELF HartTlsElf m2Policy S.empty False True False noTune
  nfe <- either (error . ("FAIL: a64 elf: " ++)) pure (emitFnA64 elf one)
  check "ELF syntax: no underscore, local-exec TLS" ("bl fpr_stack_grow" `isInfixOf` unlines (nfLines nfe) && "tprel_hi12:fpr_posix_hart" `isInfixOf` unlines (nfLines nfe))
  let tlv = A64Config MachO HartTlvMachO m2Policy S.empty False True False noTune
  nft <- either (error . ("FAIL: a64 tlv: " ++)) pure (emitFnA64 tlv one)
  check "Mach-O TLV: the descriptor call saves x0 and x30 around it" ("stp x0, x30, [sp]" `isInfixOf` unlines (nfLines nft) && "_fpr_posix_hart@TLVPPAGE" `isInfixOf` unlines (nfLines nft))
  -- a loaded QOS app (docs/2026-10-22-TYPED-IR-QOS.md): its profile is
  -- admitted, and qa64single reads the global hart cell (ELF and Mach-O)
  let qos = m2Policy {polProfile = QosApp}
  nfq <- either (error . ("FAIL: a64 qos: " ++)) pure (emitFnA64 (A64Config ELF HartX28 qos S.empty False True False noTune) one)
  check "QOS app: x28 is the hart" ("mov x9, x28" `isInfixOf` unlines (nfLines nfq))
  nfg <- either (error . ("FAIL: a64 qos single: " ++)) pure (emitFnA64 (A64Config ELF HartGlobal qos S.empty False True False noTune) one)
  check "QOS single: the global hart cell, ELF" ("adrp x9, fpr_posix_hart\n    ldr x9, [x9, #:lo12:fpr_posix_hart]" `isInfixOf` unlines (nfLines nfg))
  nfgm <- either (error . ("FAIL: a64 qos single mach-o: " ++)) pure (emitFnA64 (A64Config MachO HartGlobal qos S.empty False True False noTune) one)
  check "QOS single: the global hart cell, Mach-O" ("adrp x9, _fpr_posix_hart@PAGE\n    ldr x9, [x9, _fpr_posix_hart@PAGEOFF]" `isInfixOf` unlines (nfLines nfgm))
  refused "a QOS app without fuel is refused" "without fuel" (emitFnA64 (A64Config ELF HartX28 (qos {polFuel = False}) S.empty False True False noTune) one)
  nfx <- either (error . ("FAIL: x64: " ++)) pure (X64.emitFnX64 (X64.X64Config m2Policy (S.singleton "one") False True False noTune X64.HartTls) one)
  nfqx <- either (error . ("FAIL: qx64: " ++)) pure (X64.emitFnX64 (X64.X64Config qos S.empty False True False noTune X64.HartBorrow) one)
  check "QOS x64: borrowed hart, no app TLS" ("movq fpr_g_tlsoff(%rip), %r10\n    movq %fs:0(%r10), %r10" `isInfixOf` unlines (nfLines nfqx) && not ("@tpoff" `isInfixOf` unlines (nfLines nfqx)))
  let xt = unlines (nfLines nfx)
  check "direct x64: SysV parameter moved to rbx, rbx saved, TLS hart" ("movq %rbx, -24(%rbp)\n    movq %rdi, %rbx\n" `isInfixOf` xt && "%fs:fpr_posix_hart@tpoff" `isInfixOf` xt && "saved=rbx " `isInfixOf` xt)
  check "direct x64: aligned primitive call" ("subq $8, %rsp\n    call fpr_prim_fn__x2d\n    addq $8, %rsp" `isInfixOf` xt)
  check "direct x64: frame-based return and native bound" ("leaq -8(%r11), %rsp\n    ret" `isInfixOf` xt && rSegMax (nfReport nfx) /= Nothing)
  let pairFn n = Fn "pair" ["base"] TVal (BId 0)
        [Block (BId 0) [(VId 0,TAddr)]
          [Instr Nothing OStackCheck, Instr Nothing OSafepoint,
           Instr Nothing (OSimdPair False (iterate (\e -> SFloat FAdd e SLane) SLane !! n) [] (VId 0)),
           Instr (Just (VId 1,TVal)) (ONullary 0 0)] (TRet (VId 1))]
      pairCfg = X64.X64Config m2Policy S.empty False True False noTune X64.HartTls
  pair7 <- either error pure (X64.emitFnX64 pairCfg (pairFn 7))
  check "SSE2 pair uses its last reserved temporary" ("addpd %xmm8, %xmm15" `isInfixOf` unlines (nfLines pair7))
  refused "SSE2 pair exceeds reserved bank" "seven scratch temporaries" (X64.emitFnX64 pairCfg (pairFn 8))
  let wrapper = Fn "wrapper" ["a", "b"] TVal (BId 0)
        [Block (BId 0) [(VId 0, TVal), (VId 1, TVal)]
          [Instr Nothing OStackCheck, Instr Nothing OSafepoint]
          (TTailCall (Callee "callee" Imported [TVal, TVal] TVal) [VId 1, VId 0])]
  fw <- either error pure (emitFnA64 cfg {cfgForwardParams = True} wrapper)
  fx <- either error pure (X64.emitFnX64 (X64.X64Config m2Policy S.empty False True True noTune X64.HartTls) wrapper)
  forM_ [("a64", fw), ("x64", fx)] $ \(target, result) -> do
    let asm = unlines (nfLines result)
    check (target ++ " forwarding needs no callee-save parking") ("forward=yes saved=none" `isInfixOf` asm)
    check (target ++ " forwarding retains both slow calls") ("fpr_stack_grow" `isInfixOf` asm && "fpr_fuel_exhausted" `isInfixOf` asm)
    check (target ++ " forwarding keeps its native bound") (rSegMax (nfReport result) /= Nothing)
  -- X64 keeps its explicit frame refusal; growable A64 entries now reserve
  -- their complete frame. Neither may silently overflow the headroom.
  -- 4200 values live at once (every constant is consumed only after all
  -- are defined): more than the budget and the caller-saved pool, so they
  -- spill to 4200 distinct slots, beyond the 32768-byte ceiling
  let wide = Fn "wide" [] TVal (BId 0)
        [ Block (BId 0) []
            ([Instr Nothing OStackCheck, Instr Nothing OSafepoint]
              ++ [Instr (Just (VId n, TInt)) (OConstInt (fromIntegral n)) | n <- [0 .. 4199]]
              ++ [Instr (Just (VId (4200 + n), TVal)) (OTag (VId n)) | n <- [0 .. 4199]])
            (TRet (VId 8399)) ]
  wideX64 <- either (error . ("FAIL: sized x64 frame: " ++)) pure
    (X64.emitFnX64 (X64.X64Config m2Policy S.empty False True False noTune X64.HartTls) wide)
  check "sized x64 frame reserves before entry" ("reserve=yes" `isInfixOf` unlines (nfLines wideX64) &&
    "call fpr_stack_reserve" `isInfixOf` unlines (nfLines wideX64) && rSegMax (nfReport wideX64) /= Nothing)
  wideA64 <- either (error . ("FAIL: sized A64 frame: " ++)) pure (emitFnA64 cfg wide)
  check "sized A64 frame reserves before entry" ("reserve=yes" `isInfixOf` unlines (nfLines wideA64) &&
    "bl _fpr_stack_reserve" `isInfixOf` unlines (nfLines wideA64) && rSegMax (nfReport wideA64) /= Nothing)
  let staticWide = wide {fnBlocks = [b {bInstrs = drop 2 (bInstrs b)} | b <- fnBlocks wide]}
      staticCfg = cfg {cfgPolicy = m2Policy {polProfile=Builtin,polFuel=False,polStackCheck=StackStatic}}
  refused "A64 builtin profile remains RISC-V-only" "builtin native lowering requires RISC-V" (emitFnA64 staticCfg staticWide)
  forM_ [("one", nf)] $ \(n, f) -> check ("no legacy bound label on " ++ n) (not ("# wcet:" `isInfixOf` unlines (nfLines f)))
  -- FPR_TYPED_IR_SHRINK_WRAP (docs/2026-10-22-TYPED-IR-FIB.md) on hand-built
  -- physical streams: s1 is a saved register
  let s1 = Phys "x19"
      op o ds us = plain o (map OP ds) (map OP us)
      ret' = (plain "ret" [] [OP (Phys "x0")]) {siControl = Return}
      br l = (plain "bz" [] [OP (Phys "x0"), OL (Label l)]) {siControl = CondTo [Label l]}
      jmp l = (plain "jump" [] [OL (Label l)]) {siControl = JumpTo (Label l)}
      callS = (op "call" [] []) {siCalls = [Call "f" True False]}
      notes xs = [(siOp i, siAnnotation i) | I i <- xs]
      -- entry branches: the leaf returns at once, the other arm uses s1 around a call
      arms = [ I (op "entry" [] []), I (br "leaf"),
               I (op "mv" [s1] [Phys "x0"]), I callS, I (op "mv" [Phys "x0"] [s1]), I ret',
               ILabel (Label "leaf"), I ret' ]
  case shrinkWrap [s1] arms of
    Just wrapped -> do
      check "the saves move to the arm that uses the register"
        (take 3 (map fst (notes wrapped)) == ["entry", "bz", "saves.here"])
      check "only the returns that arm dominates restore"
        ([n | (o, n) <- notes wrapped, o == "ret"] == [NoAnnotation, SkipRestores])
    Nothing -> error "FAIL: shrink-wrap declined the two-arm stream"
  check "a register used in the entry block keeps the prologue saves"
    (shrinkWrap [s1] (I (op "mv" [s1] [Phys "x0"]) : arms) == Nothing)
  check "a save point on a cycle is refused"
    (shrinkWrap [s1] [ I (op "entry" [] []), I (br "out"), ILabel (Label "loop"), I (op "mv" [s1] [Phys "x0"]), I callS,
                       I (br "out"), I (jmp "loop"), ILabel (Label "out"), I ret' ] == Nothing)
  check "an exit the save point does not dominate is refused"
    (shrinkWrap [s1] [ I (op "entry" [] []), I (br "join"), I (op "mv" [s1] [Phys "x0"]), I callS,
                       ILabel (Label "join"), I ret' ] == Nothing)
  check "no saved register, no change" (shrinkWrap [] arms == Nothing)
  putStrLn "SelectedIR: x86-64 constraints and refusals, flag-neutral placement, frame layout, conditional-path bounds, A64 pipeline (Mach-O x28, ELF TLS, Mach-O TLV), direct x64 pipeline, sized A64 frames and explicit profile/x64 limits, shrink-wrap placement and refusals: PASS"
