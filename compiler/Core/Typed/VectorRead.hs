{-# LANGUAGE FlexibleContexts #-}
-- Eliminate only an immediately destructured read pair. Keeping the tuple
-- pattern and its typed RHS together makes the handle-reuse proof explicit.
module Core.Typed.VectorRead (planReads) where
import Core.Typed.Syntax
import Core.Typed.Walk (mapChildrenM)
import qualified Core.VectorRead as Read
import Control.Monad.Writer
import Data.Monoid (Any(..))

-- The Bool reports whether any read pair was planned, so linked passes can
-- leave untouched products with their existing verification and erasure.
planReads :: Expr -> (Expr,Bool)
planReads e=let (child,Any sub)=runWriter (mapChildrenM planChild e) in
  case exprNode child of
    LetPattern p rhs body | TuplePattern [_,_]<-patNode p,
      (head',args)<-spine rhs [],Var (Global name _)<-exprNode head',
      Just op<-Read.fromSourceName name,
      length args==Read.indexArity op+1,
      let handle=last args,Var (Local _)<-exprNode handle ->
        (child {exprNode=LetPattern p (rhs {exprNode=VectorReadPair op (init args) handle}) body},True)
    _->(child,sub)
  where
    planChild x=let (x',planned)=planReads x in tell (Any planned) >> pure x'
    spine x args=case exprNode x of
      Note y->spine y args
      Apply f a->spine f (a:args)
      _->(x,args)
