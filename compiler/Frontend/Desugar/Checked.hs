-- Compatibility facade for callers of the staged migration API. Semantic
-- source construction belongs to Typed; native closing/erasure belongs to the
-- native pipeline. New compiler code consumes the owned products directly.
module Frontend.Desugar.Checked
  (module Frontend.Desugar.Typed,
   Desugared,desugaredCore,desugaredTyped,desugaredClosed,desugaredTypeContext,
   desugarCheckedUnit,lowerCheckedUnit,desugarCheckedUnitWith,lowerCheckedUnitWith,
   desugarSpecialized,lowerSpecialized,desugarSpecializedWith,lowerSpecializedWith,
   compileTopChecked,lowerToUntyped) where
import Frontend.Desugar.Typed
import Frontend.Desugar (D,DEnv(..))
import qualified Compiler.Native.Core as Native
import Compiler.DataLayout
import Core.Typed.Callback
import Core.Typed.Pipeline
import Core.Typed.Program
import Core.Syntax (Prog)
import Frontend.Syntax (STop)
import Control.Monad.State.Strict (get,modify)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

newtype Desugared=Desugared Native.NativeCore
desugaredCore (Desugared p)=Native.nativeProgram p
desugaredTyped (Desugared p)=programFunctions (closedInput (Native.nativeClosed p))
desugaredClosed (Desugared p)=closedDefinitions (Native.nativeClosed p)
desugaredTypeContext (Desugared p)=programTypes (closedInput (Native.nativeClosed p))

bridge :: CallbackMode -> (S.Set String -> Either String SourceSelection) -> D Desugared
bridge mode select=do
  state<-get
  selected<-either error pure (select (M.keysSet (dCons state)))
  output<-either error pure (Native.compileSelectionAt (dFresh state) mode (Layouts (dCons state) (dShapes state)) selected)
  modify (\s->s {dFresh=Native.nativeFresh output,dJoins=S.toList (Native.nativeJoins output)++dJoins s})
  pure (Desugared output)

desugarCheckedUnit :: CheckedUnit -> D Desugared
desugarCheckedUnit=desugarCheckedUnitWith PreserveCallbacks
desugarCheckedUnitWith :: CallbackMode -> CheckedUnit -> D Desugared
desugarCheckedUnitWith mode unit=bridge mode (\constructors->selectUnit constructors unit)
lowerCheckedUnit :: CheckedUnit -> D Prog
lowerCheckedUnit=lowerCheckedUnitWith PreserveCallbacks
lowerCheckedUnitWith :: CallbackMode -> CheckedUnit -> D Prog
lowerCheckedUnitWith mode=fmap desugaredCore . desugarCheckedUnitWith mode

desugarSpecialized :: SpecializedSource -> S.Set String -> D Desugared
desugarSpecialized=desugarSpecializedWith PreserveCallbacks
desugarSpecializedWith :: CallbackMode -> SpecializedSource -> S.Set String -> D Desugared
desugarSpecializedWith mode source names=bridge mode (\constructors->selectSpecialized constructors source names)
lowerSpecialized :: SpecializedSource -> S.Set String -> D Prog
lowerSpecialized=lowerSpecializedWith PreserveCallbacks
lowerSpecializedWith :: CallbackMode -> SpecializedSource -> S.Set String -> D Prog
lowerSpecializedWith mode source names=desugaredCore <$> desugarSpecializedWith mode source names

compileTopChecked :: CheckedPlans -> [STop] -> D Desugared
compileTopChecked plans tops=bridge PreserveCallbacks (\constructors->selectClauses constructors plans tops)
lowerToUntyped :: CheckedPlans -> [STop] -> D Prog
lowerToUntyped plans tops=desugaredCore <$> compileTopChecked plans tops
