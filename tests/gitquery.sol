Git = use "../sol/lib/git".

show label result = case result of
  Ok value -> print "{label}: Ok [{value}]"
| Err msg -> print "{label}: Err [{msg}]".

> r = Git.repo "/tmp/sol-git-wrap";
  u1 = show "status" (Git.status r);
  u2 = show "log" (Git.log 1 r);
  show "head" (Git.head r).
