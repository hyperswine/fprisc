-- Adapt retained pass facts to the public remark vocabulary. No decisions
-- are rediscovered by parsing rendered notes or generated assembly.
module Compiler.Remarks (collect,writeRemarks) where
import qualified Core.Typed.Decision as D
import Core.Typed.Pipeline (closedDecisions)
import qualified Diagnostic.Remark as R
import qualified Diagnostic.Render as D
import qualified Compiler.Native.Core as N
import qualified Compiler.Native.Regions as Regions
import qualified Core.Typed.Fusion as F
import qualified Core.Typed.FusionSafety as S
import qualified ReceiveTurns as Turns
import Core.Syntax (freeVars)
import Data.Graph (SCC(..),stronglyConnComp)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import System.IO (hPutStrLn,stderr)

collect :: [N.NativeCore] -> [Regions.Result] -> [F.FusionNote] -> [R.Remark]
collect natives regions fusion=Set.toAscList (Set.fromList (paths++fusions++boundaries++attempts))
  where
    program=M.unions (map N.nativeProgram natives)
    homes=M.unions [M.map N.checkedOwner (N.nativeDefinitions native) | native<-natives]
    sourceOwner n=M.findWithDefault n n homes
    recursive=Set.fromList [sourceOwner n | CyclicSCC ns<-stronglyConnComp
      [(n,n,filter (`M.member` program) (filter (`notElem` ps) (freeVars body))) | (n,(ps,body))<-M.toList program],n<-ns]
    groups=concatMap Regions.resultGroups regions
    receiving=Set.fromList [sourceOwner n | g<-groups,not (Turns.groupPure g),n<-Turns.groupMembers g]
    heat n | n `Set.member` receiving=R.ReceiveLoop
           | n `Set.member` recursive=R.RecursiveGroup
           | otherwise=R.Cold
    attempts=[case decision of
      D.InlineDecision n target why->R.Remark n (heat n) (R.InlineAttempt target why)
      D.CallbackDecision n target why->R.Remark n (heat n) (R.CallbackAttempt target why)
      | native<-natives,decision<-closedDecisions (N.nativeClosed native)]
    paths=[R.Remark n (heat n) (R.CompatibilityLowering why) | native<-natives,(n,why)<-M.toList (N.nativeCompatibility native)]
    fusions=[R.Remark n (heat n) (refusal why) | F.FusionNote n _ _ _ why<-fusion]
    refusal why=case why of
      F.CallbackEffect name cause->R.CallbackEffect name (effect cause) (S.renderReason cause)
      F.CaptureEffect->R.CaptureEffect;F.CaptureBudget->R.CaptureBudget
    effect why=case why of
      S.UnknownFunction _->R.UnknownFunction;S.Primitive _->R.Primitive;S.Partial _->R.Partial
      S.UnknownCall _->R.UnknownCall;S.FunctionValue _->R.FunctionValue;S.Recursive _->R.Recursive
      S.Failure->R.Failure;S.Unsupported _->R.Unsupported
    boundaries=[R.Remark (sourceOwner n) (heat (sourceOwner n)) (if Turns.groupPure g then R.LoopRegionPlaced
      else if Turns.groupLooped g then R.ReceiveRegionPlaced else R.ReceiveTrampolinePlaced)
      | g<-groups,n<-Turns.groupMembers g]

writeRemarks :: R.Mode -> D.Sources -> D.Anchors -> [R.Remark] -> IO ()
writeRemarks R.Off _ _ _=pure ()
writeRemarks mode sources anchors remarks=do
  if mode==R.JSON then hPutStrLn stderr (R.renderInputs sources) else pure ()
  mapM_ (hPutStrLn stderr . render) (filter (R.selected mode) remarks)
  where render=if mode==R.JSON then R.renderJSON sources anchors else R.renderText sources anchors
