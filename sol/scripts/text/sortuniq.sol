unsafe program.
# sortuniq.sol -- sort, sort -u, uniq -c, tac, tr-ish transforms; a
# merge sort on lists because the prelude has none (Str.cmp is the comparator)
#   fpr sol sol/scripts/text/sortuniq.sol sort|uniq|uniqc|rev|upper FILE
strLe a b = Str.cmp a b <= 0.          # native, one pass
rev xs = List.fold (fn acc x -> x :: acc) [] xs.
merge xs ys = case xs of
    [] -> ys
  | x :: xr -> (case ys of
        [] -> xs
      | y :: yr -> (case strLe x y of True -> x :: merge xr ys | False -> y :: merge xs yr)).
msort xs = case List.len xs <= 1 of
    True -> xs
  | False -> h = List.len xs / 2; merge (msort (List.take h xs)) (msort (List.drop h xs)).
dedupe xs = case xs of
    [] -> []
  | x :: [] -> [x]
  | x :: y :: r -> (case x == y of True -> dedupe (y :: r) | False -> x :: dedupe (y :: r)).
runs xs = case xs of
    [] -> []
  | x :: r -> (case runs r of
        [] -> [(x, 1)]
      | (y, n) :: t -> (case x == y of True -> (y, n + 1) :: t | False -> (x, 1) :: (y, n) :: t)).
countLine (w, n) = "{n} {w}".
execute argv = case argv of
    "sort" :: path :: [] -> u = map print (msort (Str.lines (readPath path))); Unit
  | "uniq" :: path :: [] -> u = map print (dedupe (msort (Str.lines (readPath path)))); Unit
  | "uniqc" :: path :: [] -> u = map (fn p -> print (countLine p)) (runs (msort (Str.lines (readPath path)))); Unit
  | "rev" :: path :: [] -> u = map print (rev (Str.lines (readPath path))); Unit
  | "upper" :: path :: [] -> u = map (fn l -> print (Str.upper (Str.trim l))) (Str.lines (readPath path)); Unit
  | _ -> error "usage: sortuniq.sol sort|uniq|uniqc|rev|upper FILE".
> execute (args Unit).
