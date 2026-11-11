(* treemap: ordered map inserts and lookups (SPEC.md) *)
module IntMap = Map.Make (Int)

let m = 1_000_000_007
let lcg x = ((x * 1103515245) + 12345) mod 2147483648

let () =
  let x = ref 7 in
  let map = ref IntMap.empty in
  for i = 0 to 499_999 do
    x := lcg !x;
    map := IntMap.add (!x mod 1_000_000) i !map
  done;
  let hits = ref 0 and sum = ref 0 in
  for _ = 0 to 499_999 do
    x := lcg !x;
    match IntMap.find_opt (!x mod 1_000_000) !map with
    | Some v ->
        incr hits;
        sum := !sum + v
    | None -> ()
  done;
  let k = IntMap.fold (fun key _ k -> ((k * 31) + key) mod m) !map 0 in
  Printf.printf "size %d hits %d sum %d keyhash %d\n" (IntMap.cardinal !map) !hits !sum k
