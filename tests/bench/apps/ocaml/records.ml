(* records: three-key sort and group-by (SPEC.md) *)
let n = 1_000_000
let m = 1_000_000_007

type record = { id : int; dept : int; age : int; salary : int }

let lcg x = ((x * 1103515245) + 12345) mod 2147483648

let () =
  let x = ref 42 in
  let rs =
    Array.init n (fun id ->
        x := lcg !x;
        let x = !x in
        { id; dept = x mod 100; age = 18 + (x / 100 mod 63); salary = 30000 + (x / 6300 mod 90000) })
  in
  Array.sort
    (fun a b ->
      if a.dept <> b.dept then compare a.dept b.dept
      else if a.age <> b.age then compare b.age a.age
      else compare a.id b.id)
    rs;
  let o = Array.fold_left (fun o r -> ((o * 31) + r.id) mod m) 0 rs in
  Printf.printf "records %d order %d\n" n o;
  let i = ref 0 in
  while !i < n do
    let dept = rs.(!i).dept and first = rs.(!i).id in
    let count = ref 0 and sum = ref 0 in
    while !i < n && rs.(!i).dept = dept do
      incr count;
      sum := !sum + rs.(!i).salary;
      incr i
    done;
    Printf.printf "%d %d %d %d\n" dept !count !sum first
  done
