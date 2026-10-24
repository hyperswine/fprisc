{-# LANGUAGE LambdaCase, TupleSections #-}
-- First consumer of inference evidence in surface-to-Core lowering. Covered
-- functions construct and verify typed Core, then erase at the explicit seam
-- before the not-yet-migrated closure/optimization passes. Unsupported source
-- forms remain recorded as migration work, not as typed success.
module Frontend.Desugar.Checked
  ( CheckedPlans, prepareChecked, checkedNames, checkedDeclines,
    Desugared, desugaredCore, desugaredTyped, desugaredTypeContext, compileTopChecked, lowerToLegacy ) where
import Core.Identity
import qualified Core.Typed.Syntax as T
import Core.Typed.Erase (eraseFunction)
import Core.Syntax (Core, Prog)
import Type.Syntax (Type(..),Scheme(..))
import Ownership.Shape (LShape(..))
import Frontend.Syntax
import Frontend.Desugar (D, DEnv(..), fresh, constructorStubs, groupClauses, compileGroup)
import Infer.Result
import qualified Infer.Evidence as E
import Infer.Elaboration
import Precond (checkedName)
import Control.Monad (forM, unless)
import Control.Monad.State.Strict (get)
import Data.Binary (encode)
import qualified Data.Map.Strict as M
import qualified Data.IntMap.Strict as IM
import qualified Data.Set as S

data CheckedPlans = Plans T.TypeContext (M.Map String Plan) [(String,String)]
data Plan = Plan Namespace [T.Binder] EPlan [([SPat],[SGuard],SExpr)]
data EPlan = EP E.ExprFact PNode
data PNode = PVarRef T.Reference | PIntValue Integer | PStringValue String
  | PApply EPlan EPlan | PLambda [T.Binder] EPlan | PLet T.Binder EPlan EPlan
  | PInfix String EPlan EPlan | PBoolCase EPlan Bool EPlan EPlan | PNote EPlan

checkedNames :: CheckedPlans -> S.Set String
checkedNames (Plans _ ps _) = M.keysSet ps
checkedDeclines :: CheckedPlans -> [(String,String)]
checkedDeclines (Plans _ _ ds) = ds

prepareChecked :: InferenceResult -> Either String CheckedPlans
prepareChecked result = do
  evidence <- case inferenceEvidence result of
    Right (Just e) -> Right e
    Left reason -> Left reason
    _ -> Left "typed Core requires a checked inference result"
  let expressions=M.fromList [(E.expressionIdentity e,e) | e<-E.evidenceExpressions evidence]
      binders=M.fromList [(E.binderIdentity b,b) | b<-E.evidenceBinders evidence]
      globals=S.fromList ([n | TBind n _ _ _<-inferenceTops result] ++ [n | TSig n _ _<-inferenceTops result])
      targets=IM.fromList [(elaborationSite e,elaborationTarget e) | e<-inferenceElaborations result]
      at=M.fromListWith (++) [(uid,[e]) | e<-inferenceElaborations result,Just uid<-[elaborationExpression e]]
      roots=M.fromListWith (flip (++)) [(owner,[e]) | uid<-E.evidenceRoots evidence,Just e<-[M.lookup uid expressions],Just owner<-[E.expressionOwner e]]
      groups=M.fromListWith (flip (++)) [(n,[(ps,gs,b)]) | TBind n ps gs b<-inferenceTops result]
      binder uid = case M.lookup uid binders of
        Nothing -> Left "missing checked binder"
        Just b -> Right (T.Binder uid (E.binderSpelling b) (E.binderScheme b) (E.binderTypeShape b))
      scoped e name = maybe (Left "parameter/layout not yet represented in checked scope") binder (M.lookup name (E.expressionScope e))
      child uid = maybe (Left "missing checked expression") plan (M.lookup uid expressions)
      children e = mapM child (E.expressionChildren e)
      -- Leaves have bounded raw rewrites (including constructor-hole wrappers
      -- and reference dictionaries). Never traverse every nested expression's
      -- rewritten subtree: that would make this handoff quadratic.
      rewrittenLeaf e = applySites globals targets (E.expressionRewritten e)
      changedSite e = any nonidentity (M.findWithDefault [] (E.expressionIdentity e) at)
      nonidentity site = case elaborationTarget site of
        OpPrim "" -> False
        OpDictionary [] -> False
        _ -> True
      operator e original = case [elaborationTarget x | x<-M.findWithDefault [] (E.expressionIdentity e) at,elaborationOperation x==original] of
        [OpPrim n] -> Right n
        [OpGlobal n] -> Right (let checked=checkedName n 0 in if S.member checked globals then checked else n)
        [] | original `elem` ["|>",">>"] -> Right original
        _ -> Left "operator/projection elaboration not yet migrated"
      plan e = do
        let make n=Right (EP e n)
        case E.expressionSource e of
          SVar _ -> case (E.expressionReference e,rewrittenLeaf e) of
            (Just (E.LocalReference _ uid),SVar n) -> do
              b<-binder uid
              if n==T.binderName b then make (PVarRef (T.Local uid)) else Left "local layout alias not yet migrated"
            (Just (E.GlobalReference _ sc),SVar n) -> make (PVarRef (T.Global n sc))
            _ -> Left "generated reference wrapper not yet migrated"
          SInt n -> make (PIntValue n)
          SStrI [SegStr s] -> make (PStringValue s)
          SStrI [] -> make (PStringValue "")
          SMark _ _ -> children e >>= \case
            [a] -> make (PNote a)
            _ -> Left "source mark derivation"
          SApp _ _ | not (changedSite e) -> children e >>= \case
            [a,b] -> make (PApply a b)
            _ -> Left "synthesized application not yet migrated"
          SLam names _ -> children e >>= \case
            [body@(EP fact _)] -> do
              ps<-mapM (scoped fact) names
              make (PLambda ps body)
            _ -> Left "lambda derivation"
          SBlock ss _ -> do
            case E.expressionRewritten e of
              SBlock raw _ -> unless (bindingNames ss==bindingNames raw)
                (Left "local layout aliases not yet migrated")
              _ -> Left "block elaboration not yet migrated"
            cs<-children e
            let block [] [last'] = Right last'
                block (SBind n [] _:rest) (rhs:more@(EP next _: _)) = do
                  b<-scoped next n
                  -- Ordinary Core let is nonrecursive. Inference's recursive
                  -- placeholder must not make a self-use look nonrecursive.
                  unless (not (uses (T.binderId b) rhs)) (Left "recursive let not yet migrated")
                  body<-block rest more
                  pure (EP e (PLet b rhs body))
                block _ _ = Left "pattern/function local binding not yet migrated"
            block ss cs
          SBin op _ _ -> do
            name<-operator e op
            children e >>= \case
              [a,b] -> make (PInfix name a b)
              _ -> Left "operator derivation not yet migrated"
          SCase _ [(PCon a [],_),(PCon b [],_)]
            | [a,b]==["True","False"] || [a,b]==["False","True"] -> children e >>= \case
                [scrut,yes,no] -> make (PBoolCase scrut (a=="True") yes no)
                _ -> Left "Bool case derivation"
          _ -> Left "source form not yet migrated"
      bindingNames = map (\case SBind n _ _ -> Just n; _ -> Nothing)
      entry n clauses = case (clauses,M.findWithDefault [] n roots) of
        ([(ps,[],_)],[root]) | all plain ps -> do
          params<-mapM (scoped root) [v | Frontend.Syntax.PVar v<-ps]
          body<-plan root
          pure (Plan (E.evidenceNamespace evidence) params body clauses)
        _ -> Left "pattern/guard/multiple-clause entry not yet migrated"
      plain (Frontend.Syntax.PVar _) = True
      plain _ = False
      answers=[(n,entry n clauses) | (n,clauses)<-M.toList groups]
  pure (Plans (T.TypeContext [n | TType n True _ _<-inferenceTops result]) (M.fromList [(n,p) | (n,Right p)<-answers]) [(n,reason) | (n,Left reason)<-answers])
  where
    uses uid (EP _ node) = case node of
      PVarRef (T.Local x) -> x==uid
      _ -> any (uses uid) (kids node)
    kids node = case node of
      PApply a b -> [a,b]; PLambda _ b -> [b]; PLet _ a b -> [a,b]
      PInfix _ a b -> [a,b]; PBoolCase a _ b c -> [a,b,c]; PNote b -> [b]
      _ -> []

-- Typed evidence is attached to this stage's bodies only. The explicit
-- lowerToLegacy seam does not claim that later lifting preserved it.
data Desugared = Desugared T.TypeContext Prog (M.Map String T.Function)
desugaredCore :: Desugared -> Prog
desugaredCore (Desugared _ p _) = p
desugaredTyped :: Desugared -> M.Map String T.Function
desugaredTyped (Desugared _ _ p) = p

desugaredTypeContext :: Desugared -> T.TypeContext
desugaredTypeContext (Desugared types _ _) = types

compileTopChecked :: CheckedPlans -> [STop] -> D Desugared
compileTopChecked plans@(Plans types _ _) tops = do
  stubs<-constructorStubs
  groups<-mapM (lowerCheckedGroup plans) (groupClauses tops)
  pure (Desugared types (M.union (M.fromList (map fst groups)) stubs)
       (M.fromList [(T.functionName f,f) | (_,Just f)<-groups]))

lowerToLegacy :: CheckedPlans -> [STop] -> D Prog
lowerToLegacy plans tops = desugaredCore <$> compileTopChecked plans tops

lowerCheckedGroup :: CheckedPlans -> (String,[([SPat],[SGuard],SExpr)])
                  -> D ((String,([String],Core)),Maybe T.Function)
lowerCheckedGroup (Plans types plans _) group@(name,clauses) = case M.lookup name plans of
  -- A later specialization or per-unit resolution may change the surface
  -- input. It has not preserved typed evidence yet, so it must use that
  -- stage's old lowerer. Do not attach stale types to the transformed body.
  Just (Plan ns ps body expected) | encode clauses==encode expected -> do
    args<-forM (zip [1::Int ..] ps) $ \(i,p) -> generatedBinder ns ("a"++show i) (T.binderType p) (T.binderShape p)
    b<-lower ns body
    let withAliases=foldr (\(p,a) rest -> generated (T.exprType rest) (T.exprShape rest)
                         (T.Let p (generated (T.binderType a) (T.binderShape a) (T.Var (T.Local (T.binderId a)))) rest)) b (zip ps args)
        fn=T.Function name args withAliases
    case eraseFunction types fn of
      Left reason -> error reason -- a supported handoff failed its contract
      Right result -> pure ((name,result),Just fn)
  _ -> (,Nothing) <$> compileGroup group
  where
    generated ty shape node = T.Expr ty shape T.Generated Nothing node
    generatedBinder (Namespace ns) prefix ty shape = do
      st<-get
      n<-fresh prefix
      pure (T.Binder (BinderId (Namespace (ns++"/core/"++name)) (dFresh st)) n (Forall [] [] ty) shape)
    lower ns (EP fact node) = do
      n<-case node of
        PVarRef ref -> pure (T.Var ref)
        PIntValue i -> pure (T.IntValue i)
        PStringValue s -> pure (T.StringValue s)
        PApply a b -> T.Apply <$> lower ns a <*> lower ns b
        PLambda ps b -> T.Lambda ps <$> lower ns b
        PLet p a b -> T.Let p <$> lower ns a <*> lower ns b
        PNote b -> T.Note <$> lower ns b
        PInfix "|>" a b -> T.Apply <$> lower ns b <*> lower ns a
        PInfix ">>" a b -> do
          x<-lower ns a
          y<-lower ns b
          p<-generatedBinder ns "seq" (T.exprType x) (T.exprShape x)
          pure (T.Let p x y)
        PInfix op a b -> do
          x<-lower ns a; y<-lower ns b
          let result=E.expressionType fact
              inner=TFn (T.exprType y) result
              ft=TFn (T.exprType x) inner
              f=generated ft LU (T.Var (T.Global op (Forall [] [] ft)))
          pure (T.Apply (generated inner LU (T.Apply f x)) y)
        PBoolCase a first yes no -> do
          p<-generatedBinder ns "scrut" (TC "Bool") LU
          x<-lower ns a
          -- Existing pattern lowering builds the fallthrough arm first.
          n<-lower ns no; y<-lower ns yes
          let v=generated (TC "Bool") LU (T.Var (T.Local (T.binderId p)))
              test=generated (TC "Bool") LU (T.BoolTest first v)
              branch=generated (E.expressionType fact) (E.expressionTypeShape fact) (T.If test y n)
          pure (T.Let p x branch)
      pure (T.Expr (E.expressionType fact) (E.expressionTypeShape fact)
            (T.Checked (E.expressionIdentity fact)) (E.expressionOffset fact) n)
