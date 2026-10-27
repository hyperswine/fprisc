Git = use "../sol/lib/git".

> r = Git.repo "/tmp/sol-git-wrap";
  result = Git.pushNow "origin" "main" r;
  print "push: {result}".
