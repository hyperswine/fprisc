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
module Codegen.StringRead (StringRead (..), canRead, planLength, planElement, planCompare, lowerRead, lowerCompare) where

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

-- strCompare: the two strings (TVal), answered inline when their first
-- two bytes or their lengths settle the order (lowerCompare)
planCompare :: Policy -> Callee -> VId -> VId -> Maybe (Callee, VId, VId)
planCompare policy callee a b
  | canRead policy callee "strCompare" 2 = Just (callee, a, b)
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
  -- one header word: OVariantTest answers False for a tagged Int too
  v TPred (OVariantTest stringTypeId 0 str) >>= guard
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

-- strCompare a b (runtime.c g_strCompare): -1, 0 or 1 in byte order, then
-- by length. Inline, after both header guards: when either string is empty
-- the lengths decide; when the first bytes differ they decide; when they
-- are equal and either string has one byte the lengths decide; when the
-- second bytes differ they decide. Anything else (a longer common prefix,
-- a header that is not (T_STR, 0), a tagged Int) calls the C entry with
-- the original values, so its diagnostics and answer are unchanged. Most
-- compares on a map walk end on the first byte; the C call's cost (two
-- argument checks, the alignment test, the word loop set-up) was more
-- than the compare. No loop: the fragment's worst case is fixed.
lowerCompare :: Monad m => Builder m -> (Callee, VId, VId) -> m VId
lowerCompare builder (callee, a, b) = do
  (join, result) <- newJoin builder TInt
  slow <- newLabel builder
  rare builder slow
  let v = value builder
      label = newLabel builder
      enter blk = begin builder blk []
      finish r = end builder (TBr join [r])
      constant n = v TInt (OConstInt n)
      guard p = do
        next <- label
        end builder (TCondBr p next [] slow [])
        enter next
      -- branch on p: to a fresh block for True and one for False
      split p = do
        yes <- label
        no <- label
        end builder (TCondBr p yes [] no [])
        pure (yes, no)
      -- -1 or 1 as x < y (x and y differ)
      order x y = do
        (lt, gt) <- v TPred (OCmp Lt x y) >>= split
        enter lt
        constant (-1) >>= finish
        enter gt
        constant 1 >>= finish
  v TPred (OVariantTest stringTypeId 0 a) >>= guard
  v TPred (OVariantTest stringTypeId 0 b) >>= guard
  pa <- v TAddr (OAddress a)
  pb <- v TAddr (OAddress b)
  la <- v TInt (OLoad TInt pa stringLengthOffset)
  lb <- v TInt (OLoad TInt pb stringLengthOffset)
  byLength <- label
  zero <- constant 0
  one <- constant 1
  -- an empty string: the lengths decide
  emptyA <- v TPred (OCmp Eq la zero)
  (eA, neA) <- split emptyA
  enter eA
  end builder (TBr byLength [])
  enter neA
  emptyB <- v TPred (OCmp Eq lb zero)
  (eB, neB) <- split emptyB
  enter eB
  end builder (TBr byLength [])
  enter neB
  a0 <- v TInt (OLoadByte pa stringBytesOffset)
  b0 <- v TInt (OLoadByte pb stringBytesOffset)
  (same0, differ0) <- v TPred (OCmp Eq a0 b0) >>= split
  enter differ0
  order a0 b0
  enter same0
  -- a one-byte string with an equal first byte: the lengths decide
  shortA <- v TPred (OCmp Eq la one)
  (sA, nsA) <- split shortA
  enter sA
  end builder (TBr byLength [])
  enter nsA
  shortB <- v TPred (OCmp Eq lb one)
  (sB, nsB) <- split shortB
  enter sB
  end builder (TBr byLength [])
  enter nsB
  a1 <- v TInt (OLoadByte pa (stringBytesOffset + 1))
  b1 <- v TInt (OLoadByte pb (stringBytesOffset + 1))
  v TPred (OCmp Ne a1 b1) >>= guard
  order a1 b1
  -- equal so far and one of them ends: shorter first
  enter byLength
  (eq, ne) <- v TPred (OCmp Eq la lb) >>= split
  enter eq
  finish zero
  enter ne
  order la lb
  enter slow
  r <- v TVal (OCall callee [a, b])
  v TInt (OUntag r) >>= finish
  begin builder join [(result, TInt)]
  pure result
