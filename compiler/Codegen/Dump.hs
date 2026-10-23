{-# LANGUAGE LambdaCase #-}
-- Codegen.Dump: a deterministic text form of a typed-IR function, for
-- diagnostics, fixtures and reviews.  Blocks print in the function's
-- order, values and blocks by their numbers; no map iteration order
-- leaks into the text.
module Codegen.Dump (dumpFn, dumpProgram) where

import Codegen.IR
import Data.List (intercalate)
import qualified Data.Map.Strict as M

dumpProgram :: Program -> String
dumpProgram p = intercalate "\n" (map dumpFn (M.elems p))

dumpFn :: Fn -> String
dumpFn fn =
  unlines $
    ("fn " ++ fnName fn ++ " (" ++ unwords (fnSourceParams fn) ++ ") -> " ++ ty (fnResult fn) ++ " entry " ++ block (fnEntry fn))
      : concatMap dumpBlock (fnBlocks fn)
  where
    dumpBlock b =
      (block (bId b) ++ "(" ++ intercalate ", " [value v ++ ": " ++ ty t | (v, t) <- bParams b] ++ "):")
        : map (("  " ++) . instr) (bInstrs b)
        ++ ["  " ++ term (bTerm b)]
    instr (Instr Nothing op) = opText op
    instr (Instr (Just (v, t)) op) = value v ++ ": " ++ ty t ++ " = " ++ opText op
    opText = \case
      OConstInt n -> "const " ++ show n
      ONullary t v -> "nullary " ++ show t ++ " " ++ show v
      OString s -> "string " ++ show s
      OMake t c fs -> "make " ++ show t ++ ":" ++ show c ++ args fs
      OReuse t c r fs -> "reuse " ++ value r ++ " as " ++ show t ++ ":" ++ show c ++ args fs
      OAddress v -> "address " ++ value v
      OIndex a i -> "index " ++ value a ++ " " ++ value i
      OLoad t a n -> "load " ++ show t ++ " " ++ value a ++ "+" ++ show n
      OLoadByte a n -> "load.byte " ++ value a ++ "+" ++ show n
      OStore t a n v -> "store " ++ show t ++ " " ++ value a ++ "+" ++ show n ++ " " ++ value v
      OField n v -> "field " ++ show n ++ " " ++ value v
      OStrLen v -> "strlen " ++ value v
      OCharAt s n -> "charAt " ++ value s ++ ", " ++ value n
      OTag v -> "tag " ++ value v
      OUntag v -> "untag " ++ value v
      OBoolOf v -> "boolof " ++ value v
      OTruth v -> "truth " ++ value v
      ONot v -> "not " ++ value v
      OIsInt v -> "isint " ++ value v
      OTagTest t c v -> "tagtest " ++ show t ++ " " ++ show c ++ " " ++ value v
      OSymbol sym -> "symbol " ++ sym
      OFunValue n -> "funvalue " ++ n
      OApply f as -> "apply " ++ value f ++ args as
      OKernelArith o a b -> "kernel." ++ show o ++ " " ++ value a ++ " " ++ value b
      OArith o a b -> "arith " ++ arithSymbol o ++ " " ++ value a ++ ", " ++ value b
      OBit o a b -> "bit " ++ bitName o ++ " " ++ value a ++ ", " ++ value b
      OShift o a b -> "shift " ++ shiftName o ++ " " ++ value a ++ ", " ++ value b
      OCmp o a b -> "cmp " ++ cmpSymbol o ++ " " ++ value a ++ ", " ++ value b
      OEqVal eq a b -> (if eq then "eqval " else "neval ") ++ value a ++ ", " ++ value b
      OBits n -> "bits " ++ show n
      OFloatBin o a b -> "fbin " ++ (case o of FAdd -> "+"; FSub -> "-"; FMul -> "*"; FDiv -> "/") ++ " " ++ value a ++ ", " ++ value b
      OFloatCmp o a b -> "fcmp " ++ cmpSymbol o ++ " " ++ value a ++ ", " ++ value b
      OFloatTree t -> "ftree " ++ ftreeText t
      OFloat32Bin o a b -> "fbin32 " ++ (case o of FAdd -> "+"; FSub -> "-"; FMul -> "*"; FDiv -> "/") ++ " " ++ value a ++ ", " ++ value b
      OFloat32Cmp o a b -> "fcmp32 " ++ cmpSymbol o ++ " " ++ value a ++ ", " ++ value b
      OCall c as -> "call " ++ callee c ++ args as
      OSafepoint -> "safepoint"
      OSafepointN n -> "safepoint x" ++ show n
      OSimdPair int e a -> "simd.pair " ++ (if int then "int " else "f64 ") ++ simdText e ++ " " ++ value a
      ORvvVlMax -> "rvv.vlmax"
      ORvvLanes a n -> "rvv.lanes " ++ value a ++ " " ++ value n
      ORvvSumLoaded acc -> "rvv.sum " ++ value acc
      OStackCheck -> "stackcheck"
    term = \case
      TRet v -> "ret " ++ value v
      TBr b as -> "br " ++ block b ++ args as
      TCondBr c t as e bs -> "condbr " ++ value c ++ " -> " ++ block t ++ args as ++ " | " ++ block e ++ args bs
      TTailCall c as -> "tailcall " ++ callee c ++ args as
      TUnreachable msg -> "unreachable " ++ show msg
    callee c = calleeName c ++ (case calleeKind c of Imported -> "@import"; Foreign sym -> "@foreign:" ++ sym; Generated sym -> "@generated:" ++ sym; Local -> "")
      ++ " :: " ++ intercalate " " (map ty (calleeParams c)) ++ " -> " ++ ty (calleeResult c)
    args as = "(" ++ intercalate ", " (map value as) ++ ")"
    value (VId n) = "v" ++ show n
    block (BId n) = "b" ++ show n
    ty = \case
      TVal -> "val"
      TInt -> "int"
      TRaw W64 -> "raw64"
      TRaw W32 -> "raw32"
      TPred -> "pred"
      TAddr -> "addr"
      TF64 -> "f64"

simdText :: SimdExpr -> String
simdText = \case
  SLane -> "lane"
  SConst n -> show n
  SInt o x y -> "(" ++ simdText x ++ " " ++ (case o of Add -> "+"; Sub -> "-"; Mul -> "*"; Div -> "/") ++ " " ++ simdText y ++ ")"
  SFloat o x y -> "(" ++ simdText x ++ " " ++ (case o of FAdd -> "f+"; FSub -> "f-"; FMul -> "f*"; FDiv -> "f/") ++ " " ++ simdText y ++ ")"

ftreeText :: FloatTree -> String
ftreeText (FLeaf v) = "v" ++ show (let VId n = v in n)
ftreeText (FNode o x y) = "(" ++ ftreeText x ++ " " ++ (case o of FAdd -> "+"; FSub -> "-"; FMul -> "*"; FDiv -> "/") ++ " " ++ ftreeText y ++ ")"
