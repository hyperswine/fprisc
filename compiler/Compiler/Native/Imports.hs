-- The explicit bridge from linked checked code interfaces to native emission.
-- Legacy transformations may still change erased bodies; they cannot copy a
-- checked private definition into a different artifact or invent its arity.
module Compiler.Native.Imports
  (CodeDeclarations,codeDeclarations,CodeDeclaration,declarationHome,declarationSource,
   declarationCode,declarationContract,declarationArity,preservedCode,
   ReadyProgram,prepareEmission,prepareEmissionWithImports,readyProgram,readySymbols,readyImports,readyTemplates,importArities) where
import Compiler.Native.Linked
import Core.Typed.Syntax (CodeId(..),CodeContract(..))
import Core.Syntax
import Codegen.Target.Common (SymbolPolicy,symbolPolicy)
import Control.Monad (unless,forM_)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data CodeDeclaration=CodeDeclaration ArtifactId String CodeId CodeContract
  deriving Show
declarationHome :: CodeDeclaration -> ArtifactId
declarationHome (CodeDeclaration home _ _ _)=home
declarationSource :: CodeDeclaration -> String
declarationSource (CodeDeclaration _ source _ _)=source
declarationCode :: CodeDeclaration -> CodeId
declarationCode (CodeDeclaration _ _ code _)=code
declarationContract :: CodeDeclaration -> CodeContract
declarationContract (CodeDeclaration _ _ _ contract)=contract
declarationArity :: CodeDeclaration -> Int
declarationArity entry=let c=declarationContract entry
                      in length (contractCaptures c)+length (contractParameters c)

data CodeDeclarations=CodeDeclarations (S.Set ArtifactId) (M.Map Name CodeDeclaration)
codeDeclarations :: LinkedProgram -> Either String CodeDeclarations
codeDeclarations linked=do
  let entries=[(name,CodeDeclaration home source code contract)
        | (_,SymbolOwner home (PrivateDefinition source code@(CodeId name) contract))<-M.toList (linkedSymbols linked)]
      catalog=M.fromList entries
  unless (length entries==M.size catalog) (Left "native declarations: ambiguous private code identity")
  pure (CodeDeclarations (M.keysSet (linkedArtifacts linked)) catalog)

-- These canonical labels must not be renamed into an importing caller. Only
-- compatibility helpers without checked code ownership still need that path.
preservedCode :: CodeDeclarations -> ArtifactId -> S.Set Name
preservedCode (CodeDeclarations _ catalog) home=M.keysSet (M.filter ((==home) . declarationHome) catalog)

data ReadyProgram=ReadyProgram Prog SymbolPolicy (M.Map Name CodeDeclaration) Prog
readyProgram :: ReadyProgram -> Prog
readyProgram (ReadyProgram p _ _ _)=p
readySymbols :: ReadyProgram -> SymbolPolicy
readySymbols (ReadyProgram _ symbols _ _)=symbols
readyImports :: ReadyProgram -> M.Map Name CodeDeclaration
readyImports (ReadyProgram _ _ imports _)=imports
readyTemplates :: ReadyProgram -> Prog
readyTemplates (ReadyProgram _ _ _ templates)=templates
importArities :: ReadyProgram -> M.Map Name Int
importArities=M.map declarationArity . readyImports

prepareEmission :: CodeDeclarations -> ArtifactId -> S.Set Name -> Prog -> Either String ReadyProgram
prepareEmission=prepareEmissionWithImports M.empty

-- Templates belong to the remaining erased transformations. Check their
-- calling/ownership boundary, without claiming to recover typed bodies from
-- that projection. Only reachable templates enter the backend's lookup context.
prepareEmissionWithImports :: Prog -> CodeDeclarations -> ArtifactId -> S.Set Name -> Prog -> Either String ReadyProgram
prepareEmissionWithImports templates declarations@(CodeDeclarations artifacts catalog) here public input=do
  unless (here `S.member` artifacts) (bad "unknown emitting artifact")
  unless (public `S.isSubsetOf` M.keysSet input) (bad "export is absent after transformation")
  let own=preservedCode declarations here
  unless (own `S.isSubsetOf` M.keysSet input) (bad "home private definition is absent after transformation")
  forM_ (M.toList (M.intersection catalog input)) $ \(name,entry)->do
    unless (declarationHome entry==here) (bad ("private definition copied away from its home: "++name))
    unless (length (fst (input M.! name))==declarationArity entry)
      (bad ("private physical arity changed: "++name))
  forM_ (M.toList templates) $ \(name,(ps,_))->case M.lookup name catalog of
    Just entry | declarationHome entry/=here,length ps==declarationArity entry->pure ()
    _->bad ("template lacks an imported calling contract: "++name)
  let refs p=S.unions [references (S.fromList ps) body | (ps,body)<-M.elems p] S.\\ M.keysSet input
      reach seen pending
        | S.null pending=seen
        | otherwise=let wanted=pending `S.intersection` M.keysSet catalog
                        more=refs (M.restrictKeys templates wanted)
                    in reach (seen<>wanted) (more S.\\ (seen<>pending))
      imports=M.restrictKeys catalog (reach S.empty (refs input))
  unless (all ((/=here) . declarationHome) imports) (bad "unresolved home private reference")
  symbols<-symbolPolicy public (own S.\\ public)
  pure (ReadyProgram input symbols imports (M.restrictKeys templates (M.keysSet imports)))
  where
    bad why=Left ("native imports "++show here++": "++why)
    -- Scope-aware and linear in the erased tree, rather than constructing
    -- free-variable lists repeatedly along a deeply nested let spine.
    references bound body=go bound body S.empty
    go bound e found=case e of
      CVar n | n `S.notMember` bound->S.insert n found
      CApp a b->go bound a (go bound b found)
      CLam ps b->go (bound<>S.fromList ps) b found
      CLet n a b->go bound a (go (S.insert n bound) b found)
      CIf a b c->go bound a (go bound b (go bound c found))
      CMk _ _ xs->foldr (go bound) found xs
      CTagEq _ _ x->go bound x found
      CProj _ x->go bound x found
      _->found
