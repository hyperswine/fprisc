(* format: string building (SPEC.md) *)
let n = 1_000_000
let m = 1_000_000_007

let () =
  let status = [| "open"; "paid"; "shipped" |] in
  let lines =
    Array.init n (fun i ->
        let c = i * 7919 mod 10007 in
        let q = (i mod 17) + 1 in
        let cents = i * 104729 mod 1_000_000 in
        Printf.sprintf "order %d cust c%d qty %d total %d.%02d status %s" i c q (cents / 100)
          (cents mod 100) status.(i mod 3))
  in
  let bytes = ref 0 and h = ref 0 in
  Array.iter
    (fun l ->
      let len = String.length l in
      bytes := !bytes + len;
      h := ((!h * 31) + len) mod m)
    lines;
  Printf.printf "lines %d bytes %d hash %d\n" n !bytes !h;
  print_endline lines.(0);
  print_endline lines.(499_999);
  print_endline lines.(999_999)
