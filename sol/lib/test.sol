# sol/lib/test.sol -- checks for the Sol scripts `fpr test` runs.
#
#   T = use "sol/lib/test".
#   > T.run [T.that "two is even" (2 % 2 == 0), T.equal "sum" 6 (1 + 2 + 3)].
#
# A Sol test is an ordinary script (docs/2026-10-31-PROJECT-WORKFLOW.md):
# `fpr test` passes it when it exits 0.  `run` prints one line per check,
# "ok N - name" or "not ok N - name: why", then ends the script with
# status 1 when any check failed.

that name ok = if ok then (name, "") else (name, "expected True").
equal name want got = if want == got then (name, "") else (name, "want {want}, got {got}").

failures : (checks : List (String, String) | measure checks) -> Int.
failures checks = case checks of
    [] -> 0
  | c :: rest -> (n, why) = c; (if why == "" then 0 else 1) + failures rest.

count : (checks : List (String, String) | measure checks) -> Int.
count checks = case checks of [] -> 0 | c :: rest -> 1 + count rest.

report : Int -> (checks : List (String, String) | measure checks) -> Unit.
report i checks = case checks of
    [] -> Unit
  | c :: rest -> (n, why) = c;
      _ = print (if why == "" then "ok {i} - {n}" else "not ok {i} - {n}: {why}");
      report (i + 1) rest.

run checks = _ = report 1 checks;
  bad = failures checks;
  total = count checks;
  if bad == 0 then print "{total} passed" else failed bad total.

failed bad total = _ = print "{bad} of {total} failed"; Script.exit 1.
