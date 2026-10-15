# Native host snapshot. FP-RISC owns rendering and report policy.
System = use "../lib/system".

section title body =
  "---------------------------------------------------\n{title}\n---------------------------------------------------\n{body}".

diskRow (path, total, available) = "{path}: total={total} available={available} bytes".
processRow (pid, ppid, name) = "{pid}\t{ppid}\t{name}".
renderReport (date, host, os, uptime, disks, processes) = Str.join "\n" [
  section "Date" date,
  section "Hostname" host,
  section "Operating system" os,
  section "Uptime" "{uptime} seconds",
  section "Disk usage (bytes)" (Str.join "\n" (List.map diskRow disks)),
  section "Processes (pid, parent pid, executable name)" (Str.join "\n" (List.map processRow processes))
].
buildReport u = System.snapshot Unit |> mapOk renderReport.

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
