{-# LANGUAGE FlexibleContexts #-}
-- A checked, parametric transport may execute arbitrary work on its control
-- arguments. Keep that call (including recursion and entry fuel), but carry
-- Unit through it when the caller already owns every field of its result.
module Core.Typed.BaseTransport (specializeTransport) where

import Core.Identity
import Core.Typed.Syntax
import Core.Typed.Program
import Core.Typed.Monomorphize (monomorphizeSelectedWithOrigins)
import Core.Typed.Walk (localUses,mapChildrenM)
import Core.Typed.Verify (instanceOf)
import Ownership.Shape (isLin)
import Ownership.TypeShape (linShapeT)
import Type.Syntax
import Type.Substitution (variables)
import Control.Monad (guard,foldM)
import Control.Monad.State.Strict
import Data.Functor.Const
import Data.Either (isRight)
import Data.Monoid (Any(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

application :: Expr -> (Expr,[Expr])
application e=go e []
  where go f args=case exprNode f of
          Apply callee x->go callee (x:args)
          _->(f,args)

-- Every successful return must yield the very same local. A control
-- expression can print, throw or diverge, but must never see the payload.
forwarded :: Function -> Maybe Int
forwarded fn=do
  TV v<-pure (exprType (functionBody fn))
  [(index,carrier)]<-pure [(i,p) | (i,p)<-zip [0..] params,binderType p==TV v]
  guard (all (\p->binderId p==binderId carrier || S.notMember v (fst (variables (binderType p)))) params)
  (returns,recurs)<-tailProof index (S.singleton (binderId carrier)) (functionBody fn)
  guard (getAny returns && getAny recurs)
  pure index
  where
    params=functionParameters fn
    alias ids e=case exprNode e of
      Var (Local uid)->uid `S.member` ids
      Note x->alias ids x
      _->False
    independent ids=all (`S.notMember` ids) . localUses
    tailProof _ ids e | alias ids e=Just (Any True,Any False)
    tailProof i ids e=case exprNode e of
      Note x->tailProof i ids x
      If c a b | independent ids c->(<>) <$> tailProof i ids a <*> tailProof i ids b
      Sequence a b | independent ids a->tailProof i ids b
      Let p a b | alias ids a->tailProof i (S.insert (binderId p) ids) b
                | independent ids a->tailProof i ids b
      Match _ xs alts->mconcat <$> traverse (branch xs) alts
      Apply _ _ | (f,args)<-application e, Var (Global n _)<-exprNode f,
        n==functionName fn,length args==length params,
        and [if j==i then alias ids x else independent ids x | (j,x)<-zip [0..] args]->Just (Any False,Any True)
      Fail _->Just mempty
      _->Nothing
      where
        branch xs (Alternative ps [] b) | length xs==length ps=
          foldM bind ids (zip xs ps) >>= \scope->tailProof i scope b
        branch _ _=Nothing
        bind scope (x,p)
          | alias ids x=case patNode p of
              Bind b->Just (S.insert (binderId b) scope)
              Wildcard->Just scope
              _->Nothing
          | independent ids x=Just scope
          | otherwise=Nothing

specializeTransport :: Bool -> S.Set String -> S.Set String -> Program
  -> Either String (Program,[(String,String)],M.Map String String)
specializeTransport reporting pinned retained input
  | M.null proofs || M.null changed=pure (input,declines,M.empty)
  | otherwise=do
      checked<-programWithAssumptions (programNamespace input) (programTypes input)
        (programSchemas input) (programArities input) (changed `M.union` source) (programAssumptions input)
      (output,notes,origins)<-monomorphizeSelectedWithOrigins (\n ty->S.member (n,ty) witnesses) pinned retained checked
      pure (output,declines++notes,origins)
  where
    source=programFunctions input
    proofs=M.mapMaybe forwarded (M.withoutKeys source pinned)
    Namespace ns=programNamespace input
    TypeContext linears constructors=programTypes input
    generated at ty=Expr ty (linShapeT linears ty) Generated (exprOffset at)
    (changed,(_,witnesses))=runState (M.traverseWithKey rewrite owners) (0::Int,S.empty)
    owners=M.filter (\fn->variables (functionType fn)==mempty && contains (functionBody fn)) source
    declines
      | reporting=S.toAscList (M.foldMapWithKey (\owner fn->refusals owner (functionBody fn)) source)
      | otherwise=[]
    refusals owner e=here<>getConst (mapChildrenM (Const . refusals owner) e)
      where here=case site e of
              Just (Left why)->S.singleton (owner,why)
              _->S.empty
    contains e=maybe False isRight (site e) || getAny (getConst (mapChildrenM (Const . Any . contains) e))
    rewrite _ fn=do
      body<-walk (functionBody fn)
      pure fn {functionBody=body}
    walk e=do
      child<-mapChildrenM walk e
      case site child of
        Just (Right (name,schema,i,args,p,body,controlTy,results))->do
          let enter=generated child controlTy (Var (Global name schema))
              call f (x,r)=generated child r (Apply f x)
          modify' (\(serial,used)->(serial,S.insert (name,controlTy) used))
          -- Capture the other arguments in evaluation order, including those
          -- following the aggregate. The constructor call keeps its own tick.
          steps<-mapM (argument child i p) (zip [0..] args)
          let control=foldl call enter (zip (map snd steps) results)
              finish=generated child (exprType body) (Sequence control body)
          pure (foldr (\(wrap,_) rest->wrap rest) finish steps)
        _->pure child
    argument at i p (j,x)
      | j==i=pure (\rest->generated at (exprType rest) (Match CaseMatch [x] [Alternative [p] [] rest]),
                   generated at tUnit (Construct "Unit" []))
      | otherwise=do
          (serial,used)<-get
          put (serial+1,used)
          let b=Binder (BinderId (Namespace (ns++"/base-transport")) serial) ("$transport"++show serial)
                  (Forall [] [] (exprType x)) (exprShape x)
          pure (\rest->generated at (exprType rest) (Let b x rest),generated x (exprType x) (Var (Local (binderId b))))
    site e=do
      (rhs,p,body)<-case exprNode e of
        Match CaseMatch [x] [Alternative [pat] [] b]->Just (x,pat,b)
        LetPattern pat x b->Just (x,pat,b)
        _->Nothing
      let (callee,args)=application rhs
      Var (Global n _) <-pure (exprNode callee)
      guard (case patNode p of TuplePattern _->True;ConstructorPattern _ _->True;_->False)
      fn<-M.lookup n source
      TV _<-pure (exprType (functionBody fn))
      guard (length (functionParameters fn)==length args)
      schema<-M.lookup n (programSchemas input)
      let refuse reason=Left ("tagged call to "++n++": "++reason)
      pure $ case M.lookup n proofs of
        Nothing->refuse "no proof of a private recursive entry forwarding one unchanged argument"
        Just i | payload:_<-drop i args->
          let args'=[if j==i then tUnit else exprType x | (j,x)<-zip [0..] args]
          in case scanr TFn tUnit args' of
            ty:results
              | variables (exprType callee)/=mempty->refuse "open calling type"
              | isLin (exprShape payload)->refuse "linear payload requires the original ownership boundary"
              | not (known payload p)->refuse "the constructor and its immediate field reader are not statically matched"
              | instanceOf schema ty && M.member "Unit" constructors->Right (n,schema,i,args,p,body,ty,results)
            _->refuse "control instance does not satisfy the published calling scheme"
        _->refuse "carrier position outside the saturated call"
    known x p=case (exprNode x,patNode p) of
      (TupleValue fields,TuplePattern ps)->fieldsMatch fields ps
      (Construct n fields,ConstructorPattern m ps)->n==m && fieldsMatch fields ps
      (_,ConstructorPattern m ps) | (callee,fields)<-application x,
        Var (Global n _)<-exprNode callee,n==m,Just fn<-M.lookup n source,
        Construct k _<-exprNode (functionBody fn),k==n,M.member n constructors->fieldsMatch fields ps
      _->False
    fieldsMatch xs ps=not (null xs) && length xs==length ps && all simple ps
    simple p=case patNode p of
      Bind _->True
      Wildcard->True
      _->False
