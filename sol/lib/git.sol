# Native libgit2 automation. Mutations defer in journal order; queries see
# live pre-commit state. Push is the terminal deferred publication. No hooks or helpers.
Repo = Type (Repo String String String).
Selection = Type (All | Updated | Paths (List String)).
UncommitMode = Type (KeepStaged | KeepWorktree).
all = All.
updated = Updated.
paths ps = Paths ps.
keepStaged = KeepStaged.
keepWorktree = KeepWorktree.
outputLimit = 8388608.
repo path = Repo path "" "".
identity name email (Repo path _ _) = Repo path name email.
queue operation r = case r of Repo path name email ->
  u = NativeGit.afterCommit outputLimit path name email operation; r.
init r = queue (GitInit "main") r.
initOn branchName r = queue (GitInit branchName) r.
add selection r = case selection of
  All -> queue (GitAdd "all" []) r
| Updated -> queue (GitAdd "update" []) r
| Paths ps -> queue (GitAdd "paths" ps) r.
unadd selection r = case selection of
  All -> queue (GitUnadd "all" []) r
| Updated -> queue (GitUnadd "all" []) r
| Paths ps -> queue (GitUnadd "paths" ps) r.
commit message r = queue (GitCommit message) r.
uncommit mode r = case mode of
  KeepStaged -> queue (GitUncommit "soft") r
| KeepWorktree -> queue (GitUncommit "mixed") r.
branch name r = queue (GitBranch name) r.
deleteBranch name r = queue (GitDeleteBranch name) r.
switch name r = queue (GitSwitch name) r.
tag name r = queue (GitTag name) r.
untag name r = queue (GitUntag name) r.
query operation (Repo path _ _) = NativeGit.query outputLimit path operation.
# Native status rows are numeric libgit2 flags and quoted paths, not porcelain.
status r = query GitStatus r.
diff r = query GitDiff r.
diffStaged r = query GitDiffStaged r.
log count r = if count < 0 or count > 100000 then Err "Git.log count must be 0..100000" else query (GitLog count) r.
head r = query GitHead r.
headLater (Repo path _ _) = Deferred.trim (NativeGit.headLater outputLimit path).
tagAt name sha r = case r of Repo path _ _ ->
  u = NativeGit.tagAt outputLimit path name sha; r.
commitNow message (Repo path name email) = NativeGit.commitNow outputLimit path name email message.
push remote branchName r = case r of Repo path _ _ ->
  u = NativeGit.pushLater outputLimit path remote branchName; r.
pushNow remote branchName r = case r of Repo path _ _ ->
  NativeGit.push outputLimit path remote branchName |> mapOk (fn output -> r).
