(* Benchmarks Game reverse-complement, single-threaded. *)
let comp = Bytes.init 256 (fun i -> Char.chr i)
let () =
  List.iter (fun (a, b) ->
    Bytes.set comp (Char.code a) b;
    Bytes.set comp (Char.code (Char.lowercase_ascii a)) b)
    [ ('A','T'); ('C','G'); ('G','C'); ('T','A'); ('U','A'); ('M','K');
      ('R','Y'); ('W','W'); ('S','S'); ('Y','R'); ('K','M'); ('V','B');
      ('H','D'); ('D','H'); ('B','V'); ('N','N') ]

let width = 60

let output_seq buf =
  let n = Buffer.length buf in
  let s = Buffer.to_bytes buf in
  let out = Bytes.create (n + n / width + 1) in
  let o = ref 0 in
  let col = ref 0 in
  for i = n - 1 downto 0 do
    Bytes.set out !o (Bytes.get comp (Char.code (Bytes.get s i)));
    incr o; incr col;
    if !col = width then (Bytes.set out !o '\n'; incr o; col := 0)
  done;
  if !col > 0 then (Bytes.set out !o '\n'; incr o);
  output stdout out 0 !o

let () =
  let path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "data/fasta-2500000.txt" in
  let ic = open_in_bin path in
  let buf = Buffer.create (1 lsl 20) in
  (try
     while true do
       let l = input_line ic in
       if String.length l > 0 && l.[0] = '>' then begin
         if Buffer.length buf > 0 then (output_seq buf; Buffer.clear buf);
         print_string l; print_char '\n'
       end else Buffer.add_string buf l
     done
   with End_of_file -> ());
  if Buffer.length buf > 0 then output_seq buf;
  close_in ic
