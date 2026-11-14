# Every std module is on the safety allow-list (port of the retired
# tests/check_trust.py; compiler/Safety.hs approvedLibraries,
# docs/2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md). A module not on the list has its
# public functions refused in every safe program that uses it; a new module is
# added to the list WITH a line in that review page about its unsafe helpers.
# Known gaps are rows "trust:std/<module>.fpr" in tests/sol-checks-known-failures.tsv.
H = use "helpers".
moduleChar c = (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95.
quotedModule s = Str.startsWith "std/" s and Str.endsWith ".fpr" s and Str.len s > 8
  and List.all moduleChar (Str.codes (Str.slice s 4 (Str.len s - 4))).
> root = H.root Unit;
  listed = List.filter quotedModule (Str.split 34 (readPath "{root}/compiler/Safety.hs"));
  modules = List.map (fn n -> "std/{n}") (List.filter (fn n -> Str.endsWith ".fpr" n) (ls "{root}/std"));
  missing = List.filter (fn m -> not (List.has m listed)) modules;
  stale = List.filter (fn m -> not (H.isFile "{root}/{m}")) listed;
  _ = List.map (fn m -> print "{m}: not on the safety allow-list (compiler/Safety.hs approvedLibraries)") missing;
  _ = List.map (fn m -> print "{m}: on the allow-list but no such file") stale;
  _ = print "Safety allow-list: {List.len modules} std modules, {List.len missing} not listed, {List.len stale} stale";
  H.settle "trust" root (List.append missing stale).
