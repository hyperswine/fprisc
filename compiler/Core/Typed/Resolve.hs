-- Resolve known, saturated lexical closure calls while types and code IDs
-- still exist. This does not copy a lambda or specialize its code by use type.
module Core.Typed.Resolve (resolveCalls) where
import Core.Typed.Syntax
import Core.Typed.Close
import Core.Typed.Walk (mapChildrenM)
import Type.Syntax (Type(..),Row(..),Scheme(..))
import Ownership.Shape (isLin)
import qualified Data.Map.Strict as M
import Control.Monad.Identity

resolveCalls :: TypeContext -> ClosedFunction -> Either String ClosedFunction
resolveCalls types input=do
  verifyClosed types input
  mapClosed types root code input
  where
    contracts=closedContracts input
    root f=Right f {functionBody=go M.empty (functionBody f)}
    code f=Right f {codeBody=go M.empty (codeBody f)}
    known env e=case exprNode e of
      ClosureValue label captures->Just (label,captures)
      Var (Local uid)->M.lookup uid env
      Note x->known env x
      _->Nothing
    -- Only value aliases enter the environment. A stored partial application
    -- may already have evaluated effects and generalized argument types; it
    -- requires a separate checked staging transformation, never substitution.
    go env e=case exprNode e of
      Let b rhs body->
        let rhs'=go env rhs
            scope=case known env rhs' of
              Just value->M.insert (binderId b) value env
              Nothing->env
        in e {exprNode=Let b rhs' (go scope body)}
      Apply {}->
        let (head',args)=spine e []
            fn=go env head'
            xs=map (go env) args
        in case known env fn of
                  Just (label,captures)
                    | Just contract<-M.lookup label contracts,
                      all safeCapture (contractCaptures contract),
                      length xs==length (contractParameters contract)->e {exprNode=CodeCall label captures xs}
                  _->runIdentity (mapChildrenM (pure . go env) e)
      _->runIdentity (mapChildrenM (pure . go env) e)
    spine e args=case exprNode e of
      Apply fn arg->spine fn (arg:args)
      Note fn->spine fn args
      _->(e,args)
    -- Keeping an escaping closure binding while calling its captures directly
    -- introduces another lexical use of those captures. Until callable-owner
    -- evidence is preserved, permit only manifest immutable data; a function's
    -- arrow type alone does not prove its captured environment unrestricted.
    schemeType (Forall _ _ ty)=ty
    safeCapture (scheme,shape)=not (isLin shape) && plain (schemeType scheme)
    plain ty=case ty of
      TC n->n `elem` ["Int","Bool","Atom","F32","F64","String","Unit"]
      TLayout _->True
      TTupT xs->all plain xs
      TRec row->fields row
      _->False
    fields RNil=True
    fields (RExt _ ty rest)=plain ty && fields rest
    fields (RV _)=False
