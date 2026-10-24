import Infer
import qualified Infer.Evidence as E
import Core.Identity
import Frontend.Parser (program)
import Frontend.Syntax
import Struct (sigTable, structTable)
import Ownership.Shape
import Text.Megaparsec (parse,errorBundlePretty)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Monad (unless)

check label ok = unless ok (error label)
proof r = either error (maybe (error "missing evidence") id) (inferenceEvidence r)
source = unlines
  [ "identity x = x."
  , "shadow x = (fn x -> x + 1) x."
  , "local n = ident x = x; (ident n, ident True)."
  , "pat p = case p of (a,b) -> a + b."
  , "guarded p | (a,b) <- p = a + b."
  , "guarded _ = 0."
  , "floaty x = x + 1.25."
  , "capture x = fn y -> x + y."
  , "recur n = loop k = if k == 0 then n else loop (k - 1); loop 2."
  , "field record = record.value."
  , "showPoly value = print value."
  , "Token 1 = Type Int."
  , "take : Token -> Token."
  , "take token = token."
  ]
main = do
  let tops = either (error.errorBundlePretty) id (parse program "evidence.fpr" source)
      sigs = sigTable tops; structs = structTable tops
      legacy = inferTopsInterfaces aotProf sigs structs tops
      r = inferTopsChecked (Namespace "unit-A") aotProf sigs structs tops
      projected = (inferenceErrors r,inferenceNotes r,inferenceHoles r,
                   inferenceLinearity r,inferenceTops r,inferenceInterfaces r)
  check ("valid fixture: " ++ show (inferenceErrors r)) (null (inferenceErrors r))
  check "evidence does not perturb schemes, diagnostics, holes, layouts or type IDs" (show legacy==show projected)
  let e=proof r; bs=E.evidenceBinders e; es=E.evidenceExpressions e
  check "checked declaration schemes are retained"
    (case M.lookup "identity" (inferenceSchemes r) of
       Just (Forall qs _ (TFn (TV a) (TV b))) -> a==b && a `elem` qs
       _ -> False)
  check "facts are retained" (not (null bs) && not (null es) && not (null (E.evidenceRoots e)))
  let xs=[b | b<-bs,E.binderOwner b==Just "shadow",E.binderSpelling b=="x"]
  check "shadowed spellings have distinct identities" (length xs==2 && S.size (S.fromList (map E.binderIdentity xs))==2)
  let uses=[uid | n<-es,E.expressionOwner n==Just "shadow",Just (E.LocalReference "x" uid)<-[E.expressionReference n]]
  check "both lexical bindings are referenced" (S.fromList uses==S.fromList (map E.binderIdentity xs))
  let localUses owner name = [uid | n<-es,E.expressionOwner n==Just owner,
                                   Just (E.LocalReference spelling uid)<-[E.expressionReference n],spelling==name]
      localIds owner name = [E.binderIdentity b | b<-bs,E.binderOwner b==Just owner,E.binderSpelling b==name]
  check "lambda capture retains its enclosing identity"
    (localUses "capture" "x"==localIds "capture" "x")
  check "recursive local is refined without allocating a second identity"
    (case localIds "recur" "loop" of [uid]->localUses "recur" "loop"==[uid,uid]; _->False)
  check "recorded expression types are zonked" (any ((==TC "F64").E.expressionType) es)
  check "owned parameter shape retained" (any (\b->E.binderOwner b==Just "take" && E.binderSpelling b=="token" && E.binderTypeShape b==LL) bs)
  let prints=[sc | n<-es,Just (E.GlobalReference "print" sc)<-[E.expressionReference n]]
  check "quantified schemes stay polymorphic under the final substitution"
    (not (null prints) && all (\sc -> case sc of
      Forall qs _ (TFn (TV v) (TC "Unit")) -> v `elem` qs
      _ -> False) prints)
  check "row quantifiers survive the final substitution"
    (case M.lookup "field" (inferenceSchemes r) of
      Just (Forall tvs rvs (TFn (TRec (RExt "value" (TV a) (RV row))) (TV b))) ->
        a==b && a `elem` tvs && row `elem` rvs
      _ -> False)
  let sites = inferenceElaborations r
      exprIds = S.fromList (map E.expressionIdentity es)
  check "operator choices and their checked types are retained"
    (any (\site -> case elaborationTarget site of
      OpPrim "F64.+" -> elaborationType site == TC "F64"
      _ -> False) sites)
  check "elaborations identify their source checking occurrences"
    (not (null sites) && all (\site -> maybe True (`S.member` exprIds) (elaborationExpression site)) sites)
  check "source offsets retained" (any ((/=Nothing).E.expressionOffset) es)
  let other=proof (inferTopsChecked (Namespace "unit-B") aotProf sigs structs tops)
  check "identities cannot collide between units" (S.null (S.intersection (S.fromList (map E.binderIdentity bs)) (S.fromList (map E.binderIdentity (E.evidenceBinders other)))))
  let badTops=[TBind "bad" [] [] (SBin "+" (SInt 1) (SVar "True"))]
      bad=inferTopsChecked (Namespace "bad") aotProf M.empty M.empty badTops
  check "failed checking does not seal evidence" (not (null (inferenceErrors bad)) && case inferenceEvidence bad of Left _->True; _->False)
  let holed=inferTopsChecked (Namespace "hole") aotProf M.empty M.empty
        [TBind "holed" [] [] (SApp (SVar "?hole") (SStrI [SegStr "todo"]))]
  check "unresolved named holes do not seal evidence"
    (not (null (inferenceHoles holed)) && case inferenceEvidence holed of Left _->True; _->False)
  -- The builder is deliberately exposed for the producer. Its result is
  -- sealed only after scope/identity/closure checks, including malformed inputs.
  let ns=Namespace "lint";sc=Forall [] [] (TC "Int")
      (ids,b0)=E.bindNames E.ClauseParameter (Just "f") (M.singleton "x" sc) (E.emptyBuilder ns)
      uid=ids M.! "x"
      (eid,b1)=E.beginExpr (Just "f") Nothing (SVar "x") ids (Just (E.LocalReference "x" uid)) b0
      b2=E.endExpr eid (TC "Int") b1
      accepted b=case E.sealEvidence (const LU) b of Right _->True; _->False
  check "well-scoped facts accepted" (accepted b2)
  check "unfinished facts refused" (not (accepted b1))
  let (out,b3)=E.beginExpr (Just "f") Nothing (SVar "x") M.empty (Just (E.LocalReference "x" uid)) b0
  check "out-of-scope reference refused" (not (accepted (E.endExpr out (TC "Int") b3)))
  let (cross,b4)=E.beginExpr (Just "other") Nothing (SVar "x") ids (Just (E.LocalReference "x" uid)) b0
  check "cross-owner reference refused" (not (accepted (E.endExpr cross (TC "Int") b4)))
  let foreignId=BinderId (Namespace "different") 0
      (wrong,b5)=E.beginExpr (Just "f") Nothing (SVar "x") (M.singleton "x" foreignId) (Just (E.LocalReference "x" foreignId)) b0
  check "cross-unit reference refused" (not (accepted (E.endExpr wrong (TC "Int") b5)))
  putStrLn "Inference evidence: zonked types, lexical identities, source/type shapes, compatibility projection and malformed-scope refusals passed"
