# system-report.sol -- collect a portable host snapshot without a shell.
# Every command is a structured, read-only Proc.query. Failures stay on the
# Result rail; an optional report file is written in one Sol transaction.
#
#   ./fpr sol sol/scripts/system-report.sol
#   ./fpr sol sol/scripts/system-report.sol report.txt

P = use "../lib/proc".

section title body =
  "---------------------------------------------------\n{title}\n---------------------------------------------------\n{body}".

capture title argv =
  P.output (Proc.query (P.spec argv))
    |> mapOk (fn body -> section title body)
    |> context title.

buildReport u = collect [
  capture "Date" ["date", "-u"],
  capture "Hostname" ["hostname"],
  capture "Operating system" ["uname", "-a"],
  capture "Uptime" ["uptime"],
  capture "Disk usage" ["df", "-h"],
  capture "Processes" ["ps", "-Ao", "pid,ppid,%cpu,%mem,command"]
] |> mapOk (fn sections -> Str.join "\n" sections).

emit target result = case result of
  Err message -> error "system-report: {message}"
| Ok report -> case target == "" of
    True -> print report
  | False -> u = writePath target report; print "system-report: wrote {target}".

execute argv = case argv of
  [] -> emit "" (buildReport Unit)
| target :: [] -> emit target (buildReport Unit)
| _ -> error "usage: system-report.sol [OUTPUT]".

> execute (args Unit).
