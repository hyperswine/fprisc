(* Benchmarks Game n-body, single-threaded. *)
let pi = 3.141592653589793
let solar_mass = 4.0 *. pi *. pi
let days_per_year = 365.24

type body = {
  mutable x : float; mutable y : float; mutable z : float;
  mutable vx : float; mutable vy : float; mutable vz : float;
  mass : float;
}

let body x y z vx vy vz m =
  { x; y; z; vx = vx *. days_per_year; vy = vy *. days_per_year;
    vz = vz *. days_per_year; mass = m *. solar_mass }

let bodies = [|
  body 0. 0. 0. 0. 0. 0. 1.;
  body 4.84143144246472090e+00 (-1.16032004402742839e+00) (-1.03622044471123109e-01)
       1.66007664274403694e-03 7.69901118419740425e-03 (-6.90460016972063023e-05)
       9.54791938424326609e-04;
  body 8.34336671824457987e+00 4.12479856412430479e+00 (-4.03523417114321381e-01)
       (-2.76742510726862411e-03) 4.99852801234917238e-03 2.30417297573763929e-05
       2.85885980666130812e-04;
  body 1.28943695621391310e+01 (-1.51111514016986312e+01) (-2.23307578892655734e-01)
       2.96460137564761618e-03 2.37847173959480950e-03 (-2.96589568540237556e-05)
       4.36624404335156298e-05;
  body 1.53796971148509165e+01 (-2.59193146099879641e+01) 1.79258772950371181e-01
       2.68067772490389322e-03 1.62824170038242295e-03 (-9.51592254519715870e-05)
       5.15138902046611451e-05;
|]

let offset_momentum bs =
  let px = ref 0. and py = ref 0. and pz = ref 0. in
  Array.iter (fun b ->
    px := !px +. b.vx *. b.mass;
    py := !py +. b.vy *. b.mass;
    pz := !pz +. b.vz *. b.mass) bs;
  bs.(0).vx <- -. !px /. solar_mass;
  bs.(0).vy <- -. !py /. solar_mass;
  bs.(0).vz <- -. !pz /. solar_mass

let energy bs =
  let e = ref 0. in
  let n = Array.length bs in
  for i = 0 to n - 1 do
    let b = bs.(i) in
    e := !e +. 0.5 *. b.mass *. (b.vx *. b.vx +. b.vy *. b.vy +. b.vz *. b.vz);
    for j = i + 1 to n - 1 do
      let b2 = bs.(j) in
      let dx = b.x -. b2.x and dy = b.y -. b2.y and dz = b.z -. b2.z in
      e := !e -. b.mass *. b2.mass /. sqrt (dx *. dx +. dy *. dy +. dz *. dz)
    done
  done;
  !e

let advance bs dt =
  let n = Array.length bs in
  for i = 0 to n - 1 do
    let b = bs.(i) in
    for j = i + 1 to n - 1 do
      let b2 = bs.(j) in
      let dx = b.x -. b2.x and dy = b.y -. b2.y and dz = b.z -. b2.z in
      let d2 = dx *. dx +. dy *. dy +. dz *. dz in
      let mag = dt /. (d2 *. sqrt d2) in
      b.vx <- b.vx -. dx *. b2.mass *. mag;
      b.vy <- b.vy -. dy *. b2.mass *. mag;
      b.vz <- b.vz -. dz *. b2.mass *. mag;
      b2.vx <- b2.vx +. dx *. b.mass *. mag;
      b2.vy <- b2.vy +. dy *. b.mass *. mag;
      b2.vz <- b2.vz +. dz *. b.mass *. mag
    done
  done;
  for i = 0 to n - 1 do
    let b = bs.(i) in
    b.x <- b.x +. dt *. b.vx;
    b.y <- b.y +. dt *. b.vy;
    b.z <- b.z +. dt *. b.vz
  done

let () =
  let n = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 5000000 in
  offset_momentum bodies;
  Printf.printf "%.9f\n" (energy bodies);
  for _ = 1 to n do advance bodies 0.01 done;
  Printf.printf "%.9f\n" (energy bodies)
