# Run from tests/bench/clbg after sol build.sol: sol run.sol [program ...] < /dev/null
# RUNS (default 3) timed runs per program and language, after one untimed warm-up run; LANGS (comma separated) picks languages.
# Each run is timed by a Perl wrapper (microsecond wall clock) under /usr/bin/time -l (peak
# RSS, instructions retired; both include the few MB / few million instructions of the Perl
# wrapper). Output is checked against expected/<program>.md5. Writes results/<date>-<host>.md
# and .tsv, and prints the markdown.
unsafe program.
B = use "../../../sol/lib/build".
programs = [("binarytrees","18"),("fannkuchredux","10"),("nbody","5000000"),("spectralnorm","2000"),
            ("mandelbrot","4000"),("fasta","2500000"),("knucleotide","data/fasta-1000000.txt"),
            ("revcomp","data/fasta-2500000.txt")].
allLangs = ["fpr","c","rust","go","java","ocaml","haskell","js","python"].
peers = ["c","rust","go","java","ocaml","haskell","js","python"].
className name = "{Str.upper (Str.sub name 0 1)}{Str.slice name 1 (Str.len name)}".
command lang name =
  if lang == "fpr" then ["bin-fpr/{name}"]
  else if lang == "java" then ["java","-cp","bin/java-classes",className name]
  else if lang == "js" then ["node","js/{name}.js"]
  else if lang == "python" then ["python3","python/{name}.py"]
  else ["bin/{name}.{lang}"].
timer = "use Time::HiRes qw(time); open STDOUT, '>', shift or die; $t = time; system @ARGV; $s = $?; printf STDERR qq(wall %d\\n), (time - $t) * 1000000; exit($s >> 8)".
lead line = t = Str.trim line; k = Str.find 32 t; Str.parse (if k < 0 then t else Str.slice t 0 k).
field key lines = case List.filter (fn l -> Str.contains key l) lines of l :: _ -> lead l | [] -> 0.
wallOf lines = case List.filter (fn l -> Str.startsWith "wall " l) lines of l :: _ -> Str.parse (Str.slice l 5 (Str.len l)) | [] -> 0.
# one run: (wall us, rss bytes, instructions, output ok)
once lang name arg =
  argv = List.append ["/usr/bin/time","-l","perl","-e",timer,"bin/run.out"] (List.append (command lang name) [arg]);
  ProcessResult code _ err = unwrap (Proc.runNow (ProcessSpec argv "" [] "" 0));
  lines = Str.lines err;
  ok = code == 0 and B.query ["md5","-q","bin/run.out"] == Str.trim (readPath "expected/{name}.md5");
  (wallOf lines, field "maximum resident set size" lines, field "instructions retired" lines, ok).
insert : unsafe Int -> List Int -> List Int.
insert x xs = case xs of [] -> [x] | y :: rest -> if x <= y then x :: xs else y :: insert x rest.
sorted xs = List.fold (fn acc x -> insert x acc) [] xs.
median xs = s = sorted xs; s ! (List.len s / 2).
first4 (a, _, _, _) = a.
second4 (_, b, _, _) = b.
third4 (_, _, c, _) = c.
fourth4 (_, _, _, d) = d.
repeatRuns : unsafe Int -> String -> String -> String -> List (Int, Int, Int, Bool) -> List (Int, Int, Int, Bool).
repeatRuns n lang name arg acc = if n <= 0 then acc else repeatRuns (n - 1) lang name arg (once lang name arg :: acc).
# (program, lang, median wall us, median rss bytes, min instructions, all ok)
measure runs (name, arg) lang =
  warm = once lang name arg;
  rs = repeatRuns runs lang name arg [];
  _ = print "{name} {lang} {List.map first4 rs}";
  (name, lang, median (List.map first4 rs), median (List.map second4 rs), (sorted (List.map third4 rs)) ! 0, List.all fourth4 rs).
rName (n, _, _, _, _, _) = n.
rLang (_, l, _, _, _, _) = l.
rOk (_, _, _, _, _, ok) = ok.
pName (n, _) = n.
cell rows name lang = case List.filter (fn r -> rName r == name and rLang r == lang) rows of r :: _ -> r | [] -> (name, lang, 0, 0, 0, False).
wallAt rows name lang = (_, _, w, _, _, _) = cell rows name lang; w.
rssAt rows name lang = (_, _, _, m, _, _) = cell rows name lang; m.
# fixed point helpers: x / 10^d written with d decimals
pad : unsafe Int -> String -> String.
pad d s = if Str.len s >= d then s else pad d "0{s}".
pow10 : unsafe Int -> Int.
pow10 d = if d <= 0 then 1 else 10 * pow10 (d - 1).
fixed d x = "{x / pow10 d}.{pad d "{x % pow10 d}"}".
secs us = fixed 3 ((us + 500) / 1000).
mb bytes = "{(bytes + 524288) / 1048576}".
# ratio a/b with one decimal
ratio a b = if b <= 0 then "-" else fixed 1 ((a * 10 + b / 2) / b).
# log2 of x / 2^16 in 16.16 fixed point, by squaring
one = 65536.
lg x = lgInt x 0.
lgInt : unsafe Int -> Int -> Int.
lgInt x ip = if x >= 2 * one then lgInt (x / 2) (ip + 1) else if x < one then lgInt (x * 2) (ip - 1) else lgFrac x 16 (ip * one) (one / 2).
lgFrac : unsafe Int -> Int -> Int -> Int -> Int.
lgFrac x k acc bit = if k <= 0 then acc else
  y = x * x / one;
  if y >= 2 * one then lgFrac (y / 2) (k - 1) (acc + bit) (bit / 2) else lgFrac y (k - 1) acc (bit / 2).
# geometric mean of ratios a_i / b_i, times 100, by bisection on the mean log
lgRatio (a, b) = if a <= 0 or b <= 0 then 0 else lg (a * one / b).
geo pairs = target = List.fold (fn s p -> s + lgRatio p) 0 pairs;
  n = List.len pairs;
  bisect n target 1 10000000.
bisect : unsafe Int -> Int -> Int -> Int -> Int.
bisect n target lo hi = if hi - lo <= 1 then lo else
  mid = (lo + hi) / 2;
  if n * lg (mid * one / 100) <= target then bisect n target mid hi else bisect n target lo mid.
medianOf xs = median xs.
peerMedian rows name = medianOf (List.map (fn l -> wallAt rows name l) peers).
row rows langs (name, _) = "| {name} | {Str.join " | " (List.map (fn l -> secs (wallAt rows name l)) langs)} | {ratio (wallAt rows name "fpr") (wallAt rows name "c")} | {ratio (wallAt rows name "fpr") (peerMedian rows name)} |".
memRow rows langs (name, _) = "| {name} | {Str.join " | " (List.map (fn l -> mb (rssAt rows name l)) langs)} |".
tsvRow (n, l, w, m, i, ok) = "{n}\t{l}\t{w}\t{m}\t{i}\t{if ok then "ok" else "WRONG"}".
geoLine rows chosen label lang = "- {label}: {fixed 2 (geo (List.map (fn p -> (wallAt rows (pName p) "fpr", wallAt rows (pName p) lang)) chosen))}x".
report rows langs chosen stamp runs =
  hasAll = List.all (fn l -> List.has l langs) allLangs;
  wrong = List.filter (fn r -> not (rOk r)) rows;
  Str.join "\n" (List.append [
    "# Benchmarks Game suite, {stamp}", "",
    "Median wall seconds of {runs} runs; the last two columns are FP-RISC time over C and over the median of the eight peers.", "",
    "| program | {Str.join " | " langs} | fpr/C | fpr/peers |",
    "|---|{Str.join "" (List.map (fn x -> "---|") langs)}---|---|"]
    (List.append (List.map (row rows langs) chosen)
    (List.append ["", "Peak RSS, MB:", "", "| program | {Str.join " | " langs} |", "|---|{Str.join "" (List.map (fn x -> "---|") langs)}"]
    (List.append (List.map (memRow rows langs) chosen)
    (List.append ["", "Geometric mean of FP-RISC time over:"]
    (List.append (if hasAll then List.append (List.map (fn l -> geoLine rows chosen l l) peers) [] else [])
    ["", if wrong == [] then "Every output matched expected/." else "WRONG OUTPUT: {Str.join ", " (List.map (fn r -> "{rName r}/{rLang r}") wrong)}", ""])))))).
>! runs = Str.parse (B.setting "RUNS" "3");
  langs = (case unwrap (Env.get "LANGS") of EnvText s -> (if s == "" then allLangs else Str.split 44 s) | EnvMissing -> allLangs);
  chosen = (case args Unit of [] -> programs | names -> List.filter (fn p -> List.has (pName p) names) programs);
  rows = List.concat (List.map (fn p -> List.map (measure runs p) langs) chosen);
  stamp = "{B.query ["date","+%Y-%m-%d-%H%M"]}-{B.query ["hostname","-s"]}";
  text = report rows langs chosen stamp runs;
  _ = B.command ["mkdir","-p","results"];
  _ = writePath "results/{stamp}.md" text;
  _ = writePath "results/{stamp}.tsv" (Str.join "\n" (List.append ["program\tlang\twall_us\trss_bytes\tinstructions\toutput"] (List.map tsvRow rows)));
  print text.
