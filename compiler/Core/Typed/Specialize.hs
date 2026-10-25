{-# LANGUAGE FlexibleContexts #-}
-- Structure specialization transforms checked expressions and signatures.
-- Clone identities/arity and the existing source application gate are retained;
-- a local reference can never be mistaken for a same-spelled generic global.
module Core.Typed.Specialize
  (Context(..),Specialized,specialize,functions,cloneNames,declines,callingSchemes) where
import Core.Typed.Syntax
import Core.Typed.Walk
import Core.Typed.Instantiate
import Core.Typed.Verify
import Core.Identity
import Type.Syntax
import qualified Type.Substitution as U
import Ownership.TypeShape (linShapeT)
import Control.Monad.State.Strict
import Control.Monad (unless,forM,foldM)
import Data.Functor.Const
import Data.List (findIndex,nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Context=Context
  { typeContext :: TypeContext, globalSchemes :: M.Map String Scheme,
    genericParameters :: M.Map String [Int], structures :: S.Set String,
    memberEntries :: M.Map String String, eligibleCalls :: S.Set ExprId }
data Specialized=Specialized (M.Map String Function) (S.Set String) [(String,String)] (M.Map String Scheme)
functions (Specialized fs _ _ _)=fs
cloneNames (Specialized _ ns _ _)=ns
declines (Specialized _ _ ds _)=ds
callingSchemes (Specialized _ _ _ ss)=ss
data Problem=Deferred String | Corrupt String
data Work=Work {nextType :: Int,clones :: M.Map String Function,schemas :: M.Map String Scheme}

specialize :: Namespace -> Context -> M.Map String Function -> Either String Specialized
specialize (Namespace ns) context input=do
  unless (all (`M.member` globalSchemes context) (S.toList (structures context))) (Left "typed specialization: structure lacks a checked schema")
  mapM_ (\(n,positions)->do
    unless (all (>=0) positions && length positions==length (nub positions)) (Left "typed specialization: invalid parameter positions")
    case M.lookup n input of
      Just fn->unless (all (<length (functionParameters fn)) positions) (Left "typed specialization: parameter outside definition")
      Nothing->pure ()) (M.toList (genericParameters context))
  mapM_ (verifyFunction (typeContext context)) (M.elems input)
  (out,work,ds)<-foldM one (M.empty,Work start M.empty M.empty,[]) (M.toAscList input)
  let result=M.union out (clones work)
  mapM_ (verifyFunction (typeContext context)) (M.elems result)
  pure (Specialized result (M.keysSet (clones work)) ds (schemas work `M.union` globalSchemes context))
  where
    allVars=mconcat (map functionVars (M.elems input)
      ++[U.variables t | Forall _ _ t<-M.elems (globalSchemes context)])
    functionVars fn=U.variables (functionType fn)<>exprVars (functionBody fn)
      <>mconcat [U.variables t | b<-functionParameters fn++allBinders (functionBody fn),let Forall _ _ t=binderScheme b]
    exprVars e=U.variables (exprType e)<>getConst (mapChildrenM (Const . exprVars) e)<>mconcat (map patternVars (patterns e))
    patterns e=case exprNode e of
      LetPattern p _ _->[p]
      Match _ _ as->concatMap altPatterns as
      MatchTail _ _ as _->concatMap altPatterns as
      _->[]
    altPatterns (Alternative ps gs _)=ps++[p | PatternGuard p _<-gs]
    patternVars p=U.variables (patType p)<>case patNode p of
      ConstructorPattern _ ps->mconcat (map patternVars ps)
      TuplePattern ps->mconcat (map patternVars ps)
      _->mempty
    start=1+maximum (0:S.toList (fst allVars)++S.toList (snd allVars))
    bad=lift . Left . Corrupt
    deferred=lift . Left . Deferred
    require why ok=unless ok (bad why)
    TypeContext linears _=typeContext context
    generated ty node=Expr ty (linShapeT linears ty) Generated Nothing node
    one (out,work,ds) (name,fn)=case runStateT (walkFunction 0 fn) work of
      Left (Deferred why)->Right (out,work,ds++[(name,why)])
      Left (Corrupt why)->Left ("typed specialization "++name++": "++why)
      Right (fn',next)->Right (M.insert name fn' out,next,ds)
    scheme name=maybe (bad ("absent global schema "++name)) pure (M.lookup name (globalSchemes context))
    known e=case exprNode (unNote e) of Var (Global name _)|name `S.member` structures context->Just name;_->Nothing
    unNote e=case exprNode e of Note x->unNote x;_->e
    sourceId e=case exprOrigin e of Checked uid->Just uid;Reinstantiated uid->Just uid;_->Nothing
    eligible e=maybe False (`S.member` eligibleCalls context) (sourceId e)
    spine=go [] where go xs e=case exprNode e of Apply f a->go (a:xs) f;_->(e,xs)
    apply old head' args=do
      result<-foldM (\f arg->case exprType f of
        TFn a r->do require "rewritten call argument" (sameType a (exprType arg));pure (generated r (Apply f arg))
        _->bad "rewritten call has no argument arrow") head' args
      require "rewritten call result" (sameType (exprType result) (exprType old))
      pure result {exprOrigin=case exprOrigin old of Checked uid->Reinstantiated uid;o->o,exprOffset=exprOffset old}
    walkFunction depth fn=do b<-walk depth (functionBody fn);pure fn {functionBody=b}
    walk depth e=case exprNode e of
      Apply _ _->do
        let (head0,args0)=spine e
        args<-mapM (walk depth) args0
        head'<-walk depth head0
        case exprNode (unNote head') of
          Var (Global name _)|eligible e,Just positions<-M.lookup name (genericParameters context),
            all (<length args) positions,Just picked<-mapM (\i->(,) i <$> known (args!!i)) positions->do
              target<-getClone depth name picked
              sc<-gets ((M.! target) . schemas)
              let keep=[a | (i,a)<-zip [0..] args,i `notElem` positions]
                  dropArgs ty=go 0 ty where
                    go i (TFn a b)=if i `elem` positions then go (i+1) b else TFn a (go (i+1) b)
                    go _ t=t
                  callee=generated (dropArgs (exprType head')) (Var (Global target sc))
              apply e callee keep
          _->apply e head' args
      _->mapChildrenM (walk depth) e
    getClone depth name picks=do
      let target=name++concat ["#"++s | (_,s)<-picks]
      existing<-gets (M.member target . clones)
      if existing then pure target else do
        require "specialization recursion exceeded its source limit" (depth<=32)
        template<-maybe (deferred ("callee lacks typed source: "++name)) pure (M.lookup name input)
        sourceSchema<-scheme name
        require "definition/calling schema disagreement" (instanceOf sourceSchema (functionType template))
        first<-gets nextType
        let fresh (acc,flex,next) (i,s)=
              let sc=globalSchemes context M.! s
                  (ty,vars,next')=U.freshen next sc
              in (acc++[(i,s,ty)],flex<>vars,next')
            (arguments,newVars,after)=foldl fresh ([],mempty,first) picks
            rigid=U.schemeVariables sourceSchema<>mconcat [U.schemeVariables (globalSchemes context M.! s) | (_,s)<-picks]
            bodyVars=U.variables (functionType template)
            flexible=(fst bodyVars S.\\ fst rigid,snd bodyVars S.\\ snd rigid)<>newVars
            pairs=[(binderType (functionParameters template!!i),ty) | (i,_,ty)<-arguments]
        (sub,next)<-either bad pure (U.unifyTypes flexible after pairs)
        modify (\w->w {nextType=next})
        let copied=instantiateFunction (Namespace (ns++"/struct/"++target)) (typeContext context) sub template
            fixed=[(i,s,U.applyType sub ty) | (i,s,ty)<-arguments]
        clone<-dropParameters target fixed copied
        let signature=functionType clone
            -- Only the original ambient variables stay rigid. New structure
            -- quantifiers and untouched ordinary parameters remain generic.
            rigid'=mconcat ([U.variables (U.applyType sub (TV v)) | v<-S.toList (fst rigid)]
                      ++[U.variables (U.applyType sub (TRec (RV v))) | v<-S.toList (snd rigid)])
            vars=U.variables signature
            cloneSchema=Forall (S.toAscList (fst vars S.\\ fst rigid')) (S.toAscList (snd vars S.\\ snd rigid')) signature
        require "clone collides with a source global" (M.notMember target (globalSchemes context))
        modify (\w->w {clones=M.insert target clone (clones w),schemas=M.insert target cloneSchema (schemas w)})
        converted<-walkFunction (depth+1) clone
        either bad pure (verifyFunction (typeContext context) converted)
        modify (\w->w {clones=M.insert target converted (clones w)})
        pure target
    dropParameters target picked fn=case exprNode (functionBody fn) of
      Match (FunctionMatch _) args alts->do
        positions<-forM picked $ \(i,s,ty)->do
          let uid=binderId (functionParameters fn!!i)
          j<-maybe (bad "signature parameter is not a source match argument") pure
            (findIndex (\e->case exprNode e of Var (Local v)->uid==v;_->False) args)
          pure (j,s,ty)
        -- Preserve the source specializer's existing last-clause template.
        chosen<-case reverse alts of a:_->pure a;_->bad "empty generic definition"
        alternative<-fixAlternative positions chosen
        let remove xs=[x | (i,x)<-zip [0..] xs,i `notElem` map (\(j,_,_)->j) positions]
            ps=[p | (i,p)<-zip [0..] (functionParameters fn),i `notElem` map (\(j,_,_)->j) picked]
            body=(functionBody fn) {exprNode=Match (FunctionMatch target) (remove args) [alternative]}
        pure (Function target ps body)
      _->bad "generic definition lost its checked source clauses"
    fixAlternative positions (Alternative ps gs body)=do
      substitutions<-forM positions $ \(i,s,ty)->case patNode (ps!!i) of
        Bind b->do sc<-scheme s;pure (binderId b,generated ty (Var (Global s sc)))
        _->bad "signature parameter is not a binder"
      let replace=M.fromList substitutions
          selected=S.fromList [s | (_,s,_)<-positions]
          rewrite e=do
            child<-mapChildrenM rewrite e
            case exprNode child of
              Var (Local uid)|Just actual<-M.lookup uid replace->do
                require "dictionary substitution type" (sameType (exprType child) (exprType actual))
                pure actual {exprOrigin=exprOrigin child,exprOffset=exprOffset child}
              RecordField base (field:rest)|Var (Global s _)<-exprNode (unNote base),s `S.member` selected->do
                memberType<-maybe (bad "dictionary member lacks a checked type") pure (fieldType (exprType base) [field])
                let raw=s++"."++field;entry=M.findWithDefault raw raw (memberEntries context)
                sc<-scheme entry
                -- A record member may already capture hidden layout args.
                -- Its checked value then has a different callable shape from
                -- the raw global; retain the semantic field access instead.
                if instanceOf sc memberType then do
                  let ref=generated memberType (Var (Global entry sc))
                  pure child {exprNode=if null rest then exprNode ref else RecordField ref rest}
                else pure child
              _->pure child
          guard (BoolGuard e)=BoolGuard <$> rewrite e
          guard (PatternGuard p e)=PatternGuard p <$> rewrite e
      gs'<-mapM guard gs;body'<-rewrite body
      pure (Alternative [p | (i,p)<-zip [0..] ps,i `notElem` map (\(j,_,_)->j) positions] gs' body')
