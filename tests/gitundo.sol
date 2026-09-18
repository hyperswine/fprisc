Git = use "../sol/lib/git".

> r = Git.repo "/tmp/sol-git-wrap"
      |> Git.untag "v1"
      |> Git.deleteBranch "feature"
      |> Git.uncommit Git.keepStaged
      |> Git.unadd Git.all;
  print "queued conventional git undo operations".
