-- Exact non-trapping, non-allocating selections in the RV64 builtin ARC ABI.
-- Selection and resource analysis share this description: an earlier OCall
-- does not imply a runtime call when this complete checked adapter is emitted.
module Codegen.Target.RV.ScalarAdapters
  (ScalarAdapter(..),WordBinary(..),scalarAdapter) where

import Codegen.IR (Callee(..),CalleeKind(..),Ty(..),CmpOp(..))
import Codegen.Target.Common (functionSymbol)

data WordBinary = WordAdd | WordSub | WordAnd | WordOr | WordXor deriving (Eq,Show)
data ScalarAdapter
  = Binary WordBinary | WordNot | WordFromInt | WordToInt | WordBits
  | Compare CmpOp | AddressIdentity | AddressNull | AddressAdd
  deriving (Eq,Show)

-- A reserved source spelling alone is not proof: check the actual foreign
-- symbol, complete word signature and saturated arity. Callers additionally
-- establish RV64/BuiltinArc selection; no other profile uses these facts.
scalarAdapter :: Callee -> Int -> Maybe ScalarAdapter
scalarAdapter c arity
  | calleeKind c/=Foreign (functionSymbol (calleeName c))
    || calleeParams c/=replicate arity TVal || calleeResult c/=TVal = Nothing
  | otherwise = case (calleeName c,arity) of
      ("$arc.wordadd",2)->Just (Binary WordAdd)
      ("$arc.wordsub",2)->Just (Binary WordSub)
      ("$arc.wordand",2)->Just (Binary WordAnd)
      ("$arc.wordor",2)->Just (Binary WordOr)
      ("$arc.wordxor",2)->Just (Binary WordXor)
      ("$arc.wordnot",1)->Just WordNot
      ("$arc.wordfromInt",1)->Just WordFromInt
      ("$arc.wordtoInt",1)->Just WordToInt
      ("$arc.wordbits",1)->Just WordBits
      ("$arc.wordeq",2)->Just (Compare Eq)
      ("$arc.rawEq",2)->Just (Compare Eq)
      ("$arc.rawNe",2)->Just (Compare Ne)
      ("$arc.lt",2)->Just (Compare Lt)
      ("$arc.gt",2)->Just (Compare Gt)
      ("$arc.le",2)->Just (Compare Le)
      ("$arc.ge",2)->Just (Compare Ge)
      ("$arc.addrfromWord",1)->Just AddressIdentity
      ("$arc.addrtoWord",1)->Just AddressIdentity
      ("$arc.addrnull",1)->Just AddressNull
      ("$arc.addradd",2)->Just AddressAdd
      ("$arc.addreq",2)->Just (Compare Eq)
      _->Nothing
