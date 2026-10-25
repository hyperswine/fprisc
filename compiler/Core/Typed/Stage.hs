-- Native application groups before erasure/specialization. Known entries keep
-- their physical saturation boundary; unknown callable groups snapshot their
-- operands before a later pass can replace the callee with known code.
module Core.Typed.Stage
  (StagedFunction,stageFunction,stagedFunction,verifyStagedFunction,
   StagedCalls,stageCalls,stagedClosed,verifyStagedCalls) where
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Verify (verifyFunction)
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Identity
import Type.Syntax (Type(..),Scheme(..))
import Ownership.TypeShape (linShapeT)
import Compiler.VectorLayout (builderArity)
import Control.Monad (unless,foldM)
import Control.Monad.State.Strict
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data StagedFunction=StagedFunction (M.Map String Int) Function
data StagedCalls=StagedCalls (M.Map String Int) ClosedFunction
type Staging=StateT Int (Either String)
stagedFunction :: StagedFunction -> Function
stagedFunction (StagedFunction _ fn)=fn
stagedClosed :: StagedCalls -> ClosedFunction
stagedClosed (StagedCalls _ closed)=closed

-- Run before closure conversion: lexical arity evidence must reach a nested
-- lambda before capture renaming replaces the outer binding by a parameter.
stageFunction :: Namespace -> TypeContext -> M.Map String Int -> Function -> Either String StagedFunction
stageFunction (Namespace ns) types globals input=do
  verifyFunction types input
  validGlobals globals
  let context=makeContext types globals M.empty [input]
  fn<-normalize (Namespace (ns++"/staging/"++functionName input++"/source")) context input
  let output=StagedFunction globals fn
  verifyStagedFunction types output
  pure output

-- The same transformation remains available to later typed closed passes.
-- They may add explicit CodeCall expressions with another saturation boundary.
stageCalls :: Namespace -> TypeContext -> M.Map String Int -> ClosedFunction -> Either String StagedCalls
stageCalls (Namespace ns) types globals input=do
  verifyClosed types input
  validGlobals globals
  let functions=closedRoot input:map codeAsFunction (M.elems (closedCode input))
      context=makeContext types globals (closedContracts input) functions
      run role=normalize (Namespace (ns++"/staging/"++functionName (closedRoot input)++"/"++role)) context
      code c=do
        fn<-run ("code/"++show (codeId c)) (codeAsFunction c)
        pure c {codeBody=functionBody fn}
  closed<-mapClosed types (run "root") code input
  let output=StagedCalls globals closed
  verifyStagedCalls types output
  pure output

validGlobals :: M.Map String Int -> Either String ()
validGlobals globals=unless (all (>=0) (M.elems globals)) (Left "typed staging: negative global arity")
data Context=Context [String] (M.Map String Int) (M.Map CodeId CodeContract) (S.Set BinderId) (S.Set String)
makeContext :: TypeContext -> M.Map String Int -> M.Map CodeId CodeContract -> [Function] -> Context
makeContext (TypeContext linears _) globals contracts functions=Context linears globals contracts used names
  where
    binders=concat [functionParameters f++allBinders (functionBody f) | f<-functions]
    used=S.fromList (map binderId binders)
    names=S.fromList (map binderName binders++map functionName functions)
      `S.union` S.unions (map (globalNames . functionBody) functions)
    globalNames e=(case exprNode e of
      Var (Global n _)->S.singleton n
      _->S.empty)<>getConst (mapChildrenM (Const . globalNames) e)

normalize :: Namespace -> Context -> Function -> Either String Function
normalize namespace (Context linears globals contracts used names) input=do
  body<-evalStateT (go namespace M.empty (functionBody input)) 0
  pure input {functionBody=body}
  where
    generated ty offset node=Expr ty (linShapeT linears ty) Generated offset node
    newBinder :: Namespace -> Expr -> Staging Binder
    newBinder namespace rhs=do
      n<-get
      put (n+1)
      let uid=BinderId namespace n;name="$typed_stage_"++show n
      if uid `S.member` used || name `S.member` names then newBinder namespace rhs
      else pure (Binder uid name (Forall [] [] (exprType rhs)) (exprShape rhs))
    ref b=generated (binderType b) Nothing (Var (Local (binderId b)))
    binding b rhs body=generated (exprType body) (exprOffset rhs) (Let b rhs body)
    apply :: Expr -> Expr -> Staging Expr
    apply fn arg=case exprType fn of
      TFn _ result->pure (generated result (exprOffset fn) (Apply fn arg))
      _->lift (Left "typed staging: application lost its checked arrow")
    app :: Expr -> [Expr] -> Staging Expr
    app fn args=foldM apply fn args
    snapshot :: Namespace -> Expr -> (Expr -> Staging Expr) -> Staging Expr
    snapshot namespace rhs continuation
      | ready globals rhs=continuation rhs
      | otherwise=do
          b<-newBinder namespace rhs
          body<-continuation (ref b)
          pure (binding b rhs body)
    unknown :: Namespace -> Expr -> [Expr] -> Staging Expr
    unknown namespace fn args=snapshot namespace fn $ \head'->do
      let arguments [] done=app head' (reverse done)
          arguments (x:xs) done=snapshot namespace x (\value->arguments xs (value:done))
      if length args>1 then arguments args [] else app head' args
    go :: Namespace -> M.Map BinderId Int -> Expr -> Staging Expr
    go namespace env e=case exprNode e of
      Let b rhs body->do
        let scope=case arity globals contracts env rhs of
              Just n | n>0->M.insert (binderId b) n env
              _->env
        rhs'<-go namespace env rhs
        body'<-go namespace scope body
        pure e {exprNode=Let b rhs' body'}
      LetRec b rhs body->do
        let scope=extend globals contracts env b rhs
        rhs'<-go namespace scope rhs
        body'<-go namespace scope body
        pure e {exprNode=LetRec b rhs' body'}
      Apply {}->do
        let (head0,args0)=spine e []
        head'<-go namespace env head0
        args<-mapM (go namespace env) args0
        result<-case arity globals contracts env head0 of
          Just n | n>0, length args>n->do
            prefix<-app head' (take n args)
            b<-newBinder namespace prefix
            body<-unknown namespace (ref b) (drop n args)
            pure (binding b prefix body)
          Just n | n>0->app head' args
          _ | unregisteredGlobal globals head0->app head' args
          _->unknown namespace head' args
        pure result {exprOrigin=exprOrigin e,exprOffset=exprOffset e}
      _->mapChildrenM (go namespace env) e

verifyStagedFunction :: TypeContext -> StagedFunction -> Either String ()
verifyStagedFunction types (StagedFunction globals fn)=do
  verifyFunction types fn
  verifyGroups globals M.empty (functionBody fn)

verifyStagedCalls :: TypeContext -> StagedCalls -> Either String ()
verifyStagedCalls types (StagedCalls globals closed)=do
  verifyClosed types closed
  let functions=closedRoot closed:map codeAsFunction (M.elems (closedCode closed))
  mapM_ (verifyGroups globals (closedContracts closed) . functionBody) functions

verifyGroups :: M.Map String Int -> M.Map CodeId CodeContract -> Expr -> Either String ()
verifyGroups globals contracts=check M.empty
  where
    require message ok=unless ok (Left ("typed staging: "++message))
    check env e=case exprNode e of
      Lambda ps body->do
        require "a callable lambda needs an ordinary parameter" (not (null ps))
        check env body
      Let b rhs body->do
        check env rhs
        check (extend globals contracts env b rhs) body
      LetRec b rhs body->do
        let scope=extend globals contracts env b rhs
        check scope rhs
        check scope body
      Apply {}->do
        let (head',args)=spine e []
        case arity globals contracts env head' of
          Just n | n>0->require "known saturation boundary is not explicit" (length args<=n)
          _ | unregisteredGlobal globals head'->pure ()
          _->do
            require "computed head is not evaluated before its arguments" (ready globals head')
            require "unknown call arguments are not snapshotted" (length args<=1 || all (ready globals) args)
        check env head'
        mapM_ (check env) args
      _->mapChildrenM (\child->check env child>>pure child) e>>pure ()

extend :: M.Map String Int -> M.Map CodeId CodeContract -> M.Map BinderId Int -> Binder -> Expr -> M.Map BinderId Int
extend globals contracts env b rhs=case arity globals contracts env rhs of
  Just n | n>0->M.insert (binderId b) n env
  _->env

-- An arrow count is not physical arity: a CAF or a one-argument function may
-- return another callable. Only producer metadata and captured code IDs count.
arity :: M.Map String Int -> M.Map CodeId CodeContract -> M.Map BinderId Int -> Expr -> Maybe Int
arity globals contracts env e=case exprNode e of
  Var (Global n _)->M.lookup n globals
  Var (Local uid)->M.lookup uid env
  ClosureValue label _->length . contractParameters <$> M.lookup label contracts
  Lambda ps _->Just (length ps)
  VectorBuild builder _->Just (builderArity builder)
  Note x->arity globals contracts env x
  Apply {}->let (head',args)=spine e [] in do
    n<-arity globals contracts env head'
    if n>length args then Just (n-length args) else Nothing
  _->Nothing
spine :: Expr -> [Expr] -> (Expr,[Expr])
spine e args=case exprNode e of
  Apply fn arg->spine fn (arg:args)
  Note x->spine x args
  _->(e,args)
-- Undeclared globals here are runtime primitives, not caller-owned templates.
-- Leave their established native lowering intact; do not invent an arity from
-- their logical type or obstruct layout-dependent vector fusion.
unregisteredGlobal :: M.Map String Int -> Expr -> Bool
unregisteredGlobal globals e=case exprNode e of
  Var (Global n _)->M.notMember n globals
  _->False
ready :: M.Map String Int -> Expr -> Bool
ready globals e=case exprNode e of
  Var (Local _)->True
  Var (Global n _)->maybe False (>0) (M.lookup n globals)
  ClosureValue _ []->True
  IntValue _->True
  StringValue _->True
  BoolValue _->True
  LayoutLiteral _->True
  Note x->ready globals x
  _->False
