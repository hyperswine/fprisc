{-# LANGUAGE TupleSections #-}
-- Guarded scalar reads are typed CFG fragments. Operands are already evaluated
-- before entry, and every miss calls the original C entry with those values.
module Codegen.VectorRead (Builder(..),ScalarRead(..),View(..),Index(..),canRead,canStore,storeNames,planRead,lowerRead,lowerElement,lowerStore,expandViews) where
import Codegen.IR
import Codegen.Policy
import Codegen.Target.Common (mangleName)
import qualified Core.VectorRead as Read
import Compiler.VectorABI
import Control.Monad.State.Strict
import Data.List (nub)

data Builder m=Builder
  { value :: Ty -> Op -> m VId,
    newLabel :: m BId,
    newJoin :: Ty -> m (BId,VId),
    newJoinN :: [Ty] -> m (BId,[VId]),
    begin :: BId -> [(VId,Ty)] -> m (),
    effect :: Op -> m (),
    end :: Term -> m (),
    rare :: BId -> m () } -- the block is rarely run: lay it out of the way
data ScalarRead=Length Callee VId | Element Callee VId VId

canRead :: Policy -> Read.Read -> Callee -> Bool
canRead policy op callee
  | not (polVectorFast policy) || policyWidth policy/=W64
    || polProfile policy `notElem` [HostedBase,QosApp]=False
  | calleeKind callee/=Foreign expected || calleeResult callee/=TVal
    || calleeParams callee/=replicate arity TVal || Read.fromPeekName (calleeName callee)/=Just op=False
  | otherwise=True
  where arity=Read.indexArity op+1
        expected="fpr_g_"++mangleName (calleeName callee)++"_call"++show arity

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

-- A flat view of one vector handle: the length that a flat Int or float
-- column answers for (0 for every other shape, so one bounds test is also the
-- shape test), the column's base, and 1 for an Int column. The handle is
-- linear, and neither a read nor an in-place store moves or resizes the
-- column, so the view is a function of the handle value (IR.OVectorView): it
-- holds wherever that value is in scope, repeated views are shared, and a
-- loop that carries the same handle forms its view once, before the loop.
-- What an access tests and reads through: the mixed view (either column
-- kind, told apart at each access), or the one kind the element's type names
-- (the length is 0 for the other kind, so no test of which it is).
data View=Mixed { viewLength :: VId, viewBase :: VId, viewInteger :: VId }
  | Ints { viewLength :: VId, viewBase :: VId }
  | Floats { viewLength :: VId, viewBase :: VId }
-- an index already known to be an Int, or a value still to be tested
data Index=Raw VId | Tagged VId

storeNames :: [String]
storeNames=Read.storeNames

canStore :: Policy -> String -> Callee -> Bool
canStore policy name callee
  | not (polVectorFast policy) || policyWidth policy/=W64
    || polProfile policy `notElem` [HostedBase,QosApp]=False
  | otherwise=name `elem` storeNames && calleeKind callee==Foreign ("fpr_g_"++mangleName name++"_call3")
      && calleeResult callee==TVal && calleeParams callee==replicate 3 TVal && calleeName callee==name

-- the tests and loads of a view, ending in `join`, whose parameters are the
-- three parts
viewBlocks :: Monad m => Builder m -> VId -> BId -> m ()
viewBlocks builder vec join=do
  let v=value builder
      label=newLabel builder
      enter b=begin builder b []
      constant n=v TInt (OConstInt n)
      load ty a offset=v ty (OLoad ty a offset)
  miss<-label
  address<-v TAddr (OAddress vec)
  zero<-constant 0
  one<-constant 1
  let guard p=do
        next<-label
        end builder (TCondBr p next [] miss [])
        enter next
      equal x n=constant n >>= \y->v TPred (OCmp Eq x y)
      flat kindOk flag=do
        count<-load TInt address (lengthOffset 8)
        columns<-load TInt address (columnCountOffset 8)
        equal columns 1 >>= guard
        kinds<-load TAddr address (kindsOffset 8)
        kind<-v TInt (OLoadByte kinds 0)
        kindOk kind
        directory<-load TAddr address (columnsOffset 8)
        column<-load TAddr directory 0
        base<-load TAddr column (columnBaseOffset 8)
        end builder (TBr join (if flag==one then [count,base,flag,count,zero] else [count,base,flag,zero,count]))
  isInteger<-v TPred (OTagTest vectorTypeId intRep vec)
  integer<-label
  checkFloat<-label
  end builder (TCondBr isInteger integer [] checkFloat [])
  enter integer
  flat (\kind->equal kind intKind >>= guard) one
  enter checkFloat
  v TPred (OTagTest vectorTypeId floatRep vec) >>= guard
  flat (\kind->do
    wide<-equal kind f64Kind
    ok<-label
    narrow<-label
    end builder (TCondBr wide ok [] narrow [])
    enter narrow
    equal kind f32Kind >>= guard
    end builder (TBr ok [])
    enter ok) zero
  enter miss
  end builder (TBr join [zero,address,zero,zero,zero])

-- Replace every view operation by its blocks: the simplifier's last pass, so
-- no target selects one. A run of parts of one handle in a block shares one
-- expansion; the block is split there and its remainder becomes the join.
expandViews :: Fn -> Fn
expandViews fn
  | not (any (any (\(Instr _ op)->viewOp op) . bInstrs) (fnBlocks fn))=fn
  | otherwise=
      let (blocks,(_,_,copies))=runState (mapM block (fnBlocks fn)) (nextV,nextB,[])
          -- a part asked for twice in one run is the first: its readers,
          -- wherever they are, read the first (same block, so it dominates them)
          rename x=maybe x id (lookup x copies)
      in fn {fnBlocks=[b {bInstrs=[Instr d (mapOpUses rename op) | Instr d op<-bInstrs b],bTerm=mapTermUses rename (bTerm b)}
                      | b<-concat blocks]}
  where
    viewOp op=case op of OVectorView {}->True;_->False
    nextV=1+maximum (0:[n | b<-fnBlocks fn,(VId n,_)<-blockDefs b])
    nextB=1+maximum (0:[n | b<-fnBlocks fn,BId n<-[bId b]])
    block b=case break (\(Instr _ op)->viewOp op) (bInstrs b) of
      (_,[])->pure [b]
      (before,rest@(Instr _ (OVectorView _ vec):_))->do
        let (run,after)=span (\(Instr _ op)->case op of OVectorView _ h->h==vec;_->False) rest
            parts=nub [which | Instr _ (OVectorView which _)<-run]
            first which=head [d | Instr (Just (d,_)) (OVectorView w _)<-run,w==which]
        modify (\(v,l,copies)->(v,l,[(d,first which) | which<-parts,Instr (Just (d,_)) (OVectorView w _)<-run,w==which,d/=first which]++copies))
        join<-freshBlock
        results<-mapM (\which->if which `elem` parts then pure (first which) else freshValue) [minBound..maxBound]
        made<-expansion (bId b) (bParams b) before vec join
        more<-block (Block join (zip results [TInt,TAddr,TInt,TInt,TInt]) after (bTerm b))
        pure (made++more)
      _->pure [b]
    expansion start params before vec join=do
      (_,done)<-execStateT (viewBlocks expander vec join) (Just (start,params,reverse before),[])
      pure (reverse done)

-- fresh value and block numbers and the repeated parts found; over them, the block being built (its
-- instructions newest first) and the blocks finished, newest first
type Fresh=State (Int,Int,[(VId,VId)])
type Expand=StateT (Maybe (BId,[(VId,Ty)],[Instr]),[Block]) Fresh

freshValue :: Fresh VId
freshValue=state (\(v,l,c)->(VId v,(v+1,l,c)))
freshBlock :: Fresh BId
freshBlock=state (\(v,l,c)->(BId l,(v,l+1,c)))

expander :: Builder Expand
expander=Builder
  { value = \ty op->do v<-lift freshValue;emitInto (Instr (Just (v,ty)) op);pure v,
    newLabel=lift freshBlock,
    newJoin = \_->(,) <$> lift freshBlock <*> lift freshValue,
    newJoinN = \tys->(,) <$> lift freshBlock <*> mapM (const (lift freshValue)) tys,
    begin = \b ps->modify (\(_,done)->(Just (b,ps,[]),done)),
    effect=emitInto . Instr Nothing,
    end = \term->modify (\(open,done)->case open of
      Just (b,ps,instrs)->(Nothing,Block b ps (reverse instrs) term:done)
      Nothing->error "Codegen.VectorRead: a terminator without an open block"),
    rare = \_->pure () }
  where
    emitInto :: Instr -> Expand ()
    emitInto i=modify (\(open,done)->case open of
      Just (b,ps,instrs)->(Just (b,ps,i:instrs),done)
      Nothing->error "Codegen.VectorRead: an instruction without an open block")

-- the cell's address when the index is inside the flat length; every other
-- case (a non-Int index, a miss, another shape) goes to `slow`
cellOf :: Monad m => Builder m -> View -> Index -> BId -> m VId
cellOf builder view index slow=do
  let v=value builder
      guard p=do
        next<-newLabel builder
        end builder (TCondBr p next [] slow [])
        begin builder next []
  i<-case index of
    Raw raw->pure raw
    Tagged boxed->v TPred (OIsInt boxed) >>= guard >> v TInt (OUntag boxed)
  zero<-v TInt (OConstInt 0)
  v TPred (OCmp Ge i zero) >>= guard
  v TPred (OCmp Lt i (viewLength view)) >>= guard
  v TAddr (OIndex (viewBase view) i)

boxedIndex :: Monad m => Builder m -> Index -> m VId
boxedIndex builder index=case index of
  Raw raw->value builder TVal (OTag raw)
  Tagged boxed->pure boxed

-- the element as the view's kind reads it: a raw Int (TInt) from an Int
-- column, the word itself (TVal) from a float column
lowerElement :: Monad m => Builder m -> Callee -> View -> Index -> VId -> m (VId,Ty)
lowerElement builder callee view index vec=do
  let v=value builder
      ty=case view of Ints {}->TInt;_->TVal
  (join,result)<-newJoin builder ty
  slow<-newLabel builder
  rare builder slow
  cursor<-cellOf builder view index slow
  case view of
    Ints {}->v TInt (OLoad TInt cursor 0) >>= \raw->end builder (TBr join [raw])
    Floats {}->v TVal (OLoad TVal cursor 0) >>= \bits->end builder (TBr join [bits])
    Mixed {}->do
      zero<-v TInt (OConstInt 0)
      isInteger<-v TPred (OCmp Ne (viewInteger view) zero)
      integer<-newLabel builder
      floating<-newLabel builder
      end builder (TCondBr isInteger integer [] floating [])
      begin builder integer []
      raw<-v TInt (OLoad TInt cursor 0)
      boxed<-v TVal (OTag raw)
      end builder (TBr join [boxed])
      begin builder floating []
      bits<-v TVal (OLoad TVal cursor 0)
      end builder (TBr join [bits])
  begin builder slow []
  i<-boxedIndex builder index
  answer<-v TVal (OCall callee [i,vec])
  -- the C entry answers a tagged Int for an Int element: by its type, an Int
  out<-case view of Ints {}->v TInt (OUntag answer);_->pure answer
  end builder (TBr join [out])
  begin builder join [(result,ty)]
  pure (result,ty)

-- An in-place store. Its answer is the handle it was given: the C entry
-- (vec.c h_set), which keeps every other case and its traps, returns its
-- argument too, and a store changes neither the length nor the column, so
-- the same value and the same view go on. The element is a raw Int the
-- lowering already holds (Left), or a word (Right): an Int column takes a
-- word only after the test that it is an Int.
lowerStore :: Monad m => Builder m -> Callee -> View -> Index -> Either VId VId -> VId -> m ()
lowerStore builder callee view index element vec=do
  let v=value builder
      intStore cursor slow=case element of
        Left raw->effect builder (OStore TInt cursor 0 raw)
        Right word->do
          small<-v TPred (OIsInt word)
          store<-newLabel builder
          end builder (TCondBr small store [] slow [])
          begin builder store []
          raw<-v TInt (OUntag word)
          effect builder (OStore TInt cursor 0 raw)
      asWord=case element of
        Left raw->v TVal (OTag raw)
        Right word->pure word
  join<-newLabel builder
  slow<-newLabel builder
  rare builder slow
  cursor<-cellOf builder view index slow
  case view of
    Ints {}->intStore cursor slow >> end builder (TBr join [])
    Floats {}->asWord >>= \word->effect builder (OStore TVal cursor 0 word) >> end builder (TBr join [])
    Mixed {}->do
      zero<-v TInt (OConstInt 0)
      isInteger<-v TPred (OCmp Ne (viewInteger view) zero)
      integer<-newLabel builder
      floating<-newLabel builder
      end builder (TCondBr isInteger integer [] floating [])
      begin builder integer []
      intStore cursor slow
      end builder (TBr join [])
      begin builder floating []
      word<-asWord
      effect builder (OStore TVal cursor 0 word)
      end builder (TBr join [])
  begin builder slow []
  i<-boxedIndex builder index
  word<-asWord
  _<-v TVal (OCall callee [i,word,vec])
  end builder (TBr join [])
  begin builder join []
