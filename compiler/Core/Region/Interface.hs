-- Owned region interfaces retain physical checked binders and result types.
-- Declaration-only compatibility evidence is distinct from a checked body.
module Core.Region.Interface
  (Interface,Provenance(..),closedInterfaces,declaredInterface,interfaceProvenance,
   interfaceParameters,interfaceArguments,interfaceResult,interfaceResultShape,interfaceArity,
   callableRegionEntry) where
import Core.Typed.Syntax
import Core.Typed.Pipeline
import Core.Typed.Close
import Core.Calling
import Type.Syntax
import Ownership.Shape (LShape)
import qualified Data.Map.Strict as M

data Provenance=SourceEntry String | PrivateEntry String CodeId CodeKind | SourceDeclaration String
  deriving (Eq,Show)
data Interface=Interface Provenance (Maybe [Binder]) Calling (Maybe LShape) deriving Show
interfaceProvenance :: Interface -> Provenance
interfaceProvenance (Interface origin _ _ _)=origin
interfaceParameters :: Interface -> Maybe [Binder]
interfaceParameters (Interface _ ps _ _)=ps
interfaceArguments :: Interface -> [Type]
interfaceArguments (Interface _ _ c _)=callingArguments c
interfaceResult :: Interface -> Type
interfaceResult (Interface _ _ c _)=callingResult c
interfaceResultShape :: Interface -> Maybe LShape
interfaceResultShape (Interface _ _ _ shape)=shape
interfaceArity :: Interface -> Int
interfaceArity=length . interfaceArguments

closedInterfaces :: ClosedProgram -> M.Map String Interface
closedInterfaces closed=M.fromList (concatMap one (M.toList (closedDefinitions closed)))
  where
    make role fn=case calling (length (functionParameters fn)) (functionType fn) of
      Just c->Interface role (Just (functionParameters fn)) c (Just (exprShape (functionBody fn)))
      Nothing->error "region interfaces: verified physical function lost its arrows"
    one (name,f)=(name,make (SourceEntry name) (closedRoot f)):
      [(n,make (PrivateEntry name key (codeKind code)) (codeAsFunction code))
        | (key@(CodeId n),code)<-M.toList (closedCode f)]
declaredInterface :: String -> Calling -> Interface
declaredInterface name c=Interface (SourceDeclaration name) Nothing c Nothing

callableRegionEntry :: Interface -> Bool
callableRegionEntry f=case interfaceProvenance f of PrivateEntry _ _ JoinCode->False;_->True
