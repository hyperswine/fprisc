(* Benchmarks Game mandelbrot, single-threaded. *)
let () =
  let n = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 4000 in
  let row_bytes = (n + 7) / 8 in
  let row = Bytes.create row_bytes in
  let fn = float n in
  Printf.printf "P4\n%d %d\n" n n;
  for y = 0 to n - 1 do
    let ci = 2.0 *. float y /. fn -. 1.0 in
    Bytes.fill row 0 row_bytes '\000';
    for x = 0 to n - 1 do
      let cr = 2.0 *. float x /. fn -. 1.5 in
      let zr = ref 0.0 and zi = ref 0.0 and tr = ref 0.0 and ti = ref 0.0 in
      let i = ref 0 in
      while !i < 50 && !tr +. !ti <= 4.0 do
        zi := 2.0 *. !zr *. !zi +. ci;
        zr := !tr -. !ti +. cr;
        tr := !zr *. !zr;
        ti := !zi *. !zi;
        incr i
      done;
      if !tr +. !ti <= 4.0 then begin
        let b = x lsr 3 in
        Bytes.set row b
          (Char.chr (Char.code (Bytes.get row b) lor (0x80 lsr (x land 7))))
      end
    done;
    output_bytes stdout row
  done
