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
import Codegen.Policy (m2Policy)
import Codegen.Selected
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
      cfg = A64Config MachO HartX28 m2Policy (S.singleton "one") False
  nf <- either (error . ("FAIL: a64: " ++)) pure (emitFnA64 cfg one)
  let text = unlines (nfLines nf)
      has s = s `isInfixOf` text
  check "the function is exported under its generated symbol" (has ".globl _fpr_fn_one" && has "_fpr_fn_one:")
  check "the parameter is parked before the entry calls" (has "stur x0, [x29, #-24]\n" && has "bl _fpr_stack_grow" && has "bl _fpr_fuel_exhausted")
  check "the hart is read from x28" (has "mov x9, x28")
  check "the subtraction's slow path re-enters the primitive with retagged operands" (has "bl _fpr_prim_fn__x2d" && has "orr x10, x9, #1")
  check "the epilogue restores sp from the frame pointer" (has "ldur x29, [x29, #-16]\n    mov sp, x9\n    ret")
  check "the bound is finite and named native-insns-v1" (rSegMax (nfReport nf) /= Nothing && has "# native-insns-v1: one segmax=")
  let elf = A64Config ELF HartTlsElf m2Policy S.empty False
  nfe <- either (error . ("FAIL: a64 elf: " ++)) pure (emitFnA64 elf one)
  check "ELF syntax: no underscore, local-exec TLS" ("bl fpr_stack_grow" `isInfixOf` unlines (nfLines nfe) && "tprel_hi12:fpr_posix_hart" `isInfixOf` unlines (nfLines nfe))
  let tlv = A64Config MachO HartTlvMachO m2Policy S.empty False
  nft <- either (error . ("FAIL: a64 tlv: " ++)) pure (emitFnA64 tlv one)
  check "Mach-O TLV: the descriptor call saves x0 and x30 around it" ("stp x0, x30, [sp]" `isInfixOf` unlines (nfLines nft) && "_fpr_posix_hart@TLVPPAGE" `isInfixOf` unlines (nfLines nft))
  nfx <- either (error . ("FAIL: x64: " ++)) pure (X64.emitFnX64 (X64.X64Config m2Policy (S.singleton "one") False) one)
  let xt = unlines (nfLines nfx)
  check "direct x64: SysV parameter home and TLS hart" ("movq %rdi, -24(%rbp)" `isInfixOf` xt && "%fs:fpr_posix_hart@tpoff" `isInfixOf` xt)
  check "direct x64: aligned primitive call" ("subq $8, %rsp\n    call fpr_prim_fn__x2d\n    addq $8, %rsp" `isInfixOf` xt)
  check "direct x64: frame-based return and native bound" ("leaq -8(%r11), %rsp\n    ret" `isInfixOf` xt && rSegMax (nfReport nfx) /= Nothing)
  -- the frame ceiling is a named refusal, never a silent overflow of the headroom
  let wide = Fn "wide" [] TVal (BId 0)
        [ Block (BId 0) []
            ([Instr Nothing OStackCheck, Instr Nothing OSafepoint]
              ++ [Instr (Just (VId n, TInt)) (OConstInt (fromIntegral n)) | n <- [0 .. 4200]]
              ++ [Instr (Just (VId 4201, TVal)) (OTag (VId 4200))])
            (TRet (VId 4201)) ]
  refused "x64 frame beyond the ceiling" "ceiling" (X64.emitFnX64 (X64.X64Config m2Policy S.empty False) wide)
  refused "a frame beyond the ceiling" "ceiling" (emitFnA64 cfg wide)
  forM_ [("one", nf)] $ \(n, f) -> check ("no legacy bound label on " ++ n) (not ("# wcet:" `isInfixOf` unlines (nfLines f)))
  putStrLn "SelectedIR: x86-64 constraints and refusals, flag-neutral placement, frame layout, conditional-path bounds, A64 pipeline (Mach-O x28, ELF TLS, Mach-O TLV), direct x64 pipeline, frame ceilings: PASS"
