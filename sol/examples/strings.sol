# strings.sol -- the builtin vocabulary, as an executable spec.  Str.*,
# List.*, the booleans and Numeric are PRELUDE: scripts should reach for
# these before writing a helper.  Every line asserts one builtin.
#
#   ./fpr sol sol/examples/strings.sol

expect what got want = case got == want of
    True -> print "ok  {what}"
  | False -> error "FAIL {what}: got {got}, wanted {want}".

# ---- Str ----
> expect "Str.len"        (Str.len "hello") 5.
> expect "Str.slice"      (Str.slice "abcdef" 2 4) "bcd".
> expect "Str.sub"        (Str.sub "abcdef" 3 2) "cd".
> expect "Str.find"       (Str.find 98 "abc") 2.
> expect "Str.find miss"  (Str.find 122 "abc") 0.
> expect "Str.findFrom"   (Str.findFrom 97 "abab" 2) 3.
> expect "Str.indexOf"    (Str.indexOf "cd" "abcdef") 3.
> expect "Str.indexOf miss" (Str.indexOf "zz" "abcdef") 0.
> expect "Str.contains"   (Str.contains "cd" "abcdef", Str.contains "dc" "abcdef") (True, False).
> expect "Str.startsWith" (Str.startsWith "ab" "abc", Str.startsWith "bc" "abc") (True, False).
> expect "Str.endsWith"   (Str.endsWith "bc" "abc", Str.endsWith "ab" "abc") (True, False).
> expect "Str.split"      (Str.split 44 "a,b,,c") ["a", "b", "", "c"].
> expect "Str.lines"      (Str.lines "x\ny\n") ["x", "y"].
> expect "Str.words"      (Str.words "  hi   there ") ["hi", "there"].
> expect "Str.join"       (Str.join ", " ["a", "b", "c"]) "a, b, c".
> expect "Str.join empty" (Str.join ", " []) "".
> expect "Str.trim"       (Str.trim "  pad  ") "pad".
> expect "Str.trimL/R"    (Str.trimL "  x ", Str.trimR " x  ") ("x ", " x").
> expect "Str.replace"    (Str.replace "o" "0" "foo boo") "f00 b00".
> expect "Str.upper"      (Str.upper "MiXed 1") "MIXED 1".
> expect "Str.lower"      (Str.lower "MiXed 1") "mixed 1".
> expect "Str.repeat"     (Str.repeat 3 "ab") "ababab".
> expect "Str.parse"      (Str.parse "42") 42.
> expect "Str.isSpace"    (Str.isSpace 32, Str.isSpace 97) (True, False).
> expect "Try.parseNum"    (Try.parseNum "2.5", Try.parseNum "-1e3", Try.parseNum "7") (Ok 2.5, Ok -1000, Ok 7).
> expect "Try.parseNum refuses" (isOk (Try.parseNum "1.2.3"), isOk (Try.parseNum "")) (False, False).

# ---- booleans (strict: both sides evaluate) ----
> expect "not" (not True, not False) (False, True).
> expect "and" (and True True, and True False) (True, False).
> expect "or"  (or False True, or False False) (True, False).
> expect "xor" (xor True True, xor True False) (False, True).

# ---- List ----
> expect "List.len"     (List.len [1, 2, 3]) 3.
> expect "List.take"    (List.take 2 [1, 2, 3]) [1, 2].
> expect "List.drop"    (List.drop 2 [1, 2, 3]) [3].
> expect "List.sum"     (List.sum [1, 2, 3]) 6.
> expect "List.has"     (List.has 2 [1, 2, 3], List.has 9 [1, 2, 3]) (True, False).
> expect "List.zip"     (List.zip [1, 2] ["a", "b"]) [(1, "a"), (2, "b")].
> expect "List.concat"  (List.concat [[1], [2, 3], []]) [1, 2, 3].
> expect "List.range"   (List.range 1 4) [1, 2, 3, 4].
> expect "List.last"    (List.last [1, 2, 3]) 3.
> expect "List.map"     (List.map (fn x -> x * 2) [1, 2]) [2, 4].
> expect "List.filter"  (List.filter (fn x -> x > 1) [1, 2, 3]) [2, 3].
> expect "List.fold"    (List.fold (fn a x -> a + x) 0 [1, 2, 3]) 6.
> expect "List.find"    (List.find (fn x -> x > 1) [1, 2, 3], List.find (fn x -> x > 9) [1, 2, 3]) ([2], []).
> expect "List.groupby" (List.groupby (fn x -> x % 2) [1, 2, 3, 4]) [(1, [1, 3]), (0, [2, 4])].

# ---- Numeric ----
> expect "% (Numeric.mod)" (7 % 3) 1.
> expect "Numeric.abs" (Numeric.abs (0 - 4)) 4.
> print "strings: OK".
