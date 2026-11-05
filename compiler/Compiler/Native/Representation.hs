-- Preserve checked interface and local aggregate evidence at ARC's erased
-- compatibility boundary. Open source slots retain their tagged fallback;
-- closed local instantiations do not depend on function specialization.
module Compiler.Native.Representation (signatures, signaturesFor, prepareFor) where
import qualified Compiler.Native.Core as Native
import qualified Core.Typed.Syntax as Core
import Core.Typed.Walk (mapChildrenM)
import Data.Functor.Const (Const(..))
import qualified Core.Syntax as Erased
import qualified Data.Set as S
import Control.Monad (unless)
import qualified Core.Calling as Calling
import qualified Core.Typed.Pipeline as Pipeline
import qualified Core.Typed.Program as Program
import qualified Compiler.Native.TypeLayout as Layout
import qualified Type.Substitution as Type
import Type.Syntax (Type(..))
import Representation.Types
import qualified Data.Map.Strict as M

signatures :: Native.NativeCore -> Either String (M.Map String CallSignature, LayoutTable)
signatures=signaturesFor True

-- Explicit raw units cannot allocate fallback boxes. Their open helper
-- variables retain the existing inferred raw ABI; exports remain concrete.
signaturesFor :: Bool -> Native.NativeCore -> Either String (M.Map String CallSignature, LayoutTable)
signaturesFor uniform native=do
  (signatures,layouts,_,_)<-prepareFor uniform native
  pure (signatures,layouts)

-- Markers are scoped to this exact checked projection and consumed by ARC.
-- They never become runtime calls or authority for compatibility definitions.
prepareFor :: Bool -> Native.NativeCore -> Either String (M.Map String CallSignature, LayoutTable, M.Map String Rep, Erased.Prog)
prepareFor uniform native=do
  let closed=Native.nativeClosed native
      types=Program.programTypes (Pipeline.closedInput closed)
      allTypes=concat [r:ps | (ps,r)<-M.elems interfaces]++
        concatMap (expressionTypes . Core.functionBody . Native.checkedFunction) (M.elems (Native.nativeDefinitions native))
  layouts<-(if uniform then Layout.layoutsFor else Layout.layoutsForRaw)
    (Pipeline.closedLayouts closed) types (if uniform then allTypes else filter closedType allTypes)
  let evidence=M.fromList ([("$representation.local."++show i,LayoutRep key) | (i,key)<-zip [0::Int ..] (M.keys layouts)]
        ++ [("$representation.open-row",UniformRep) | uniform,any Layout.openRecord allTypes]
        ++ [("$representation.bool",DataRep 1) | uniform,TC "Bool" `elem` allTypes])
      names=M.fromList [(rep,n) | (n,rep)<-M.toList evidence]
      -- A checked Bool use must validate a hidden tagged payload before an
      -- erased Boolean test. Ordinary pattern tag tests may instead fall
      -- through on a different nominal type.
      annotation e value=case (if Layout.openRecord (Core.exprType e)
                              then representation layouts (Core.exprType e)
                              else case representation layouts (Core.exprType e) of Just UniformRep->Nothing;r->r) >>= (`M.lookup` names) of
        Just name->Erased.CApp (Erased.CVar name) value
        Nothing->value
      source=Native.nativeProgram native
      reserved=M.keysSet source `S.union` S.fromList (concat [ps++Erased.freeVars body | (ps,body)<-M.elems source])
  unless (S.null (M.keysSet evidence `S.intersection` reserved)) (Left "local representation evidence: reserved marker collision")
  program<-Native.annotatedProgram annotation native
  pure (M.map (signature layouts) interfaces,layouts,evidence,program)
  where
    expressionTypes e=Core.exprType e:getConst (mapChildrenM (Const . expressionTypes) e)
    interfaces=M.mapWithKey checked (Native.nativeDefinitions native)
      `M.union` M.map declaration (Native.nativeDeclarations native)
    checked name definition=
      let fn=Native.checkedFunction definition
          ps=map Core.binderType (Core.functionParameters fn)
          r=Core.exprType (Core.functionBody fn)
      -- Runtime roots have no source caller. Their ABI supplies otherwise
      -- unconstrained slots, while concrete incompatible evidence must still
      -- reach the representation check and fail.
      in if name=="machineInterrupt"
         then (map (rootSlot (TC "Word")) ps,rootSlot (TC "Unit") r)
         else (ps,r)
    rootSlot expected (TV _)=expected
    rootSlot _ concrete=concrete
    declaration d=(Calling.callingArguments d,Calling.callingResult d)
    closedType t=Type.variables t==mempty
    representation layouts t | uniform || closedType t=Layout.representation layouts t
                             | otherwise=Nothing
    signature layouts (ps,r)=(if all ((==mempty) . Type.variables) (r:ps) then ClosedSignature else CallSignature)
      (map (representation layouts) ps) (representation layouts r)
