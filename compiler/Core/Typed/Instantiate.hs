-- Apply a checked type instantiation and clone every introduced term identity.
-- Quantified local schemes retain scope, and ownership shapes follow the
-- instantiated types rather than copying a now-stale unrestricted annotation.
module Core.Typed.Instantiate (instantiateFunction) where
import Core.Typed.Syntax
import Core.Typed.Walk
import Core.Identity
import Type.Substitution
import Ownership.TypeShape (linShapeT)
import qualified Data.Map.Strict as M
import Control.Monad.Identity

instantiateFunction :: Namespace -> TypeContext -> Substitution -> Function -> Function
instantiateFunction namespace (TypeContext linears _) sub input=input
  {functionParameters=map binder params,functionBody=expr (renameBinders names (functionBody input))}
  where
    originals=functionParameters input
    ids=originals++allBinders (functionBody input)
    names=M.fromList [(binderId b,BinderId namespace i) | (i,b)<-zip [0..] ids]
    params=[b {binderId=names M.! binderId b} | b<-originals]
    ty=applyType sub
    binder b=let sc=applyScheme sub (binderScheme b)
                 b'=b {binderScheme=sc}
             in b' {binderShape=linShapeT linears (binderType b')}
    pattern' p=p {patType=ty (patType p),patNode=case patNode p of
      Bind b->Bind (binder b)
      ConstructorPattern n ps->ConstructorPattern n (map pattern' ps)
      TuplePattern ps->TuplePattern (map pattern' ps)
      RecordPattern fs->RecordPattern [(n,binder b) | (n,b)<-fs]
      node->node}
    guard (PatternGuard p x)=PatternGuard (pattern' p) x
    guard g=g
    alt (Alternative ps gs b)=Alternative (map pattern' ps) (map guard gs) b
    expr e=let child=runIdentity (mapChildrenM (pure . expr) e)
               origin=case exprOrigin e of Checked uid->Reinstantiated uid;other->other
           in child {exprType=ty (exprType e),exprShape=linShapeT linears (ty (exprType e)),exprOrigin=origin,
             exprNode=case exprNode child of
               Var (Global n sc)->Var (Global n (applyScheme sub sc))
               Lambda ps b->Lambda (map binder ps) b
               Let b a body->Let (binder b) a body
               LetRec b a body->LetRec (binder b) a body
               LetPattern p a b->LetPattern (pattern' p) a b
               Match s xs as->Match s xs (map alt as)
               MatchTail s xs as k->MatchTail s xs (map alt as) k
               node->node}
