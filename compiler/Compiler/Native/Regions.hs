-- Owned checked interfaces, scoped analysis projections and derived cost
-- equations reach region placement together. Erased helper rewriting remains
-- explicit; no consumer re-infers types from its generated bodies.
module Compiler.Native.Regions
  (Program,prepare,programNative,programCore,programInterfaces,Context,context,
   Options(..),Analysis,analysisProgram,analysisCosts,Result,place,bypass,
   resultProgram,resultNotes,resultGenerated,resultAnalysis,resultTyped) where
import qualified Compiler.Native.Core as Native
import qualified Compiler.Native.Regions.Typed as Typed
import qualified Core.Typed.Syntax as T
import Core.Typed.Pipeline
import Compiler.DataLayout
import Core.Typed.Program (programNamespace,programTypes)
import Core.Identity
import Core.Syntax hiding (Prog)
import qualified Core.Syntax as C
import Core.Region.Interface
import qualified Core.Region.CallSites as Sites
import qualified Core.Region.Types as Region
import Core.Opt.Representation (eraseLayoutCasts)
import Core.Analysis.Scope (qualifyPrivate,programNames)
import qualified ReceiveTurns as Turns
import qualified Cost
import Safety (Measure)
import Control.Monad (unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

data Program=Program Native.NativeCore Namespace Layouts Region.ValueModel (M.Map Name Interface) (S.Set Name) C.Prog (S.Set Name)
programNative :: Program -> Native.NativeCore
programNative (Program native _ _ _ _ _ _ _)=native
programCore :: Program -> C.Prog
programCore (Program _ _ _ _ _ _ p _)=p
programInterfaces :: Program -> M.Map Name Interface
programInterfaces (Program _ _ _ _ fs _ _ _)=fs

prepare :: Native.NativeCore -> Either String Program
prepare native=do
  let closed=Native.nativeClosed native
      source=closedInput closed
      p=eraseLayoutCasts (Native.nativeProgram native)
      interfaces=closedInterfaces closed `M.union` M.mapWithKey declaredInterface (Native.nativeDeclarations native)
      shared=M.keysSet interfaces<>M.keysSet (Native.nativeCompatibility native)
  model<-Region.valueModel (programTypes source)
  mapM_ (\(name,f)->case M.lookup name p of
    Just (ps,_) | length ps==interfaceArity f->case interfaceParameters f of
      Just bs->unless (ps==map T.binderName bs) (Left ("region input: binder/erasure identity mismatch at "++name))
      Nothing->pure ()
    _->Left ("region input: physical interface mismatch at "++name)) (M.toList interfaces)
  pure (Program native (programNamespace source) (closedLayouts closed) model interfaces shared p (Native.nativeJoins native))

data Analysis=Analysis C.Prog (M.Map Name (Cost.CostEq,Cost.CostEq))
analysisProgram :: Analysis -> C.Prog
analysisProgram (Analysis p _)=p
analysisCosts :: Analysis -> M.Map Name (Cost.CostEq,Cost.CostEq)
analysisCosts (Analysis _ costs)=costs
data Context=Context Program (M.Map Name Measure) Analysis
context :: M.Map Name Measure -> Program -> Context
context measures source=let p=analysis "$region.context." S.empty source
                       in Context source measures (derive measures p)
derive measures p=Analysis p (Cost.costProgram measures M.empty p)
-- receiveLoops: receive loops take the loop form (False for a QOS process
-- image, whose plane memory reclaims per turn through $receiveLoop)
data Options=Options {loopRegions :: Bool,callRegions :: Bool,receiveLoops :: Bool} deriving (Eq,Show)
data Result=Bypassed Program | Placed Program Analysis Turns.Rewrite Typed.Program
resultProgram :: Result -> C.Prog
resultProgram (Bypassed p)=programCore p
resultProgram (Placed _ _ r _)=Turns.rewriteProgram r
resultNotes :: Result -> [String]
resultNotes (Bypassed _)=[]
resultNotes (Placed _ _ r _)=Turns.rewriteNotes r
resultGenerated :: Result -> M.Map Name Turns.Generated
resultGenerated (Bypassed _)=M.empty
resultGenerated (Placed _ _ r _)=Turns.rewriteGenerated r
resultAnalysis :: Result -> Maybe Analysis
resultAnalysis (Bypassed _)=Nothing
resultAnalysis (Placed _ a _ _)=Just a
resultTyped :: Result -> Maybe Typed.Program
resultTyped (Bypassed _)=Nothing
resultTyped (Placed _ _ _ p)=Just p
bypass :: Program -> Result
bypass=Bypassed

place :: Options -> Context -> Program -> Either String Result
place opts (Context (Program _ worldNs worldLayouts worldModel worldFaces worldShared _ _) measures base)
      input@(Program _ ns layouts model faces shared p joins)=do
  unless (ns==worldNs && model==worldModel && constructorLayouts layouts==constructorLayouts worldLayouts
    && shapeLayouts layouts==shapeLayouts worldLayouts) (Left "region context: checking namespace/layout model mismatch")
  let world=analysisProgram base
      local=analysis "$region.local." (programNames world) input
      -- A changed/unknown compatibility body must not acquire an interface
      -- from the context merely because its spelling matches a checked root.
      signatures=faces `M.union` M.withoutKeys worldFaces (M.keysSet p)
      allCode=local `M.union` world
      same=M.isSubmapOfBy (==) local world
      view=if same then base else derive measures allCode
  let arities=M.map (length . fst) allCode
      checked=Native.nativeDefinitions (programNative input)
  sites<-Sites.callSites model arities (M.mapWithKey (\name _->Native.checkedFunction <$> M.lookup name checked) p)
  rewrite<-Turns.receiveTurns (loopRegions opts) (callRegions opts) (receiveLoops opts) (analysisCosts view) signatures model sites
    (shared<>worldShared) allCode joins p
  typed<-Typed.build (programNative input) (M.map interfaceArity signatures) rewrite
  projection<-Typed.emitProgram typed
  published<-Turns.publish rewrite projection
  pure (Placed input view published typed)

-- Scope only compatibility auxiliaries for cross-view cost/effect analysis.
-- The emitted program is untouched. In particular, two independent legacy
-- fresh counters cannot accidentally identify each other's lifted_1.
analysis :: String -> S.Set Name -> Program -> C.Prog
analysis stem reserved (Program _ _ _ _ _ shared p _)=qualifyPrivate prefix shared p
  where
    occupied=reserved<>programNames p
    private=M.keysSet p S.\\ shared
    prefix=fresh (0::Int)
    fresh n=let candidate=stem++show n++"."
            in if S.null (S.map (candidate++) private `S.intersection` occupied) then candidate else fresh (n+1)
