# Sol as a text tool: can it stand in for awk, sed and the shell?

An evaluation, done from the command line with `fpr sol`, of the
ordinary text jobs one reaches for awk, sed, grep, sort, uniq, tr and a
line of bash to do: select lines, number them, print a range, substitute,
delete, split fields, sum a column, count by key, sort, dedupe, count
runs, case-fold, trim, read a pipe, read a tool's output.  The scripts are
in sol/scripts/text/ and run against sample.log / staff.txt there; the
check-all leg "sol as a text tool" runs them.

    fpr sol sol/scripts/text/grep.sol ERROR sol/scripts/text/sample.log
    fpr sol sol/scripts/text/sed.sol p 3 5 FILE        # sed -n '3,5p'
    fpr sol sol/scripts/text/sed.sol s took= t= FILE   # sed 's/took=/t=/g'
    fpr sol sol/scripts/text/sed.sol d INFO FILE       # sed '/INFO/d'
    fpr sol sol/scripts/text/awk.sol cols FILE         # awk -F: '{print $1, $3}'
    fpr sol sol/scripts/text/awk.sol sum 4 FILE        # awk -F: '{s+=$4} END{print s}'
    fpr sol sol/scripts/text/awk.sol count 3 FILE      # cut -d: -f3 | sort | uniq -c
    fpr sol sol/scripts/text/sortuniq.sol uniqc FILE   # sort | uniq -c
    cat FILE | fpr sol sol/scripts/text/stdin.sol WARN # a filter in a pipe
    fpr sol sol/scripts/text/shell.sol DIR             # ls -l, parsed
    fpr sol sol/scripts/text/rx.sol -o 'took=\d+' FILE # grep -oE

## What worked at once

Everything on that list was a few lines each, and reads better than the
awk it replaces once there is more than one step: `Str.lines (readPath
path)` is the input, `List.filter` / `List.map` / `List.groupby` /
`List.sum` are the verbs, `args Unit` is argv, `input Unit` is stdin,
`sh cmd` gives `(exit, output)` of a tool, string interpolation is the
output format.  A group count is one line:

    counts n ls = List.map countLine (List.groupby (field n) ls).

The regex was the interesting one: there is no regex engine, so rx.sol
is a 100-line backtracking matcher in Sol itself (`. * + ? ^ $ [a-z]
[^..] \d \w \s`), and it is correct on every pattern tried, including
`-o` (the first match per line).  It is also the slowest thing here --
see below.

## What bit, in the order it bit

* `keep` is a builtin (the FPRISC keep), so a helper named `keep`
  is a type error about "declared type of keep".  Pick another name.
* A lambda cannot take a tuple pattern (`fn (k, g) -> ...`); write a
  named helper with the pattern in its clause.
* Recursive helpers need `unsafe` signatures or the script needs
  `unsafe program.` at the top (the safety line).  For a throwaway
  text script the blanket marker is the right answer; the scripts here
  carry it.
* `<` / `<=` compare Ints only; there was no string order at all.
  `Str.cmp` (below) is the comparator now.
* No `List.reverse` (a fold does it), no sort (sortuniq.sol carries a
  merge sort), `xs ! i` is O(i).
* Two lines of VM telemetry landed on stdout (`[table] ... dropped`)
  and one on stderr (`[gpu] init ...`) on every run; a tool in a pipe
  cannot have that.  The table lines are on stderr now.  The gpu line
  is still there.
* `use "../lib/base"` is relative to the script's directory; a script
  outside the tree cannot see lib/ (documented; still a surprise).
* There is no one-liner mode: everything is a file.

## The number that mattered: Str.lines was quadratic

The first timing was the whole story: a 2000-line, 116 KB file took 66
seconds to line-count, and 100k lines was killed for memory.  `readPath`
was 0.2 s of that; `Str.lines` was the rest.  The preamble's `Str.split`
found the next separator and then `substr`-copied the REST of the string
for the recursive call, so splitting cost size x lines, and `strlen`
(O(n) on the list-of-char string) ran on every step.  The same shape sat
under `Str.indexOf`, `Str.replace`, `Str.trim`, `Str.upper/lower` and
`Str.join`.

Those are native now (VM.hs, one pass each: `strSplit`, `strIndexOf`,
`strReplace`, `strUpper`, `strLower`, `strTrim`, `strJoin`, plus
`strCmp` for `Str.cmp` and `strCodes` for `Str.codes`); the preamble's
`Str` record dispatches to them with the same semantics, and
sol/examples/strings.sol still says OK.  After that:

| job, 100 000 lines / 6 MB          | Sol      | the tool    |
|-------------------------------------|----------|-------------|
| line count                          | 2.9 s    | wc: 0.01 s  |
| grep -n                             | 6.5 s    | 0.008 s     |
| sed s/old/new/g                     | 4.7 s    | 0.05 s      |
| awk column sum                      | 9.7 s    | 0.05 s      |
| sort (merge sort in Sol, Str.cmp)   | 54 s     | 0.03 s      |
| grep -oE, the regex written in Sol  | 7 min    | 0.04 s      |
| the same jobs before the fix        | minutes to killed | -- |

2000 lines went from 66 s to 0.18 s.  So: a few seconds for a
100k-line file on the one-pass jobs, which is fine for a script; two to
three orders of magnitude behind the C tools; and anything that walks
a string by index in Sol (the matcher, a comparator) pays the
interpreter's per-op cost times the string, which is why `Str.codes`
exists (walk a list instead) and why a regex engine would have to be
native to be a tool.

## Verdict

As a language for these jobs Sol is already pleasant: the scripts are
shorter than the bash+awk+sed they replace, typed, and transactional
(a filter that writes its output file either lands or does not).  As a
replacement for the tools it is not there yet, and the gaps are
concrete:

1. A native regex (match, find, replace, split) -- the one thing every
   text task wants and the one thing that cannot be written in Sol at
   tool speed.
2. `List.sort` / `List.sortBy` and `List.reverse` native.
3. A one-liner mode (`fpr sol -e '...'`) with the script's argv and
   stdin pre-bound, and the startup telemetry off by default.
4. The list-of-char string: `charAt` and `!` are O(i); a packed
   representation (BStr already exists as the linear fast tier) would
   close most of the remaining gap on the one-pass jobs.
