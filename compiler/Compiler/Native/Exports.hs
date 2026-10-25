-- Source declaration admission and diagnostics for explicit C exports.
-- The ordinary unit checker has already accepted these declarations. This
-- owner projects their boundary types once and produces checked adapter plans.
module Compiler.Native.Exports
  (PreparedExport, ExportError(..), prepareExports, exportDescription, exportAdapter) where
import Frontend.Syntax (STop(..),Ty(..))
import Codegen.Export.Plan
import qualified Data.Map.Strict as M

data ExportError = ExportError {exportSource :: String, exportMessage :: String} deriving (Eq,Show)
data PreparedExport = PreparedExport String CheckedAdapter deriving (Eq,Show)
exportAdapter :: PreparedExport -> CheckedAdapter
exportAdapter (PreparedExport _ adapter)=adapter
exportDescription :: PreparedExport -> String
exportDescription (PreparedExport name checked)=
  let plan=adapterPlan checked;CExportSymbol public=adapterPublic plan;sig=adapterSignature plan
  in "export "++public++" : "++unwords (map show (signatureParams sig))++" -> "++show (signatureResult sig)++"  ("++name++")"

prepareExports :: FloatABI -> [(String,String)] -> [STop] -> M.Map String Int -> (String -> String) -> Either ExportError [PreparedExport]
prepareExports abi requests declarations arities target=traverse one requests
  where
    baseName=takeWhile (/='@')
    signatures=M.fromListWith (++) [(baseName q,[(q,as,r)]) | TSig q (as,r) _<-declarations]
    one (name,public)=do
      let bad=Left . ExportError name
          admit=either bad Right
      (q,as,r)<-case M.lookup name signatures of
        Just [entry]->Right entry
        Just _->bad "ambiguous: more than one signature by that name"
        Nothing->bad "no declared signature (an export is a contract: write `name : A -> B .`)"
      actual<-maybe (bad "no such function in this unit") Right (M.lookup q arities)
      admit (checkExportArity abi (length as) actual)
      kinds<-admit (traverse ckindOf as)
      result<-admit (ckindOf r)
      checked<-admit (planAdapter abi (CExportSymbol public) (FprEntrySymbol (target q)) (Signature kinds result))
      pure (PreparedExport q checked)

ckindOf :: Ty -> Either String CKind
ckindOf ty=case ty of
  TCon "Int" []->Right KInt
  TCon "Word" []->Right KWord
  TCon "Addr" []->Right KAddr
  TCon "Bool" []->Right KBool
  TCon "Unit" []->Right KUnit
  TCon "F64" []->Right KF64
  TCon "F32" []->Right KF32
  _->Left ("not a C-representable type: "++show ty++" (Int, Word, Addr, Bool, Unit, F64, F32 cross the boundary)")
