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
    ArithOp (..), CmpOp (..), BitOp (..), ShiftOp (..), Callee (..), CalleeKind (..), isForeign,
    Op (..), Instr (..), Term (..), Block (..), Fn (..), Program,
    Effect (..), opEffect, opUses, termUses, termSuccs, blockDefs, mapOpUses, mapTermUses,
    intMin, intMax, intFits64, arithSymbol, cmpSymbol, bitName, shiftName, wrap63, arityCeiling,
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
  | TInt -- an unboxed language Int, within the 63-bit range by construction
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
  | OArith ArithOp VId VId -- TInt TInt -> TInt; traps in program order with the primitive's message
  | OBit BitOp VId VId -- TInt TInt -> TInt: and, or, xor of the untagged values
  | OShift ShiftOp VId VId -- TInt TInt -> TInt: value, count; the count outside 0..63 traps (bits.c)
  | OCmp CmpOp VId VId -- TInt TInt -> TPred
  | OEqVal Bool VId VId -- TVal TVal -> TPred: deep structural equality (True) or inequality (False)
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
  deriving (Eq, Ord, Show)

opEffect :: Op -> Effect
opEffect = \case
  OConstInt _ -> Pure
  ONullary _ _ -> Pure
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
  OArith _ _ _ -> MayTrap
  OBit _ _ _ -> Pure
  OShift _ _ _ -> MayTrap
  OCmp _ _ _ -> Pure
  OEqVal _ _ _ -> RuntimeCall -- deep equality is the C primitive unless both are tagged Ints
  OCall _ _ -> AnyEffect
  OSafepoint -> RuntimeCall
  OStackCheck -> RuntimeCall

opUses :: Op -> [VId]
opUses = \case
  OConstInt _ -> []
  ONullary _ _ -> []
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
  OArith _ a b -> [a, b]
  OBit _ a b -> [a, b]
  OShift _ a b -> [a, b]
  OCmp _ a b -> [a, b]
  OEqVal _ a b -> [a, b]
  OCall _ as -> as
  OSafepoint -> []
  OStackCheck -> []

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
  OArith o a b -> OArith o (f a) (f b)
  OBit o a b -> OBit o (f a) (f b)
  OShift o a b -> OShift o (f a) (f b)
  OCmp o a b -> OCmp o (f a) (f b)
  OEqVal e a b -> OEqVal e (f a) (f b)
  OCall c as -> OCall c (map f as)
  OSafepoint -> OSafepoint
  OStackCheck -> OStackCheck

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
