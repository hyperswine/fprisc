(* csv: parse and aggregate (SPEC.md) *)
type agg = { mutable count : int; mutable sum_a : int; mutable max_b : int }

let () =
  let path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "data/sales.csv" in
  let text = In_channel.with_open_bin path In_channel.input_all in
  let tbl : (string, agg) Hashtbl.t = Hashtbl.create 1024 in
  let lines = ref 0 in
  List.iter
    (fun line ->
      if line <> "" then
        match String.split_on_char ',' line with
        | [ key; a; b ] ->
            let a = int_of_string a and b = int_of_string b in
            let e =
              match Hashtbl.find_opt tbl key with
              | Some e -> e
              | None ->
                  let e = { count = 0; sum_a = 0; max_b = 0 } in
                  Hashtbl.add tbl key e;
                  e
            in
            e.count <- e.count + 1;
            e.sum_a <- e.sum_a + a;
            if b > e.max_b then e.max_b <- b;
            incr lines
        | _ -> failwith ("bad line: " ^ line))
    (String.split_on_char '\n' text);
  let entries = Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl [] in
  let sorted =
    List.sort
      (fun (ka, a) (kb, b) ->
        if a.sum_a <> b.sum_a then compare b.sum_a a.sum_a else String.compare ka kb)
      entries
  in
  Printf.printf "keys %d lines %d\n" (List.length sorted) !lines;
  List.iteri
    (fun i (k, e) -> if i < 10 then Printf.printf "%s %d %d %d\n" k e.count e.sum_a e.max_b)
    sorted
