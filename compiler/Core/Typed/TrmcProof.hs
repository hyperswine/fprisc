-- A syntactic capability proof for the private list builder. A payload's
-- LShape is NOT a proof of uniqueness of its containing cons cell. The only
-- external entry is a fresh Cons/Nil passed twice (root and cursor). Neither
-- pointer can escape, be inspected, or be passed to user code before finish.
module Core.Typed.TrmcProof (verifyBuilderFunction,verifyBuilderGraph,builderView) where
import Core.Typed.Syntax
import Core.Typed.Walk (mapChildrenM,localUses)
import Core.Identity (BinderId)
import Control.Monad (unless,when)
import Data.Functor.Const (Const(..))
import Data.List (elemIndex)
import qualified Data.Map.Strict as M

children e=getConst (mapChildrenM (Const . (:[])) e)
local u e=case exprNode e of Var (Local v)->u==v;_->False
nil e=case exprNode e of Construct "Nil" []->True;_->False
fresh e=case exprNode e of Construct "Cons" [_,t]->nil t;_->False
require why ok=unless ok (Left ("typed TRMC proof: "++why))

builderView :: Function -> Maybe (BinderId,BinderId,Expr)
builderView f=case exprNode (functionBody f) of ListBuilder r c b->Just (r,c,b);_->Nothing

verifyBuilderFunction :: Function -> Either String ()
verifyBuilderFunction f=case builderView f of
  Nothing->ordinary (functionBody f)
  Just (root,cursor,body)->do
    require "root/cursor must be distinct parameters" (root/=cursor && root `elem` ids && cursor `elem` ids)
    walk root cursor body
  where
    ids=map binderId (functionParameters f)
    ordinary e=case exprNode e of
      SetField {}->Left "typed TRMC proof: store outside a builder transition"
      ListBuilder {}->Left "typed TRMC proof: nested builder marker"
      _->mapM_ ordinary (children e)
    safe r c e=do
      require "builder pointer escaped or was inspected" (all (`notElem` localUses e) [r,c])
      ordinary e
      noReentry e
    -- The graph scanner exempts self calls only because the tail-transition
    -- proof checks them. A call hidden in an ordinary operand must not gain
    -- authority to mutate some other (possibly shared) root/cursor pair.
    noReentry e=do
      case exprNode e of
        CodeCall (CodeId n) _ _->require "builder reentry outside a tail transition" (n/=functionName f)
        _->pure ()
      mapM_ noReentry (children e)
    recur r c next e=case exprNode e of
      CodeCall (CodeId n) [] args | n==functionName f,length args==length ids->do
        let Just ri=elemIndex r ids;Just ci=elemIndex c ids
        require "root/cursor changed in recursive call" (local r (args!!ri) && local next (args!!ci))
        mapM_ (\(i,a)->if i==ri || i==ci then pure () else do
          safe r c a
          require "new cursor escaped through another argument" (next `notElem` localUses a)) (zip [0..] args)
      _->Left ("typed TRMC proof: store must lead directly to self tail call in "++functionName f++" (arity "++show (length ids)++"): "++show (exprNode e))
    walk r c e=case exprNode e of
      -- Allocation, link and tail call are one indivisible proof transition.
      Let cell rhs rest | fresh rhs ->case exprNode rest of
        Let unit store next | SetField base 1 value<-exprNode store,
          local c base,local (binderId cell) value->do
            safe r c rhs
            require "store result escapes" (binderId unit `notElem` localUses next)
            if local r next then pure () else recur r c (binderId cell) next
        _->ordinaryLet r c cell rhs rest
      Let unit store result | SetField base 1 value<-exprNode store,
        local c base,local r result->do
          safe r c value
          require "finish result type" (exprType result==exprType (functionBody f))
          require "store result escapes" (binderId unit `notElem` localUses result)
      Let b rhs rest->ordinaryLet r c b rhs rest
      Note x->walk r c x
      Sequence a b->safe r c a >> walk r c b
      If cond yes no->safe r c cond >> walk r c yes >> walk r c no
      MatchTail _ args alts fallback->do
        mapM_ (safe r c) args
        mapM_ (alt r c) alts
        walk r c fallback
      Fail _->pure ()
      Var _ | local r e->pure ()
      CodeCall {}->recur r c c e
      _->Left "typed TRMC proof: unsupported builder exit"
    ordinaryLet r c _ rhs rest=safe r c rhs >> walk r c rest
    alt r c (Alternative _ guards body)=mapM_ (guard r c) guards >> walk r c body
    guard r c (BoolGuard e)=safe r c e
    guard r c (PatternGuard _ e)=safe r c e

-- Verification of the closed graph prevents a type-correct call from granting
-- mutation authority over an input/shared cell. Builders cannot be closures,
-- imported entries, or source roots, and no ordinary call may enter one.
verifyBuilderGraph :: Function -> M.Map CodeId CodeFunction -> Either String ()
verifyBuilderGraph root codes=do
  require "source root is a builder" (case builderView root of Nothing->True;_->False)
  -- Earlier typed passes have no builders; their ordinary node verifier
  -- already rejects stores. Avoid a second whole-body walk in that case.
  when (not (M.null builders)) $ do
    mapM_ valid (M.elems builders)
    scan (functionBody root)
    mapM_ (scanCode . codeAsFunction) (M.elems codes)
  where
    builders=M.filter (maybe False (const True) . builderView . codeAsFunction) codes
    valid code=do
      require "builder must be private capture-free entry code"
        (codeKind code==EntryCode && null (codeCaptures code))
      -- Establish the parameter positions before checking any caller. A
      -- malformed marker must yield Left, not a failed elemIndex pattern.
      verifyBuilderFunction (codeAsFunction code)
    scanCode f=case builderView f of
      Nothing->scan (functionBody f)
      Just _->nested (functionBody f)
      where
        -- Self calls have already been checked by the transition proof.
        nested e=case exprNode e of
          CodeCall k _ args | k==CodeId (functionName f)->mapM_ scan args
          _->scanExcept nested e
    scan e=case exprNode e of
      Let cell rhs next | fresh rhs,
        CodeCall k [] args<-exprNode next,Just code<-M.lookup k builders,
        Just (r,c,_)<-builderView (codeAsFunction code)->do
          let ids=map binderId (codeParameters code)
              Just ri=elemIndex r ids;Just ci=elemIndex c ids
          require "builder start arity" (length args==length ids)
          require "builder start needs the same fresh cell twice" (local (binderId cell) (args!!ri) && local (binderId cell) (args!!ci))
          mapM_ (\(i,a)->unless (i==ri || i==ci) $ do
            require "fresh builder cell escapes at entry" (binderId cell `notElem` localUses a)
            scan a) (zip [0..] args)
          scan rhs
      _->scanExcept scan e
    scanExcept descend e=do
      case exprNode e of
        ClosureValue k _->require "builder escapes as a closure" (M.notMember k builders)
        CodeCall k _ _->require "builder call lacks fresh-cell authority" (M.notMember k builders)
        JoinCall k _ _->require "builder escapes as a join" (M.notMember k builders)
        Var (Global n _)->require "builder escapes as a global" (M.notMember (CodeId n) builders)
        _->pure ()
      mapM_ descend (children e)
