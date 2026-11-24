{-# LANGUAGE FlexibleContexts #-}
-- Eliminate only an immediately destructured read pair. Keeping the tuple
-- pattern and its typed RHS together makes the handle-reuse proof explicit.
module Core.Typed.VectorRead (planReads) where
import Core.Typed.Syntax
import Core.Typed.Walk (localUses,mapChildrenM)
import qualified Core.VectorRead as Read
import Control.Monad.Writer
import Data.Monoid (Any(..))

-- The Bool reports whether any read pair was planned, so linked passes can
-- leave untouched products with their existing verification and erasure.
planReads :: Expr -> (Expr,Bool)
planReads e=let (child,Any sub)=runWriter (mapChildrenM planChild e) in
  case exprNode child of
    LetPattern p rhs body
      | TuplePattern [_,_]<-patNode p, Just (op,indices,handle)<-readOfLocal rhs ->
          (child {exprNode=LetPattern p (rhs {exprNode=VectorReadPair op indices handle}) body},True)
    -- Closure conversion lowers `case Vec.get i v of (x, v2) -> …` to
    -- `let sb = Vec.get i v in matchtail [sb] [(x, v2) -> body] fb`.
    -- When the single alternative has no guards, an irrefutable 2-tuple
    -- pattern, and `sb` is unused in `body`, it is identical to the
    -- tuple-pattern binding above and plans the same handle-reusing read.
    Let sb rhs m
      | MatchTail CaseMatch [x] [Alternative [p] [] body] _<-exprNode m,
        Var (Local sid)<-exprNode x,
        sid==binderId sb,
        TuplePattern [_,_]<-patNode p,
        irrefutable p,
        sid `notElem` localUses body,
        Just (op,indices,handle)<-readOfLocal rhs ->
          (child {exprNode=LetPattern p (rhs {exprNode=VectorReadPair op indices handle}) body},True)
    Match CaseMatch [scrutinee] [Alternative [p] [] body]
      | TuplePattern [_,_]<-patNode p,
        irrefutable p,
        Just (op,indices,handle)<-readOfLocal scrutinee ->
          (child {exprNode=LetPattern p (scrutinee {exprNode=VectorReadPair op indices handle}) body},True)
    _->(child,sub)
  where
    planChild x=let (x',planned)=planReads x in tell (Any planned) >> pure x'
    spine x args=case exprNode x of
      Note y->spine y args
      Apply f a->spine f (a:args)
      _->(x,args)
    -- a source-named vector read applied to its index (none for len) and
    -- a handle that is an evaluated local
    readOfLocal rhs=
      let (head',args)=spine rhs []
       in do
            op<-case exprNode head' of
              Var (Global name _)->Read.fromSourceName name
              _->Nothing
            if length args==Read.indexArity op+1
              then case exprNode (last args) of
                Var (Local _)->Just (op,init args,last args)
                _->Nothing
              else Nothing
    irrefutable pat=case patNode pat of
      Bind _->True
      Wildcard->True
      TuplePattern ps->all irrefutable ps
      _->False
