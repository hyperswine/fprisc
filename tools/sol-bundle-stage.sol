# Stream the selected source files between tar processes. NUL-separated names
# preserve whitespace, and tar retains relative symlinks and executable bits.
B = use "../sol/lib/build".
links = [("launch-sol","fpr"),("core","source/core"),("std","source/std"),("sol","source/sol")].
verifyLink bundle pair =
  (name,target) = pair;
  ProcessResult status out _ = unwrap (Proc.runNow (ProcessSpec ["readlink","{bundle}/{name}"] "" [] "" 0));
  if and (status == 0) (out == target + "\n") then Unit else error "unexpected bundle link {bundle}/{name}".
stage root binary bundle inventory =
  source = "{bundle}/source";
  _ = B.command ["mkdir","-p",source];
  _ = B.command ["cp","-p",binary,"{bundle}/fpr"];
  _ = List.map (fn pair -> (name,target) = pair; B.command ["ln","-s",target,"{bundle}/{name}"]) links;
  env = [("COPYFILE_DISABLE","1")];
  create = ProcessSpec ["tar","-cf","-","--null","-T",inventory] root env "" 0;
  extract = ProcessSpec ["tar","-xpf","-"] source env "" 0;
  case Proc.pipeline (PipelineSpec [create,extract] (PipeBytes (Bytes.empty Unit)) PipeDiscard PipeOutputInherit 0 PipeFail) of
    Ok (PipelineResult 0 _ _ _) -> Unit
  | Ok (PipelineResult code statuses _ _) -> error "source staging exited {code}: {statuses}"
  | Err why -> error "{why}".
> case args Unit of [root,binary,bundle,inventory] -> stage root binary bundle inventory
  | ["verify",bundle,staged] -> _ = B.command ["cmp","-s","{bundle}/manifest.json","{staged}/manifest.json"]; _ = List.map (verifyLink bundle) links; Unit
  | _ -> error "usage: sol-bundle-stage.sol ROOT BINARY BUNDLE INVENTORY".
