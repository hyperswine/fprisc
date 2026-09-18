# git.sol -- typed, shell-free Git workflows over Proc.*.
#
# Mutations queue with Proc.afterCommit and return Repo so they compose:
#   Git.repo "." |> Git.add Git.all |> Git.commit "message"
# Queries run immediately and return Result. Push is deliberately realtime:
# it is externally visible, cannot be rolled back, and the runtime says so.
#
# ORDER MATTERS, and the runtime enforces it. Queued mutations only run at
# commit, so anything immediate -- push, and every query -- sees the state
# from BEFORE them. Pushing in the same script that queues a commit would
# publish the pre-commit head, so Proc.runNow refuses while effects are
# pending and push returns that Err. Commit in one run, push in the next:
#
#   run 1:  Git.repo "." |> Git.add Git.all |> Git.commit "message"
#   run 2:  Git.push "origin" "main" (Git.repo ".")

P = use "proc".

Repo = Type (Repo String (List (String, String))).
Selection = Type (All | Updated | Paths (List String)).
UncommitMode = Type (KeepStaged | KeepWorktree).

all = All.
updated = Updated.
paths ps = Paths ps.
keepStaged = KeepStaged.
keepWorktree = KeepWorktree.

repo path = Repo path [].

withEnv key value (Repo path env) = Repo path ((key, value) :: env).

identity name email r =
  r |> withEnv "GIT_AUTHOR_NAME" name
    |> withEnv "GIT_AUTHOR_EMAIL" email
    |> withEnv "GIT_COMMITTER_NAME" name
    |> withEnv "GIT_COMMITTER_EMAIL" email.

rawSpec args (Repo path env) =
  ProcessSpec ("git" :: "-C" :: path :: args) "" env "" 0.

initSpec (Repo path env) = ProcessSpec ["git", "init", path] "" env "" 0.
initOnSpec branchName (Repo path env) =
  ProcessSpec ["git", "init", "-b", branchName, path] "" env "" 0.

queue args r = u = Proc.afterCommit (rawSpec args r); r.

init r = u = Proc.afterCommit (initSpec r); r.
initOn branchName r = u = Proc.afterCommit (initOnSpec branchName r); r.

add selection r = case selection of
  All -> queue ["add", "--all"] r
| Updated -> queue ["add", "--update"] r
| Paths ps -> queue (["add", "--"] + ps) r.

unadd selection r = case selection of
  All -> queue ["reset"] r
| Updated -> queue ["reset"] r
| Paths ps -> queue (["reset", "--"] + ps) r.

commit message r = queue ["commit", "-m", message] r.

uncommit mode r = case mode of
  KeepStaged -> queue ["reset", "--soft", "HEAD~1"] r
| KeepWorktree -> queue ["reset", "--mixed", "HEAD~1"] r.

branch name r = queue ["branch", name] r.
deleteBranch name r = queue ["branch", "-d", name] r.
switch name r = queue ["switch", name] r.
tag name r = queue ["tag", name] r.
untag name r = queue ["tag", "-d", name] r.

query args r = P.output (Proc.query (rawSpec args r)).
status r = query ["status", "--porcelain=v2", "--branch"] r.
diff r = query ["diff", "--no-ext-diff"] r.
diffStaged r = query ["diff", "--cached", "--no-ext-diff"] r.
log count r = query ["log", "--format=%H%x09%s", "-n", str count] r.
head r = query ["rev-parse", "HEAD"] r.

# Remote publication is immediate and irreversible. It returns the Repo only
# on exit 0 so callers can continue explicitly with |>?.
push remote branchName r = case Proc.runNow (rawSpec ["push", remote, branchName] r) of
  Ok (ProcessResult 0 _ _) -> Ok r
| Ok (ProcessResult code stdout stderr) -> Err "git push exited {code}: {stderr}{stdout}"
| Err msg -> Err msg.
