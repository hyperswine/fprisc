(* wordfreq: word counts, top 10 (SPEC.md) *)
let is_space c = c = ' ' || c = '\n' || c = '\t' || c = '\r'

let () =
  let path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "data/corpus.txt" in
  let text = In_channel.with_open_bin path In_channel.input_all in
  let counts : (string, int) Hashtbl.t = Hashtbl.create 65536 in
  let total = ref 0 in
  let n = String.length text in
  let i = ref 0 in
  while !i < n do
    while !i < n && is_space text.[!i] do incr i done;
    if !i < n then begin
      let start = !i in
      while !i < n && not (is_space text.[!i]) do incr i done;
      let w = String.sub text start (!i - start) in
      (match Hashtbl.find_opt counts w with
       | Some c -> Hashtbl.replace counts w (c + 1)
       | None -> Hashtbl.add counts w 1);
      incr total
    end
  done;
  let entries = Hashtbl.fold (fun w c acc -> (w, c) :: acc) counts [] in
  let sorted =
    List.sort
      (fun (wa, ca) (wb, cb) -> if ca <> cb then compare cb ca else String.compare wa wb)
      entries
  in
  Printf.printf "distinct %d total %d\n" (List.length sorted) !total;
  List.iteri (fun i (w, c) -> if i < 10 then Printf.printf "%s %d\n" w c) sorted
