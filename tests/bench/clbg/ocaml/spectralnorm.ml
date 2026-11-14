(* Benchmarks Game spectral-norm, single-threaded. *)
let a i j = 1.0 /. float ((i + j) * (i + j + 1) / 2 + i + 1)

let mul_av n v av =
  for i = 0 to n - 1 do
    let s = ref 0.0 in
    for j = 0 to n - 1 do s := !s +. a i j *. v.(j) done;
    av.(i) <- !s
  done

let mul_atv n v atv =
  for i = 0 to n - 1 do
    let s = ref 0.0 in
    for j = 0 to n - 1 do s := !s +. a j i *. v.(j) done;
    atv.(i) <- !s
  done

let mul_atav n v atav tmp = mul_av n v tmp; mul_atv n tmp atav

let () =
  let n = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 2000 in
  let u = Array.make n 1.0 and v = Array.make n 0.0 and tmp = Array.make n 0.0 in
  for _ = 1 to 10 do mul_atav n u v tmp; mul_atav n v u tmp done;
  let vbv = ref 0.0 and vv = ref 0.0 in
  for i = 0 to n - 1 do
    vbv := !vbv +. u.(i) *. v.(i);
    vv := !vv +. v.(i) *. v.(i)
  done;
  Printf.printf "%.9f\n" (sqrt (!vbv /. !vv))
