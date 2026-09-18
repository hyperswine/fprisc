Git = use "../sol/lib/git".

> r = Git.repo "/tmp/sol-git-wrap"
      |> Git.identity "Sol Test" "sol@example.invalid"
    |> Git.initOn "main"
      |> Git.add Git.all
      |> Git.commit "first commit"
      |> Git.branch "feature"
      |> Git.tag "v1";
  print "queued core git operations".
