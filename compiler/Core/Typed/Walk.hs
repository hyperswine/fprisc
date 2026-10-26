module Core.Typed.Walk (mapChildrenM, mapUpdateM, localUses, allBinders, renameUses, renameBinders,renameBinderNames) where
import Core.Typed.Syntax
import Core.Identity (BinderId)
import Data.Functor.Const (Const(..))
import Control.Monad.Identity
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

mapChildrenM :: Applicative m => (Expr -> m Expr) -> Expr -> m Expr
mapChildrenM f e = (\node -> e {exprNode=node}) <$> case exprNode e of
  Apply a b->Apply <$> f a <*> f b
  Lambda ps b->Lambda ps <$> f b
  Let p a b->Let p <$> f a <*> f b
  LetRec p a b->LetRec p <$> f a <*> f b
  If a b c->If <$> f a <*> f b <*> f c
  BoolTest b x->BoolTest b <$> f x
  Note x->Note <$> f x
  Construct n xs->Construct n <$> traverse f xs
  TupleValue xs->TupleValue <$> traverse f xs
  ListValue xs->ListValue <$> traverse f xs
  RecordValue fs->RecordValue <$> traverse (\(n,x)->(,) n <$> f x) fs
  RecordField x p->(`RecordField` p) <$> f x
  RecordUpdate x fs->RecordUpdate <$> f x <*> traverse (\(p,y)->(,) p <$> f y) fs
  PlannedUpdate x plan->PlannedUpdate <$> f x <*> mapUpdateM f plan
  ResultPipe a b->ResultPipe <$> f a <*> f b
  Sequence a b->Sequence <$> f a <*> f b
  LetPattern p a b->LetPattern p <$> f a <*> f b
  Match s xs as->Match s <$> traverse f xs <*> traverse alt as
  MatchTail s xs as k->MatchTail s <$> traverse f xs <*> traverse alt as <*> f k
  JoinCall label captures xs->JoinCall label captures <$> traverse f xs
  CodeCall label captures xs->CodeCall label captures <$> traverse f xs
  VectorBuild b x->VectorBuild b <$> f x
  CallRegion x->CallRegion <$> f x
  n->pure n
  where
    alt (Alternative ps gs b)=Alternative ps <$> traverse guard gs <*> f b
    guard (BoolGuard x)=BoolGuard <$> f x
    guard (PatternGuard p x)=PatternGuard p <$> f x

mapUpdateM :: Applicative m => (Expr -> m Expr) -> UpdatePlan -> m UpdatePlan
mapUpdateM f (UpdatePlan roots branches)=UpdatePlan roots <$> traverse branch branches
  where
    branch (UpdateBranch tid fields)=UpdateBranch tid <$> traverse (\(n,x)->(,) n <$> field x) fields
    field KeepField=pure KeepField
    field (ReplaceField x)=ReplaceField <$> f x
    field (NestedUpdate p)=NestedUpdate <$> mapUpdateM f p

localUses :: Expr -> [BinderId]
localUses = nub . go S.empty
  where
    bind ps scope=scope `S.union` S.fromList (map binderId ps)
    go scope e=case exprNode e of
      Var (Local uid)->[uid | uid `S.notMember` scope]
      ClosureValue _ captures->filter (`S.notMember` scope) captures
      JoinCall _ captures xs->filter (`S.notMember` scope) captures++concatMap (go scope) xs
      CodeCall _ captures xs->filter (`S.notMember` scope) captures++concatMap (go scope) xs
      Lambda ps b->go (bind ps scope) b
      Let p a b->go scope a++go (bind [p] scope) b
      LetRec p a b->let scoped=bind [p] scope in go scoped a++go scoped b
      LetPattern p a b->go scope a++go (bind (patternBinders p) scope) b
      Match _ xs as->concatMap (go scope) xs++concatMap (alt scope) as
      MatchTail _ xs as k->concatMap (go scope) xs++concatMap (alt scope) as++go scope k
      _->getConst (mapChildrenM (Const . go scope) e)
    alt scope (Alternative ps gs b)=guards (bind (concatMap patternBinders ps) scope) gs
      where
        guards s []=go s b
        guards s (BoolGuard x:rest)=go s x++guards s rest
        guards s (PatternGuard p x:rest)=go s x++guards (bind (patternBinders p) s) rest

allBinders :: Expr -> [Binder]
allBinders e = here++getConst (mapChildrenM (Const . allBinders) e)
  where
    here=case exprNode e of
      Lambda ps _->ps
      Let p _ _->[p]
      LetRec p _ _->[p]
      LetPattern p _ _->patternBinders p
      Match _ _ as->concatMap alt as
      MatchTail _ _ as _->concatMap alt as
      _->[]
    alt (Alternative ps gs _)=concatMap patternBinders ps++concat [patternBinders p | PatternGuard p _<-gs]

renameUses :: M.Map BinderId BinderId -> Expr -> Expr
renameUses names e=runIdentity $ do
  child<-mapChildrenM (pure . renameUses names) e
  pure child {exprNode=case exprNode child of
    Var (Local uid)->Var (Local (name uid))
    ClosureValue label captures->ClosureValue label (map name captures)
    JoinCall label captures xs->JoinCall label (map name captures) xs
    CodeCall label captures xs->CodeCall label (map name captures) xs
    n->n}
  where name uid=M.findWithDefault uid uid names

-- Clone introduced identities as well as their uses. Free lexical identities
-- are deliberately absent from the map and remain references to the caller.
renameBinders :: M.Map BinderId BinderId -> Expr -> Expr
renameBinders names = mapIntroduced binder . renameUses names
  where
    binder b=b {binderId=M.findWithDefault (binderId b) (binderId b) names}

-- Display names are not references. Hygiene changes binders alone; their
-- identity-based uses and captured identities keep the same resolution.
renameBinderNames :: M.Map BinderId String -> Expr -> Expr
renameBinderNames names=mapIntroduced (\b->b {binderName=M.findWithDefault (binderName b) (binderId b) names})

mapIntroduced :: (Binder -> Binder) -> Expr -> Expr
mapIntroduced binder=go
  where
    pattern' p=p {patNode=case patNode p of
      Bind b->Bind (binder b)
      ConstructorPattern n ps->ConstructorPattern n (map pattern' ps)
      TuplePattern ps->TuplePattern (map pattern' ps)
      RecordPattern fs->RecordPattern [(n,binder b) | (n,b)<-fs]
      n->n}
    guard (PatternGuard p x)=PatternGuard (pattern' p) x
    guard g=g
    alt (Alternative ps gs b)=Alternative (map pattern' ps) (map guard gs) b
    go e=let child=runIdentity (mapChildrenM (pure . go) e) in child {exprNode=case exprNode child of
      Lambda ps b->Lambda (map binder ps) b
      Let p a b->Let (binder p) a b
      LetRec p a b->LetRec (binder p) a b
      LetPattern p a b->LetPattern (pattern' p) a b
      Match s xs as->Match s xs (map alt as)
      MatchTail s xs as k->MatchTail s xs (map alt as) k
      n->n}
