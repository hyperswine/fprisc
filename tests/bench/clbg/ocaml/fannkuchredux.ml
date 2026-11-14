(* Benchmarks Game fannkuch-redux, single-threaded. *)
let () =
  let n = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 10 in
  let perm1 = Array.init n (fun i -> i) in
  let perm = Array.make n 0 in
  let count = Array.make n 0 in
  let max_flips = ref 0 and checksum = ref 0 and perm_index = ref 0 in
  let r = ref n in
  try
    while true do
      while !r <> 1 do count.(!r - 1) <- !r; decr r done;
      Array.blit perm1 0 perm 0 n;
      let flips = ref 0 in
      let k = ref perm.(0) in
      while !k <> 0 do
        let i = ref 0 and j = ref !k in
        while !i < !j do
          let t = perm.(!i) in
          perm.(!i) <- perm.(!j); perm.(!j) <- t;
          incr i; decr j
        done;
        incr flips;
        k := perm.(0)
      done;
      if !flips > !max_flips then max_flips := !flips;
      checksum := if !perm_index land 1 = 0 then !checksum + !flips else !checksum - !flips;
      let continue = ref true in
      while !continue do
        if !r = n then begin
          Printf.printf "%d\nPfannkuchen(%d) = %d\n" !checksum n !max_flips;
          raise Exit
        end;
        let p0 = perm1.(0) in
        for i = 0 to !r - 1 do perm1.(i) <- perm1.(i + 1) done;
        perm1.(!r) <- p0;
        count.(!r) <- count.(!r) - 1;
        if count.(!r) > 0 then continue := false else incr r
      done;
      incr perm_index
    done
  with Exit -> ()
