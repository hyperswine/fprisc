{-# LANGUAGE LambdaCase #-}
-- Codegen.IR: the typed low-level IR between Core and native instructions
-- (docs/2026-10-20-TYPED-NATIVE-IR-PLAN.md, milestone M1).
--
-- One representation.  A function is a control-flow graph of blocks; a
-- block takes parameters (the join and loop-carried values: there are no
-- phi nodes), holds straight-line instructions over virtual values in
-- SSA form, and ends in exactly one terminator.  Every value has a type
-- that says what representation it has, not only what it means: a tagged
-- runtime word, an unboxed Int, a raw machine integer, a predicate, an
-- address, a float.  Conversions between representations are explicit
-- instructions, never implicit in an operand.
--
-- What the IR does NOT decide: physical registers, frame slots, which
-- instruction a target uses for an operation, whether a conversion pair
-- folds away.  Those are selection, allocation and frame layout (M2, M3).
-- What it DOES fix: the order of effects and traps, where the safepoints
-- are, which calls happen and what they may clobber.
--
-- Semantics of the checked operations are the legacy generator's (the C
-- primitives in runtime/runtime.c and the inline fast paths in
-- Codegen.inlineTable): Int + - * / trap when the result leaves the
-- 63-bit range, / also on a zero divisor, each in program order, each
-- with the primitive's own message.  The reference evaluator
-- (Codegen.Eval) is the executable statement of these semantics.
module Codegen.IR
  ( Name, VId (..), BId (..), Width (..), Ty (..),
    ArithOp (..), CmpOp (..), BitOp (..), ShiftOp (..), FloatOp (..), SimdExpr (..), FloatTree (..), FloatStep (..), simdCaptures, simdRegisters, ftreeLeaves, ftreeMap, ftreeRegisters, ftreeSchedule, ftreeScheduleAt, ftreeScratch, rvvLaneBound, rvvAccBound, intBits, Callee (..), CalleeKind (..), isForeign,
    Op (..), Instr (..), Term (..), Block (..), Fn (..), Program,
    Effect (..), opEffect, opUses, termUses, termSuccs, blockDefs, mapOpUses, mapTermUses,
    intMin, intMax, intFits64, intBounds, intFitsWidth, widthBits, wrapInt, arithSymbol, cmpSymbol, bitName, shiftName, wrap63, arityCeiling,
  ) where

import qualified Data.Map.Strict as M

type Name = String

-- a virtual value: defined once, by a block parameter or an instruction
newtype VId = VId Int deriving (Eq, Ord, Show)

newtype BId = BId Int deriving (Eq, Ord, Show)

data Width = W32 | W64 deriving (Eq, Ord, Show)

-- The representation of a value.  M1 produces TVal, TInt and TPred; the
-- others are declared so the vocabulary is fixed before the milestones
-- that need them (raw words for the builtin adapters and workers,
-- addresses for the indexed-memory forms, floats for the F64 paths).
data Ty
  = TVal -- a tagged runtime word: a tagged Int (2n+1) or an object pointer
  | TInt -- unboxed language Int in the policy word width (31 or 63 signed bits)
  | TRaw Width -- a raw machine integer, no language range
  | TPred -- a predicate, 0 or 1
  | TAddr -- an unmanaged address
  | TF64 -- an IEEE binary64 value
  deriving (Eq, Ord, Show)

data ArithOp = Add | Sub | Mul | Div deriving (Eq, Ord, Show, Enum, Bounded)

data CmpOp = Lt | Gt | Le | Ge | Eq | Ne deriving (Eq, Ord, Show, Enum, Bounded)

-- the bitwise operations of the base profile (runtime/bits.c band, bor,
-- bxor): on the untagged Ints, bit for bit; the result always fits
data BitOp = BAnd | BOr | BXor deriving (Eq, Ord, Show, Enum, Bounded)

-- F64 arithmetic on IEEE binary64 bits held in a TVal (the 64-bit V ABI's
-- float representation): IEEE semantics, no trap, no fused multiply-add
data FloatOp = FAdd | FSub | FMul | FDiv deriving (Eq, Ord, Show, Enum, Bounded)

-- A two-lane SIMD map body: the lane, indexed scalar captures, literals
-- (an Int or F64 bits), and operations applied to both lanes (NEON/SSE2).
data SimdExpr = SLane | SCapture Int | SConst Integer | SInt ArithOp SimdExpr SimdExpr | SFloat FloatOp SimdExpr SimdExpr
  deriving (Eq, Ord, Show)

simdCaptures :: SimdExpr -> [Int]
simdCaptures (SCapture n) = [n]
simdCaptures (SInt _ a b) = simdCaptures a ++ simdCaptures b
simdCaptures (SFloat _ a b) = simdCaptures a ++ simdCaptures b
simdCaptures _ = []

-- Monotonic expression temporaries, excluding the dedicated lane register.
simdRegisters :: SimdExpr -> Int
simdRegisters SLane = 0
simdRegisters (SCapture _) = 1
simdRegisters (SConst _) = 1
simdRegisters (SInt _ a b) = 1 + simdRegisters a + simdRegisters b
simdRegisters (SFloat _ a b) = 1 + simdRegisters a + simdRegisters b

-- A tree of F64 operations over the bits of its leaves, computed in the
-- target's scratch floating-point registers with one move in per leaf and
-- one move out: the fused form of a chain of single-use OFloatBin results
-- (Simplify.fuseFloatTrees). Evaluating a node computes its left subtree in
-- register n and its right in n+1, so a tree needs ftreeRegisters of the
-- ftreeScratch registers every target reserves (d16.., xmm8.., ft0..).
data FloatTree = FLeaf VId | FNode FloatOp FloatTree FloatTree
  deriving (Eq, Ord, Show)

ftreeScratch :: Int
ftreeScratch = 8

ftreeLeaves :: FloatTree -> [VId]
ftreeLeaves (FLeaf v) = [v]
ftreeLeaves (FNode _ x y) = ftreeLeaves x ++ ftreeLeaves y

ftreeMap :: (VId -> VId) -> FloatTree -> FloatTree
ftreeMap f (FLeaf v) = FLeaf (f v)
ftreeMap f (FNode o x y) = FNode o (ftreeMap f x) (ftreeMap f y)

ftreeRegisters :: FloatTree -> Int
ftreeRegisters (FLeaf _) = 1
ftreeRegisters (FNode _ x y) = max (ftreeRegisters x) (1 + ftreeRegisters y)

-- The evaluation of a tree as steps, each one selected instruction with at
-- most one integer operand (an allocator reloads a bounded number of
-- spilled operands per instruction): a leaf moved into scratch register n,
-- a node computed in register n from n and n+1, and the root moved out.
data FloatStep = FSLeaf VId Int | FSNode FloatOp Int deriving (Eq, Ord, Show)

ftreeSchedule :: FloatTree -> ([FloatStep], Int)
ftreeSchedule t = (ftreeScheduleAt 0 t, 0)

ftreeScheduleAt :: Int -> FloatTree -> [FloatStep]
ftreeScheduleAt n (FLeaf v) = [FSLeaf v n]
ftreeScheduleAt n (FNode o x y) = ftreeScheduleAt n x ++ ftreeScheduleAt (n + 1) y ++ [FSNode o n]

-- The RISC-V V sum strip (Kernel.rvvPrefix): at most 64 lanes a strip, each
-- lane within the lane bound, the accumulator within the acc bound, so no
-- prefix of the strip can leave the Int range: 64 * 2^(bits-14) = 2^(bits-8)
-- and the acc bound keeps 2^(bits-8) of headroom below the limits.
rvvLaneBound, rvvAccBound :: Width -> Integer
rvvLaneBound w = 2 ^ (intBits w - 14)
rvvAccBound w = 2 ^ (intBits w - 1) - 2 ^ (intBits w - 8)

intBits :: Width -> Int
intBits W32 = 31
intBits W64 = 63

-- BITSHIFTL / BITSHIFTR (runtime/bits.c h_shiftl, h_shiftr): the 64-bit
-- shift of the untagged value, wrapped to the 63-bit Int (`wrap63`); a
-- count outside 0..63 traps with the primitive's text
data ShiftOp = Shl | Shr deriving (Eq, Ord, Show, Enum, Bounded)

-- A call target with its calling convention in representation terms.
-- The legacy convention for FP-RISC functions is every argument and the
-- result TVal; workers and primitives will declare other signatures.
data CalleeKind
  = Local -- a function of this unit (`fpr_fn_<mangled>`)
  | Imported -- another unit's export, same shapes, extern symbol
  | Foreign String -- a saturated primitive of declared arity: a C entry (`fpr_prim_fn_<mangled>` for a core primitive, `fpr_g_<mangled>_call<n>` for a HAL/foreign declaration), tagged words in and out
  | Generated String -- a function of the generated-code ABI under an explicit symbol: a specialized vector kernel or typed callback clone emitted in this unit (`fpr_vspec_...`, `fpr_tkfn_...`), called exactly as the legacy caller calls it (docs/2026-10-22-TYPED-IR-KERNELS.md)
  deriving (Eq, Ord, Show)

isForeign :: Callee -> Bool
isForeign c = case calleeKind c of
  Foreign _ -> True
  _ -> False

data Callee = Callee
  { calleeName :: Name,
    calleeKind :: CalleeKind,
    calleeParams :: [Ty],
    calleeResult :: Ty
  }
  deriving (Eq, Ord, Show)

data Op
  = OConstInt Integer -- :: TInt; the literal fits the Int range
  | ONullary Int Int -- :: TVal; the immortal object of a nullary constructor (typeid, variant)
  | OString String -- immortal byte-string object, same encoding as the source literal
  | OBoxedFloat Width Integer -- TVal: an immortal RV32 numeric leaf; IEEE width and unsigned bits (not an Int payload)
  | OMake Int Int [VId] -- allocate an immutable constructor with tagged fields
  | OReuse Int Int VId [VId] -- overwrite the fields of a constructor the program owns uniquely (Reuse.reuseFresh proved it), answer it: the legacy `# reuse fresh constructor`; every field is evaluated before the first store
  | OAddress VId -- TVal -> TAddr; internal lowering, after the object/representation guard
  | OIndex VId VId -- TAddr, TInt -> TAddr; address + index * target word bytes
  | OLoad Ty VId Int -- word load at a byte offset: TInt, TVal or TAddr; mutable memory, never CSE
  | OLoadByte VId Int -- zero-extended byte -> TInt (column kind descriptor)
  | OStore Ty VId Int VId -- word store, same representation as OLoad; uniquely owned vector
  | OField Int VId -- read a statically typed constructor field (zero-based)
  | OStrLen VId -- checked String byte length -> TInt
  | OCharAt VId VId -- checked String and TInt byte index -> TInt
  | OTag VId -- TInt -> TVal: box as 2n+1
  | OUntag VId -- TVal -> TInt: the value is an Int by typing; a representation change, not a check
  | OBoolOf VId -- TPred -> TVal: fpr_true / fpr_false
  | OTruth VId -- TVal -> TPred: a Bool object's variant
  | ONot VId -- TPred -> TPred
  | OIsInt VId -- TVal -> TPred: the tag bit (a tagged Int, not an object)
  | OTagTest Int Int VId -- TVal -> TPred: typeid and variant match (a tagged Int never matches)
  | OSymbol String -- :: TVal; the address of an immortal object the unit links against: a core primitive's object (fpr_prim_obj_), a HAL contract (fpr_g_); the legacy `la a0, <symbol>`
  | OFunValue Name -- :: TVal; a program function's static PAP (its arity, no arguments): the legacy `la a0, fpr_obj_<name>`
  | OApply VId [VId] -- TVal, TVal.. -> TVal: the generic application through the runtime (fpr_applyN): partial, over-saturated, or of a computed head; allocates PAPs in the runtime, calls anything
  | OKernelArith ArithOp VId VId -- checked TInt arithmetic with the vector-kernel overflow/zero diagnostics
  | OArith ArithOp VId VId -- TInt TInt -> TInt; traps in program order with the primitive's message
  | OBit BitOp VId VId -- TInt TInt -> TInt: and, or, xor of the untagged values
  | OShift ShiftOp VId VId -- TInt TInt -> TInt: value, count; the count outside 0..63 traps (bits.c)
  | OCmp CmpOp VId VId -- TInt TInt -> TPred
  | OEqVal Bool VId VId -- TVal TVal -> TPred: deep structural equality (True) or inequality (False)
  | OBits Integer -- TVal: a raw 64-bit word, signed form (an F64 literal's IEEE bits, as the legacy generator splices them)
  | OFloatBin FloatOp VId VId -- TVal TVal -> TVal: F64 arithmetic on the bits, inline (Codegen.inlineTable F64.+ - * /)
  | OFloatCmp CmpOp VId VId -- TVal TVal -> TPred: F64 ordered comparison (false on a NaN), != is its negation (true on a NaN)
  | OFloatTree FloatTree -- TVal leaves -> TVal: a tree of F64 operations in the scratch floating-point registers, one move in per leaf, one out (Simplify.fuseFloatTrees)
  | OFloatCmpTree CmpOp FloatTree FloatTree -- TVal leaves -> TPred, scratch roots 0/1
  | OFloat32Tree FloatTree -- F32 operations, rounded at every node
  | OFloat32CmpTree CmpOp FloatTree FloatTree
  | OFloat32Bin FloatOp VId VId -- TVal TVal -> TVal: F32 arithmetic on the low 32 bits of the word (the runtime's F32 word), inline (the legacy genU F32.+ - * /)
  | OFloat32Cmp CmpOp VId VId -- TVal TVal -> TPred: F32 ordered comparison, as OFloatCmp
  | OSafepointN Int -- n fuel ticks before a bounded SIMD pair or callback-free compaction strip
  | OSimdPair Bool SimdExpr [VId] VId -- raw captures (TInt or F64 bits), TAddr: the two Int (True) or F64 (False) lanes at the address, mapped in place through the expression (NEON/SSE2, one 128-bit register); an Int lane that leaves the 63-bit range traps with the kernel diagnostic
  | ORvvVlMax -- :: TInt; RISC-V V: the lanes one vector register holds at the word's element width (vsetvli x0)
  | ORvvLanes VId VId -- TAddr, TInt n -> TPred: RISC-V V: vl = n, the n Int lanes at the address loaded into the vector unit, true when every lane is within rvvLaneBound; the lanes stay loaded for ORvvSumLoaded, which follows with no other vector operation between
  | ORvvSumLoaded VId -- TInt acc -> TInt: acc plus the lanes ORvvLanes loaded (vredsum), unchecked: the builder proved the bound
  | OCall Callee [VId] -- calleeParams -> calleeResult; clobbers every caller-saved register; any effect
  | OSafepoint -- the fuel tick: a runtime call that may deschedule the actor
  | OStackCheck -- the entry headroom check: a runtime call that may move sp to a new segment
  deriving (Eq, Ord, Show)

-- an instruction defines at most one value
data Instr = Instr (Maybe (VId, Ty)) Op deriving (Eq, Ord, Show)

data Term
  = TRet VId -- the function's result, TVal
  | TBr BId [VId] -- a jump with block arguments; to the entry block it is a self tail call
  | TCondBr VId BId [VId] BId [VId] -- predicate, then-target, else-target
  | TTailCall Callee [VId] -- parallel argument assignment, frame teardown, transfer
  | TUnreachable String -- a dead arm (Core's CErr: exhaustiveness proved it unreachable); if ever reached, the legacy trap with this text (fpr_panic)
  deriving (Eq, Ord, Show)

data Block = Block
  { bId :: BId,
    bParams :: [(VId, Ty)],
    bInstrs :: [Instr],
    bTerm :: Term
  }
  deriving (Eq, Ord, Show)

-- The entry block's parameters are the function's parameters, in order;
-- a jump to the entry block is the self tail call, and passes through the
-- entry's safepoint and stack check like any other activation.
data Fn = Fn
  { fnName :: Name,
    fnSourceParams :: [Name], -- the Core parameter names, for dumps and diagnostics
    fnResult :: Ty, -- what `ret` answers: TVal for an FP-RISC function, a worker's raw kind
    fnEntry :: BId,
    fnBlocks :: [Block]
  }
  deriving (Eq, Ord, Show)

type Program = M.Map Name Fn

-- What an operation may do besides compute its result.  Selection and
-- allocation read this; the evaluator records it as events.
data Effect
  = Pure
  | MayTrap -- ends the actor with a reason, in program order
  | RuntimeCall -- calls the runtime: clobbers caller-saved registers, may deschedule
  | AnyEffect -- an FP-RISC call: anything observable may happen
  | Reads -- mutable memory read; ordered against stores and calls
  | Writes -- writes memory of an object it owns uniquely: never moved, merged or dropped
  deriving (Eq, Ord, Show)

opEffect :: Op -> Effect
opEffect = \case
  OConstInt _ -> Pure
  ONullary _ _ -> Pure
  OString _ -> Pure
  OBoxedFloat _ _ -> Pure
  OMake _ _ _ -> RuntimeCall
  OReuse _ _ _ _ -> Writes
  OAddress _ -> Pure
  OIndex _ _ -> Pure
  OLoad _ _ _ -> Reads
  OLoadByte _ _ -> Reads
  OStore _ _ _ _ -> Writes
  OField _ _ -> Pure
  OStrLen _ -> MayTrap
  OCharAt _ _ -> MayTrap
  OTag _ -> Pure
  OUntag _ -> Pure
  OBoolOf _ -> Pure
  OTruth _ -> Pure
  ONot _ -> Pure
  OIsInt _ -> Pure
  OTagTest _ _ _ -> Pure
  OSymbol _ -> Pure
  OFunValue _ -> Pure
  OApply _ _ -> AnyEffect
  OKernelArith _ _ _ -> MayTrap
  OArith _ _ _ -> MayTrap
  OBit _ _ _ -> Pure
  OShift _ _ _ -> MayTrap
  OCmp _ _ _ -> Pure
  OEqVal _ _ _ -> RuntimeCall -- deep equality is the C primitive unless both are tagged Ints
  OBits _ -> Pure
  OFloatBin _ _ _ -> Pure
  OFloatCmp _ _ _ -> Pure
  OFloatCmpTree _ _ _ -> Pure
  OFloat32CmpTree _ _ _ -> Pure
  OFloat32Tree _ -> Pure
  OFloatTree _ -> Pure
  OFloat32Bin _ _ _ -> Pure
  OFloat32Cmp _ _ _ -> Pure
  OCall _ _ -> AnyEffect
  OSafepoint -> RuntimeCall
  OStackCheck -> RuntimeCall
  OSafepointN _ -> RuntimeCall
  OSimdPair _ _ _ _ -> Writes
  ORvvVlMax -> Pure
  ORvvLanes _ _ -> Reads
  ORvvSumLoaded _ -> Reads

opUses :: Op -> [VId]
opUses = \case
  OConstInt _ -> []
  ONullary _ _ -> []
  OString _ -> []
  OBoxedFloat _ _ -> []
  OMake _ _ fs -> fs
  OReuse _ _ r fs -> r : fs
  OAddress v -> [v]
  OIndex a i -> [a,i]
  OLoad _ a _ -> [a]
  OLoadByte a _ -> [a]
  OStore _ a _ v -> [a,v]
  OField _ v -> [v]
  OStrLen v -> [v]
  OCharAt s n -> [s, n]
  OTag v -> [v]
  OUntag v -> [v]
  OBoolOf v -> [v]
  OTruth v -> [v]
  ONot v -> [v]
  OIsInt v -> [v]
  OTagTest _ _ v -> [v]
  OSymbol _ -> []
  OFunValue _ -> []
  OApply f as -> f : as
  OKernelArith _ a b -> [a,b]
  OArith _ a b -> [a, b]
  OBit _ a b -> [a, b]
  OShift _ a b -> [a, b]
  OCmp _ a b -> [a, b]
  OEqVal _ a b -> [a, b]
  OBits _ -> []
  OFloatBin _ a b -> [a, b]
  OFloatCmp _ a b -> [a, b]
  OFloatCmpTree _ a b -> ftreeLeaves a ++ ftreeLeaves b
  OFloat32CmpTree _ a b -> ftreeLeaves a ++ ftreeLeaves b
  OFloat32Tree t -> ftreeLeaves t
  OFloatTree t -> ftreeLeaves t
  OFloat32Bin _ a b -> [a, b]
  OFloat32Cmp _ a b -> [a, b]
  OCall _ as -> as
  OSafepoint -> []
  OStackCheck -> []
  OSafepointN _ -> []
  OSimdPair _ _ caps a -> a:caps
  ORvvVlMax -> []
  ORvvLanes a n -> [a, n]
  ORvvSumLoaded a -> [a]

termUses :: Term -> [VId]
termUses = \case
  TRet v -> [v]
  TBr _ as -> as
  TCondBr c _ as _ bs -> c : as ++ bs
  TTailCall _ as -> as
  TUnreachable _ -> []

-- the same operation or terminator over renamed values (the simplification
-- passes substitute one value for another)
mapOpUses :: (VId -> VId) -> Op -> Op
mapOpUses f = \case
  OConstInt n -> OConstInt n
  ONullary t v -> ONullary t v
  OString s -> OString s
  OBoxedFloat width bits -> OBoxedFloat width bits
  OMake t v fs -> OMake t v (map f fs)
  OReuse t v r fs -> OReuse t v (f r) (map f fs)
  OAddress v -> OAddress (f v)
  OIndex a i -> OIndex (f a) (f i)
  OLoad t a n -> OLoad t (f a) n
  OLoadByte a n -> OLoadByte (f a) n
  OStore t a n v -> OStore t (f a) n (f v)
  OField n v -> OField n (f v)
  OStrLen v -> OStrLen (f v)
  OCharAt s n -> OCharAt (f s) (f n)
  OTag v -> OTag (f v)
  OUntag v -> OUntag (f v)
  OBoolOf v -> OBoolOf (f v)
  OTruth v -> OTruth (f v)
  ONot v -> ONot (f v)
  OIsInt v -> OIsInt (f v)
  OTagTest t c v -> OTagTest t c (f v)
  OSymbol s -> OSymbol s
  OFunValue n -> OFunValue n
  OApply h as -> OApply (f h) (map f as)
  OKernelArith o a b -> OKernelArith o (f a) (f b)
  OArith o a b -> OArith o (f a) (f b)
  OBit o a b -> OBit o (f a) (f b)
  OShift o a b -> OShift o (f a) (f b)
  OCmp o a b -> OCmp o (f a) (f b)
  OEqVal e a b -> OEqVal e (f a) (f b)
  OBits n -> OBits n
  OFloatBin o a b -> OFloatBin o (f a) (f b)
  OFloatCmp o a b -> OFloatCmp o (f a) (f b)
  OFloatCmpTree o a b -> OFloatCmpTree o (ftreeMap f a) (ftreeMap f b)
  OFloat32CmpTree o a b -> OFloat32CmpTree o (ftreeMap f a) (ftreeMap f b)
  OFloat32Tree t -> OFloat32Tree (ftreeMap f t)
  OFloatTree t -> OFloatTree (ftreeMap f t)
  OFloat32Bin o a b -> OFloat32Bin o (f a) (f b)
  OFloat32Cmp o a b -> OFloat32Cmp o (f a) (f b)
  OCall c as -> OCall c (map f as)
  OSafepoint -> OSafepoint
  OStackCheck -> OStackCheck
  OSafepointN n -> OSafepointN n
  OSimdPair i e caps a -> OSimdPair i e (map f caps) (f a)
  ORvvVlMax -> ORvvVlMax
  ORvvLanes a n -> ORvvLanes (f a) (f n)
  ORvvSumLoaded a -> ORvvSumLoaded (f a)

mapTermUses :: (VId -> VId) -> Term -> Term
mapTermUses f = \case
  TRet v -> TRet (f v)
  TBr b as -> TBr b (map f as)
  TCondBr c t as e bs -> TCondBr (f c) t (map f as) e (map f bs)
  TTailCall c as -> TTailCall c (map f as)
  TUnreachable m -> TUnreachable m

termSuccs :: Term -> [(BId, [VId])]
termSuccs = \case
  TRet _ -> []
  TBr b as -> [(b, as)]
  TCondBr _ t as e bs -> [(t, as), (e, bs)]
  TTailCall _ _ -> []
  TUnreachable _ -> []

blockDefs :: Block -> [(VId, Ty)]
blockDefs b = bParams b ++ [d | Instr (Just d) _ <- bInstrs b]

-- the generated-code convention's arity ceiling: eight register arguments
-- and the 56 per-hart spill cells (fpr.h FPR_ARGSPILL, Codegen.spillCells;
-- docs/2026-10-21-NATIVE-IR-CONTRACTS.md "Arguments 9-64").  A definition,
-- call or tail transfer beyond it has no convention and is refused.
arityCeiling :: Int
arityCeiling = 64

-- the Int range of the 64-bit targets (docs/2026-10-12-INT-OVERFLOW.md)
intMin, intMax :: Integer
intMin = negate (2 ^ (62 :: Int))
intMax = 2 ^ (62 :: Int) - 1

intFits64 :: Integer -> Bool
intFits64 n = n >= intMin && n <= intMax

arithSymbol :: ArithOp -> String
arithSymbol = \case Add -> "+"; Sub -> "-"; Mul -> "*"; Div -> "/"

cmpSymbol :: CmpOp -> String
cmpSymbol = \case Lt -> "<"; Gt -> ">"; Le -> "<="; Ge -> ">="; Eq -> "=="; Ne -> "!="

-- the primitives' source names (their HAL entries are fpr_g_<name>_call2)
bitName :: BitOp -> String
bitName = \case BAnd -> "band"; BOr -> "bor"; BXor -> "bxor"

shiftName :: ShiftOp -> String
shiftName = \case Shl -> "BITSHIFTL"; Shr -> "BITSHIFTR"

-- the low 63 bits of a two's-complement value, sign-extended: what
-- `slli 1; ori 1` then `srai 1` leave of a 64-bit result (the legacy
-- shift expansions and bits.c's TAG((sw)...))
wrap63 :: Integer -> Integer
wrap63 v = let m = v `mod` (2 ^ (63 :: Int)) in if m > intMax then m - 2 ^ (63 :: Int) else m

widthBits :: Width -> Int
widthBits W32 = 32
widthBits W64 = 64

intBounds :: Width -> (Integer, Integer)
intBounds width = let half = 2 ^ (widthBits width - 2) in (-half, half - 1)

intFitsWidth :: Width -> Integer -> Bool
intFitsWidth width n = let (lo,hi) = intBounds width in n >= lo && n <= hi

wrapInt :: Width -> Integer -> Integer
wrapInt width n = let modulus = 2 ^ (widthBits width - 1); m = n `mod` modulus
                  in if m > snd (intBounds width) then m - modulus else m
