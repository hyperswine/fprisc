-- Source declaration admission and diagnostics for explicit C exports.
-- The ordinary unit checker has already accepted these declarations. This
-- owner projects their boundary types once and produces checked adapter plans.
module Compiler.Native.Exports
  (PreparedExport, ExportError(..), prepareExports, prepareUniformExports, prepareUniformExportsWith, exportDescription, exportAdapter) where
import Frontend.Syntax (STop(..),Ty(..))
import Codegen.Export.Plan
import Representation.Types (CallSignature,Rep(..),signatureParts)
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
prepareExports=prepareWith planAdapter M.empty
prepareUniformExports :: FloatABI -> [(String,String)] -> [STop] -> M.Map String Int -> (String -> String) -> Either ExportError [PreparedExport]
prepareUniformExports=prepareUniformExportsWith M.empty
-- Checked aggregates and explicit uniform variables cross as owned tagged C
-- values. Hidden fields and open rows still need complete layout authority.
prepareUniformExportsWith :: M.Map String CallSignature -> FloatABI -> [(String,String)] -> [STop] -> M.Map String Int -> (String -> String) -> Either ExportError [PreparedExport]
prepareUniformExportsWith=prepareWith planUniformAdapter
prepareWith planner checked abi requests declarations arities target=traverse one requests
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
      let (params,resultRep)=maybe ([],Nothing) signatureParts (M.lookup q checked)
          kind ty known=case ckindOf ty of
            Right scalar->Right scalar
            Left why->case known of
              Just UniformRep->Right KValue
              Just TextRep->Right KValue
              Just LayoutRep {}->Right KValue
              _->Left why
      kinds<-admit (sequence (zipWith kind as (params++repeat Nothing)))
      result<-admit (kind r resultRep)
      checked<-admit (planner abi (CExportSymbol public) (FprEntrySymbol (target q)) (Signature kinds result))
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
