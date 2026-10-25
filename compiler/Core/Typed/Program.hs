-- Checked source functions and their physical calling authority travel as one
-- product. This is still semantic Core: layout and closing belong downstream.
module Core.Typed.Program
  (Program,program,programWithAssumptions,programNamespace,programTypes,programSchemas,programArities,
   programFunctions,programAssumptions,RecursiveAssumption(..),verifyProgram,verifyProgramCalls) where
import Core.Typed.Syntax
import Core.Typed.Walk (allBinders,mapChildrenM)
import Core.Typed.Verify (verifyFunction,instanceOf)
import Core.Identity
import Type.Syntax
import qualified Type.Substitution as U
import Control.Monad (unless)
import Data.Functor.Const (Const(..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S

-- These are source-checking assumptions, not proofs of a published ABI type.
-- Keeping their source identity and scope explicit prevents arbitrary stale
-- global annotations from acquiring the same permission.
data RecursiveAssumption=RecursiveAssumption
  { assumptionExpression :: ExprId, assumptionOwner :: String, assumptionTarget :: String,
    assumptionScoped :: Scheme, assumptionPublished :: Scheme } deriving Show
data Program=Program Namespace TypeContext (M.Map String Scheme) (M.Map String Int) (M.Map String Function) (M.Map ExprId RecursiveAssumption)
programNamespace (Program ns _ _ _ _ _)=ns
programTypes (Program _ ts _ _ _ _)=ts
programSchemas (Program _ _ ss _ _ _)=ss
programArities (Program _ _ _ as _ _)=as
programFunctions (Program _ _ _ _ fs _)=fs
programAssumptions (Program _ _ _ _ _ cs)=cs

program :: Namespace -> TypeContext -> M.Map String Scheme -> M.Map String Int -> M.Map String Function -> Either String Program
program ns types schemas arities functions=programWithAssumptions ns types schemas arities functions M.empty
programWithAssumptions :: Namespace -> TypeContext -> M.Map String Scheme -> M.Map String Int -> M.Map String Function -> M.Map ExprId RecursiveAssumption -> Either String Program
programWithAssumptions ns types schemas arities functions assumptions=do
  let result=Program ns types schemas arities functions assumptions
  verifyProgram result
  pure result

verifyProgram :: Program -> Either String ()
verifyProgram p=do
  unless (all (>=0) arities) (Left "typed program: negative physical arity")
  unless (length ids==S.size (S.fromList ids)) (Left "typed program: binder identity shared by definitions")
  mapM_ (\(uid,entry)->unless (uid==assumptionExpression entry
    && assumptionOwner entry `M.member` schemas && assumptionTarget entry `M.member` schemas)
      (Left "typed program: malformed recursive assumption owner/identity")) (M.toList (programAssumptions p))
  mapM_ definition (M.toList functions)
  where
    types=programTypes p;schemas=programSchemas p;arities=programArities p
    functions=programFunctions p
    ids=[binderId b | fn<-M.elems functions,b<-functionParameters fn++allBinders (functionBody fn)]
    definition (name,fn)=do
      let bad why=Left ("typed program "++name++": "++why)
      unless (name==functionName fn) (bad "definition key/name mismatch")
      unless (M.lookup name arities==Just (length (functionParameters fn))) (bad "owned physical arity mismatch")
      case M.lookup name schemas of
        Nothing->bad "owned function lacks a checked calling scheme"
        Just sc->unless (instanceOf sc (functionType fn)) (bad "owned function/calling scheme mismatch")
      unless (all (\b->case binderScheme b of Forall [] [] _->True;_->False) (functionParameters fn))
        (bad "ordinary parameter requires a monomorphic scheme")
      verifyFunction types fn
      verifyProgramCalls p name (functionBody fn)

verifyProgramCalls :: Program -> String -> Expr -> Either String ()
verifyProgramCalls p owner=references
  where
    schemas=programSchemas p
    references e=do
      case exprNode e of
        Var (Global name _) | Just sc<-M.lookup name schemas->
          unless (instanceOf sc (exprType e) || scoped name sc e)
            (Left ("typed program "++owner++": calling scheme disagrees at "++name
              ++"; declared "++show sc++"; occurrence "++show (exprType e)))
        _->pure ()
      sequence_ (getConst (mapChildrenM (Const . (:[]) . references) e))
    scoped name published e=case exprOrigin e of
      Checked uid->permit False uid
      Reinstantiated uid->permit True uid
      _->False
      where
        permit cloned uid=case M.lookup uid (programAssumptions p) of
          Just entry | assumptionTarget entry==name,
            cloned || assumptionOwner entry==owner,
            equivalent (assumptionPublished entry) (semantic published)->
              instanceOf (if cloned then generic entry else assumptionScoped entry) (exprType e)
          _->False
    semantic (Forall ts rs ty)=Forall ts rs (strip ty)
      where strip (TFn (TLayout _) rest)=strip rest;strip t=t
    equivalent a@(Forall _ _ at) b@(Forall _ _ bt)=instanceOf a bt && instanceOf b at
    generic entry=
      let sc@(Forall ts rs ty)=assumptionScoped entry
          (vs,rows)=U.schemeVariables sc
          (rigidT,rigidR)=U.schemeVariables (assumptionPublished entry)
            <>maybe mempty U.schemeVariables (M.lookup (assumptionOwner entry) schemas)
      in Forall (ts++S.toList (vs S.\\ rigidT)) (rs++S.toList (rows S.\\ rigidR)) ty
