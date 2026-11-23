module Compiler.Compile.Link (linkAndOptimize) where

import qualified Codegen as Backend (tgtW)
import Codegen.Policy (Policy (..), Profile (..))
import Compiler.CommandLine (CompileArguments (..))
import qualified Compiler.Native.Linked as Linked
import qualified Compiler.Options as Options
import Core.Typed.Callback (CallbackMode)
import Core.Typed.Fusion (FusionNote)
import qualified Diagnostic.Remark as Remark

linkAndOptimize ::
  CompileArguments ->
  Options.CodegenOptions ->
  Policy ->
  Remark.Mode ->
  CallbackMode ->
  [Either String Linked.NativeArtifact] ->
  Either String (Linked.LinkedProgram, [FusionNote], [String])
linkAndOptimize opts codegen irPolicy remarkMode callbackMode artifactResults = do
  base <- sequence artifactResults >>= Linked.linkArtifacts
  (listed, listNotes) <-
    if oArc opts || oBuiltin opts || not (Options.cgListFuse codegen)
      then pure (base, [])
      else checkedStage "checked list fusion" (Linked.fuseListLinkedWithHelpers (remarkMode /= Remark.Off) (not (oNoInline opts)) base)
  original <- checkedStage "callback specialization before inlining" (Linked.specializeLinkedWithDecisions (remarkMode /= Remark.Off) callbackMode listed)
  inlined <-
    if oArc opts || oNoInline opts
      then pure original
      else do
        inlined <- checkedStage "checked Base inlining" (Linked.inlineLinkedWithDecisions (remarkMode /= Remark.Off) 3 24 64 original)
        checkedStage "callback specialization after inlining" (Linked.specializeLinkedWithDecisions (remarkMode /= Remark.Off) callbackMode inlined)
  known <-
    if not (Options.cgCaseKnown codegen) || ((oArc opts || oBuiltin opts) && not (Options.cgTypeSpec codegen))
      then pure inlined
      else checkedStage "checked case of known constructor" (Linked.caseKnownLinked inlined)
  vectors <-
    if oArc opts || not (Options.cgVecPeek codegen)
      then pure known
      else checkedStage "checked vector reads" (Linked.planVectorReadsLinked known)
  normalized <-
    if oArc opts || oBuiltin opts || Backend.tgtW (oTarget opts) /= 8 || not (Options.cgReuse codegen)
      then pure vectors
      else checkedStage "checked Base normalization" (Linked.normalizeLinked vectors)
  (fused, notes) <-
    if oArc opts || not (Options.cgFusion codegen)
      then pure (normalized, listNotes)
      else do
        (fused, vecNotes) <- checkedStage "checked vector fusion" (Linked.fuseLinked normalized)
        pure (fused, listNotes ++ vecNotes)
  -- ARC erasure routes the proven store through its consuming adapter.
  -- The allocation-free raw runtime and 32-bit ABI remain excluded.
  (built, trmcNotes) <-
    if oRaw opts || polProfile irPolicy `notElem` [HostedBase, QosApp, Builtin, BuiltinArc] || Backend.tgtW (oTarget opts) /= 8 || not (Options.cgTrmc codegen)
      then pure (fused, [])
      else checkedStage "checked TRMC" (Linked.trmcLinked fused)
  pure (built, notes, trmcNotes)
  where
    checkedStage label = either (Left . ((label ++ ": ") ++)) Right
