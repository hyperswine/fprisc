(* Benchmarks Game binary-trees, single-threaded. *)
type tree = Empty | Node of tree * tree

let rec make d =
  if d = 0 then Node (Empty, Empty)
  else let d = d - 1 in Node (make d, make d)

let rec check = function
  | Empty -> 0
  | Node (l, r) -> 1 + check l + check r

let () =
  let n = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 18 in
  let min_depth = 4 in
  let max_depth = max (min_depth + 2) n in
  let stretch = max_depth + 1 in
  Printf.printf "stretch tree of depth %d\t check: %d\n" stretch (check (make stretch));
  let long = make max_depth in
  let d = ref min_depth in
  while !d <= max_depth do
    let iters = 1 lsl (max_depth - !d + min_depth) in
    let sum = ref 0 in
    for _ = 1 to iters do sum := !sum + check (make !d) done;
    Printf.printf "%d\t trees of depth %d\t check: %d\n" iters !d !sum;
    d := !d + 2
  done;
  Printf.printf "long lived tree of depth %d\t check: %d\n" max_depth (check long)
