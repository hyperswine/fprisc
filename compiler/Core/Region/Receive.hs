-- Readiness evidence for a leading receive. Queries never evaluate source
-- operands: a selective sender must be an already-evaluated parameter/alias.
-- Any effectful/ambiguous prefix conservatively ends the previous turn.
module Core.Region.Receive (coreProbe,typedProbe) where
import Core.Region.Syntax
import Core.Syntax
import qualified Core.Typed.Syntax as T
import Core.Primitives (entryTickName)
import qualified Data.Map.Strict as M

classify name count sender=case (name,count) of
  ("receive",1)->AnyMessage
  ("receiveFrom",2)->maybe UnknownReceive SenderMessage sender
  ("receiveFromRes",2)->maybe UnknownReceive SenderMessageOrDead sender
  ("receiveRes",1)->ResultMessage
  ("receiveNow",1)->NonBlocking
  ("receiveFromNow",2)->NonBlocking
  _->UnknownReceive

coreProbe :: [String] -> Core -> ReceiveProbe
coreProbe ps=walk (M.fromList (zip ps [0..]))
  where
    index env (CVar x)=M.lookup x env
    index _ _=Nothing
    simple env e=case e of CVar x->M.member x env;CInt _->True;CMk _ _ []->True;_->False
    spine (CApp f a) as=spine f (a:as)
    spine f as=(f,as)
    direct env e=case spine e [] of
      (CVar name,args) | name `notElem` M.keys env,all (simple env) args->
        classify name (length args) (case args of [_,peer]->index env peer;_->Nothing)
      _->UnknownReceive
    harmless env e=simple env e || case spine e [] of
      (CVar name,[arg])->name==entryTickName && simple env arg
      _->False
    walk env e=case e of
      CLet x rhs rest | harmless env rhs->walk (case index env rhs of
        Just i->M.insert x i env;_->M.delete x env) rest
      CLet _ rhs _->direct env rhs
      -- Erased matches bind their scrutinee before dispatching.
      _->direct env e

typedProbe :: [T.Binder] -> T.Expr -> ReceiveProbe
typedProbe ps=walk (M.fromList (zip (map T.binderId ps) [0..]))
  where
    index env e=case T.exprNode e of T.Var (T.Local uid)->M.lookup uid env;T.Note x->index env x;_->Nothing
    simple env e=case T.exprNode e of
      T.Var (T.Local uid)->M.member uid env
      T.IntValue _->True;T.BoolValue _->True;T.Construct _ []->True
      T.Note x->simple env x
      _->False
    spine e as=case T.exprNode e of T.Apply f a->spine f (a:as);T.Note x->spine x as;_->(e,as)
    direct env e=case spine e [] of
      (f,args) | T.Var (T.Global name _)<-T.exprNode f,all (simple env) args->
        classify name (length args) (case args of [_,peer]->index env peer;_->Nothing)
      _->UnknownReceive
    harmless env e=simple env e || case T.exprNode e of T.EntryTick->True;T.Note x->harmless env x;_->False
    bind env pattern value=case T.patNode pattern of
      T.Bind b->Just (case index env value of Just i->M.insert (T.binderId b) i env;_->M.delete (T.binderId b) env)
      T.Wildcard->Just env
      _->Nothing
    walk env e=case T.exprNode e of
      T.Note x->walk env x
      T.Let b rhs rest | harmless env rhs->walk (case index env rhs of
        Just i->M.insert (T.binderId b) i env;_->M.delete (T.binderId b) env) rest
      T.Let _ rhs _->direct env rhs
      T.LetPattern pattern rhs rest | harmless env rhs,Just next<-bind env pattern rhs->walk next rest
      T.LetPattern _ rhs _->direct env rhs
      T.Sequence rhs rest | harmless env rhs->walk env rest
      T.Sequence rhs _->direct env rhs
      -- Function-clause elaboration binds irrefutable source names to the
      -- physical parameter bank. Keep those aliases by binder identity.
      T.MatchTail (T.FunctionMatch _) args [T.Alternative patterns [] body] _
        | all (simple env) args,Just next<-foldl (\acc (pattern,value)->acc >>= \scope->bind scope pattern value) (Just env) (zip patterns args)->walk next body
      T.MatchTail _ (first:_) _ _->direct env first
      _->direct env e
