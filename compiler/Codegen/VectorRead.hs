-- Guarded scalar reads are typed CFG fragments. Operands are already evaluated
-- before entry, and every miss calls the original C entry with those values.
module Codegen.VectorRead (Builder(..),ScalarRead,canRead,planRead,lowerRead) where
import Codegen.IR
import Codegen.Policy
import Codegen.Target.Common (mangleName)
import qualified Core.VectorRead as Read
import Compiler.VectorABI

data Builder m=Builder
  { value :: Ty -> Op -> m VId,
    newLabel :: m BId,
    newJoin :: Ty -> m (BId,VId),
    begin :: BId -> [(VId,Ty)] -> m (),
    end :: Term -> m () }
data ScalarRead=Length Callee VId | Element Callee VId VId

canRead :: Policy -> Read.Read -> Callee -> Bool
canRead policy op callee
  | not (polVectorFast policy) || policyWidth policy/=W64
    || polProfile policy `notElem` [HostedBase,QosApp]=False
  | calleeKind callee/=Foreign expected || calleeResult callee/=TVal
    || calleeParams callee/=replicate arity TVal || calleeName callee/=Read.peekName op=False
  | otherwise=True
  where arity=Read.indexArity op+1
        expected="fpr_g_"++mangleName (Read.peekName op)++"_call"++show arity

planRead :: Policy -> Read.Read -> Callee -> [VId] -> Maybe ScalarRead
planRead policy op callee args
  | not (canRead policy op callee)=Nothing
  | otherwise=case (op,args) of
      (Read.Length,[vec])->Just (Length callee vec)
      (Read.At,[index,vec])->Just (Element callee index vec)
      (Read.Get,[index,vec])->Just (Element callee index vec)
      _->Nothing

lowerRead :: Monad m => Builder m -> ScalarRead -> m VId
lowerRead builder plan=do
  (join,result)<-newJoin builder TVal
  slow<-newLabel builder
  let (callee,args,vec)=case plan of
        Length c v->(c,[v],v)
        Element c i v->(c,[i,v],v)
      v=value builder
      label=newLabel builder
      enter b=begin builder b []
      finish r=end builder (TBr join [r])
      constant n=v TInt (OConstInt n)
      guard p=do
        next<-label
        end builder (TCondBr p next [] slow [])
        enter next
      equal x n=constant n >>= \y->v TPred (OCmp Eq x y)
      load ty a offset=v ty (OLoad ty a offset)
  -- On failure, C retains the operation's own validation/trap priority.
  case plan of Element _ index _->v TPred (OIsInt index) >>= guard;_->pure ()
  isInteger<-v TPred (OTagTest vectorTypeId intRep vec)
  shape<-label
  checkFloat<-label
  end builder (TCondBr isInteger shape [] checkFloat [])
  enter checkFloat
  v TPred (OTagTest vectorTypeId floatRep vec) >>= guard
  end builder (TBr shape [])
  enter shape
  address<-v TAddr (OAddress vec)
  count<-load TInt address (lengthOffset 8)
  case plan of
    Length {}->v TVal (OTag count) >>= finish
    Element _ index _->do
      i<-v TInt (OUntag index)
      zero<-constant 0
      v TPred (OCmp Ge i zero) >>= guard
      v TPred (OCmp Lt i count) >>= guard
      columns<-load TInt address (columnCountOffset 8)
      equal columns 1 >>= guard
      kinds<-load TAddr address (kindsOffset 8)
      kind<-v TInt (OLoadByte kinds 0)
      integer<-label
      floating<-label
      end builder (TCondBr isInteger integer [] floating [])
      let cell ty=do
            directory<-load TAddr address (columnsOffset 8)
            column<-load TAddr directory 0
            base<-load TAddr column (columnBaseOffset 8)
            cursor<-v TAddr (OIndex base i)
            load ty cursor 0
      enter integer
      equal kind intKind >>= guard
      cell TInt >>= \raw->v TVal (OTag raw) >>= finish
      enter floating
      wide<-equal kind f64Kind
      readFloat<-label
      narrow<-label
      end builder (TCondBr wide readFloat [] narrow [])
      enter narrow
      equal kind f32Kind >>= guard
      end builder (TBr readFloat [])
      enter readFloat
      cell TVal >>= finish -- preserve every IEEE bit, including NaNs/-0
  enter slow
  v TVal (OCall callee args) >>= finish
  begin builder join [(result,TVal)]
  pure result
