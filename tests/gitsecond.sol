Git = use "../sol/lib/git".

> r = Git.repo "/tmp/sol-git-wrap"
      |> Git.identity "Sol Test" "sol@example.invalid"
      |> Git.add (Git.paths ["second.txt"])
      |> Git.commit "second commit";
  print "queued second commit".
