(* sim: particle simulation (SPEC.md) *)
let np = 20_000
let steps = 2_000

type particle = { mutable px : int; mutable py : int; mutable vx : int; mutable vy : int }

let lcg x = ((x * 1103515245) + 12345) mod 2147483648

let () =
  let x = ref 1 in
  let draw () =
    x := lcg !x;
    !x
  in
  let ps =
    Array.init np (fun _ ->
        let px = draw () mod 1_000_000 in
        let py = draw () mod 1_000_000 in
        let vx = (draw () mod 2001) - 1000 in
        let vy = (draw () mod 2001) - 1000 in
        { px; py; vx; vy })
  in
  for _ = 1 to steps do
    Array.iter
      (fun p ->
        p.vy <- p.vy - 1;
        p.px <- p.px + p.vx;
        if p.px < 0 then begin
          p.px <- -p.px;
          p.vx <- -p.vx
        end
        else if p.px > 1_000_000 then begin
          p.px <- 2_000_000 - p.px;
          p.vx <- -p.vx
        end;
        p.py <- p.py + p.vy;
        if p.py < 0 then begin
          p.py <- -p.py;
          p.vy <- -p.vy
        end
        else if p.py > 1_000_000 then begin
          p.py <- 2_000_000 - p.py;
          p.vy <- -p.vy
        end)
      ps
  done;
  let sx = ref 0 and sy = ref 0 and e = ref 0 in
  Array.iter
    (fun p ->
      sx := !sx + p.px;
      sy := !sy + p.py;
      e := !e + (p.vx * p.vx) + (p.vy * p.vy))
    ps;
  Printf.printf "particles %d steps %d sx %d sy %d energy %d\n" np steps !sx !sy !e
