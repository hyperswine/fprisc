(* Benchmarks Game fasta, single-threaded. *)
let alu =
  "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGG\
   TCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCG\
   GGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGG\
   AGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTC\
   TCAAAAA"

let iub = [| ('a', 0.27); ('c', 0.12); ('g', 0.12); ('t', 0.27);
             ('B', 0.02); ('D', 0.02); ('H', 0.02); ('K', 0.02); ('M', 0.02);
             ('N', 0.02); ('R', 0.02); ('S', 0.02); ('V', 0.02); ('W', 0.02);
             ('Y', 0.02) |]

let homosapiens = [| ('a', 0.3029549426680); ('c', 0.1979883004921);
                     ('g', 0.1975473066391); ('t', 0.3015094502008) |]

let width = 60

let repeat_fasta header src n =
  print_string header; print_char '\n';
  let len = String.length src in
  (* src doubled so a line never wraps inside one blit *)
  let src2 = src ^ String.sub src 0 (min len width) in
  let k = ref 0 and left = ref n in
  while !left > 0 do
    let line = min width !left in
    output_substring stdout src2 !k line;
    output_char stdout '\n';
    k := (!k + line) mod len;
    left := !left - line
  done

let seed = ref 42
let next_random () =
  seed := (!seed * 3877 + 29573) mod 139968;
  float !seed /. 139968.0

let random_fasta header table n =
  print_string header; print_char '\n';
  let m = Array.length table in
  let chars = Array.map fst table in
  let cum = Array.make m 0.0 in
  let acc = ref 0.0 in
  Array.iteri (fun i (_, p) -> acc := !acc +. p; cum.(i) <- !acc) table;
  let line = Bytes.create (width + 1) in
  let left = ref n in
  while !left > 0 do
    let len = min width !left in
    for i = 0 to len - 1 do
      let r = next_random () in
      let j = ref 0 in
      while !j < m - 1 && cum.(!j) <= r do incr j done;
      Bytes.set line i chars.(!j)
    done;
    Bytes.set line len '\n';
    output stdout line 0 (len + 1);
    left := !left - len
  done

let () =
  let n = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 2500000 in
  repeat_fasta ">ONE Homo sapiens alu" alu (2 * n);
  random_fasta ">TWO IUB ambiguity codes" iub (3 * n);
  random_fasta ">THREE Homo sapiens frequency" homosapiens (5 * n)
