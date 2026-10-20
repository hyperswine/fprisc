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
      OTag v -> "tag " ++ value v
      OUntag v -> "untag " ++ value v
      OBoolOf v -> "boolof " ++ value v
      OTruth v -> "truth " ++ value v
      ONot v -> "not " ++ value v
      OIsInt v -> "isint " ++ value v
      OTagTest t c v -> "tagtest " ++ show t ++ " " ++ show c ++ " " ++ value v
      OArith o a b -> "arith " ++ arithSymbol o ++ " " ++ value a ++ ", " ++ value b
      OCmp o a b -> "cmp " ++ cmpSymbol o ++ " " ++ value a ++ ", " ++ value b
      OEqVal eq a b -> (if eq then "eqval " else "neval ") ++ value a ++ ", " ++ value b
      OCall c as -> "call " ++ callee c ++ args as
      OSafepoint -> "safepoint"
      OStackCheck -> "stackcheck"
    term = \case
      TRet v -> "ret " ++ value v
      TBr b as -> "br " ++ block b ++ args as
      TCondBr c t as e bs -> "condbr " ++ value c ++ " -> " ++ block t ++ args as ++ " | " ++ block e ++ args bs
      TTailCall c as -> "tailcall " ++ callee c ++ args as
    callee c = calleeName c ++ (if calleeKind c == Imported then "@import" else "")
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
