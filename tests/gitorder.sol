# Commit and push in ONE script: the push would publish the pre-commit head,
# so it is refused. Commit in one run, push in the next.
Git = use "../sol/lib/git".

> r = Git.repo "/tmp/sol-git-wrap"
      |> Git.identity "Sol Test" "sol@example.invalid"
      |> Git.add Git.all
      |> Git.commit "fourth commit";
  res = Git.push "origin" "main" r;
  print "push: {res}".
