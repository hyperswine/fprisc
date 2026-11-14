(* Benchmarks Game k-nucleotide, single-threaded.
   A k-mer over ACGT is packed into an int, 2 bits a base, as the key of a
   Hashtbl; one table is built per length. *)
let code = function 'A' -> 0 | 'C' -> 1 | 'G' -> 2 | 'T' -> 3 | _ -> 0
let base = "ACGT"

let read_three path =
  let ic = open_in_bin path in
  let buf = Buffer.create (1 lsl 16) in
  let rec skip () =
    let l = input_line ic in
    if String.length l >= 6 && String.sub l 0 6 = ">THREE" then () else skip ()
  in
  (try
     skip ();
     let rec go () =
       let l = input_line ic in
       if String.length l > 0 && l.[0] = '>' then ()
       else (Buffer.add_string buf l; go ())
     in
     go ()
   with End_of_file -> ());
  close_in ic;
  String.uppercase_ascii (Buffer.contents buf)

let count_kmers seq k =
  let tbl = Hashtbl.create 4096 in
  let mask = (1 lsl (2 * k)) - 1 in
  let key = ref 0 in
  for i = 0 to k - 2 do key := (!key lsl 2) lor code seq.[i] done;
  for i = k - 1 to String.length seq - 1 do
    key := ((!key lsl 2) lor code seq.[i]) land mask;
    match Hashtbl.find_opt tbl !key with
    | Some c -> incr c
    | None -> Hashtbl.add tbl !key (ref 1)
  done;
  tbl

let decode k key =
  String.init k (fun i -> base.[(key lsr (2 * (k - 1 - i))) land 3])

let encode s =
  let key = ref 0 in
  String.iter (fun c -> key := (!key lsl 2) lor code c) s;
  !key

let frequencies seq k =
  let tbl = count_kmers seq k in
  let total = float (String.length seq - k + 1) in
  let l = Hashtbl.fold (fun key c acc -> (decode k key, !c) :: acc) tbl [] in
  let l = List.sort (fun (k1, c1) (k2, c2) ->
    if c1 <> c2 then compare c2 c1 else compare k1 k2) l in
  List.iter (fun (s, c) ->
    Printf.printf "%s %.3f\n" s (100.0 *. float c /. total)) l;
  print_newline ()

let specific seq s =
  let k = String.length s in
  let tbl = count_kmers seq k in
  let c = match Hashtbl.find_opt tbl (encode s) with Some c -> !c | None -> 0 in
  Printf.printf "%d\t%s\n" c s

let () =
  let path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "data/fasta-1000000.txt" in
  let seq = read_three path in
  frequencies seq 1;
  frequencies seq 2;
  List.iter (specific seq)
    ["GGT"; "GGTA"; "GGTATT"; "GGTATTTTAATT"; "GGTATTTTAATTTATAGT"]
