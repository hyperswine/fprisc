-- Codegen.StringRead: guarded scalar String reads as typed CFG fragments,
-- in the shape of Codegen.VectorRead. Operands are already evaluated before
-- entry (left to right, as the flat OStrLen/OCharAt lowering evaluated
-- them), and every guard miss calls the original C entry with the original
-- values, so the runtime keeps its validation order and trap texts:
-- g_charAt checks "not a string" before the range, and the fragment's
-- guards reach the same C entry in the same order.
--
-- The layout constants are the W64 str_t (runtime/fpr.h): u32 tid at 0
-- (T_STR), u32 var at 4 (always 0 for a String), uw len at 8, bytes at 16.
-- tests/StringRead.hs checks them against the C header with static
-- assertions. W32/builtin/manual profiles keep the C entry: the constants
-- are only contracted for the managed 64-bit hosted/QOS targets.
module Codegen.StringRead (StringRead (..), canRead, planLength, planElement, lowerRead) where

import Codegen.IR
import Codegen.Policy
import Codegen.VectorRead (Builder (..))

data StringRead
  = StrLength Callee VId -- strlen: the string (TVal)
  | StrCharAt Callee VId VId -- charAt: the string (TVal) and the index (TInt)
  deriving (Eq, Show)

-- the managed 64-bit contract: inline layout reads need the managed word
-- and the hosted/QOS string representation
canRead :: Policy -> Callee -> String -> Int -> Bool
canRead policy callee name arity =
  polStringFast policy && policyWidth policy == W64
    && polProfile policy `elem` [HostedBase, QosApp]
    && calleeKind callee == Foreign ("fpr_g_" ++ name ++ "_call" ++ show arity)
    && calleeName callee == name
    && calleeParams callee == replicate arity TVal
    && calleeResult callee == TVal

planLength :: Policy -> Callee -> VId -> Maybe StringRead
planLength policy callee str
  | canRead policy callee "strlen" 1 = Just (StrLength callee str)
  | otherwise = Nothing

planElement :: Policy -> Callee -> VId -> VId -> Maybe StringRead
planElement policy callee str index
  | canRead policy callee "charAt" 2 = Just (StrCharAt callee str index)
  | otherwise = Nothing

stringTypeId :: Int
stringTypeId = 9000 -- T_STR (runtime/fpr.h)

stringLengthOffset :: Int
stringLengthOffset = 8

stringBytesOffset :: Int
stringBytesOffset = 16

lowerRead :: Monad m => Builder m -> StringRead -> m VId
lowerRead builder plan = do
  (join, result) <- newJoin builder TInt
  slow <- newLabel builder
  let v = value builder
      label = newLabel builder
      enter b = begin builder b []
      finish r = end builder (TBr join [r])
      constant n = v TInt (OConstInt n)
      guard p = do
        next <- label
        end builder (TCondBr p next [] slow [])
        enter next
      guardNot p = do
        next <- label
        end builder (TCondBr p slow [] next [])
        enter next
      str = case plan of
        StrLength _ s -> s
        StrCharAt _ s _ -> s
  -- a tagged Int is not a string, and a heap value whose header is not
  -- (T_STR, 0) is left to C: its diagnostics name the case
  v TPred (OIsInt str) >>= guardNot
  v TPred (OTagTest stringTypeId 0 str) >>= guard
  address <- v TAddr (OAddress str)
  count <- v TInt (OLoad TInt address stringLengthOffset)
  fast <- case plan of
    StrLength _ _ -> pure count
    StrCharAt _ _ index -> do
      zero <- constant 0
      v TPred (OCmp Ge index zero) >>= guard
      v TPred (OCmp Lt index count) >>= guard
      cursor <- v TAddr (OIndexByte address index)
      v TInt (OLoadByte cursor stringBytesOffset)
  finish fast
  enter slow
  case plan of
    StrLength callee _ -> do
      r <- v TVal (OCall callee [str])
      v TInt (OUntag r) >>= finish
    StrCharAt callee _ index -> do
      tagged <- v TVal (OTag index)
      r <- v TVal (OCall callee [str, tagged])
      v TInt (OUntag r) >>= finish
  begin builder join [(result, TInt)]
  pure result
