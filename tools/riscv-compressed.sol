# RV64 C 2.0 integer instructions normalized to base encodings. The caller
# retains the original two-byte length. FP, reserved, EBREAK and Zc refuse.
# Exact remainder avoids a float conversion in older Sol's (%) helper.
remainder a b = a - (a / b) * b.
unsigned n width = remainder (remainder n (2^width) + 2^width) (2^width).
bits n start width = remainder (n / (2^start)) (2^width).
signed value width = value - (if value >= 2^(width - 1) then 2^width else 0).
andBits : (positions : List Int | measure positions) -> Int -> Int -> Int .
andBits positions a b = case positions of
    [] -> 0
  | _ :: rest -> if a == 0 or b == 0 then 0 else remainder a 2 * remainder b 2 + 2 * andBits rest (a / 2) (b / 2).
band a b = andBits (List.range 0 63) (unsigned a 64) (unsigned b 64).
bor a b = a + b - band a b.
# These fields are disjoint, so addition is the same as bitwise OR.
i op rd f3 rs1 imm = unsigned imm 12 * 1048576 + rs1*32768 + f3*4096 + rd*128 + op.
r op rd f3 rs1 rs2 f7 = f7*33554432 + rs2*1048576 + rs1*32768 + f3*4096 + rd*128 + op.
store f3 rs1 rs2 imm = bits imm 5 7 * 33554432 + rs2*1048576 + rs1*32768 + f3*4096 + bits imm 0 5 * 128 + 35.
branch f3 rs1 raw =
  imm = unsigned raw 13;
  bits imm 12 1 * 2147483648 + bits imm 5 6 * 33554432 + rs1*32768 + f3*4096 + bits imm 1 4 * 256 + bits imm 11 1 * 128 + 99.
jump raw =
  imm = unsigned raw 21;
  bits imm 20 1 * 2147483648 + bits imm 1 10 * 2097152 + bits imm 11 1 * 1048576 + bits imm 12 8 * 4096 + 111.
refuse = error "unsupported/reserved compressed instruction".
expand h =
  _ = if h >= 0 and h <= 65535 and remainder h 4 != 3 then Unit else error "not a compressed instruction";
  f = bits h 13 3; rd = bits h 7 5; rs2 = bits h 2 5;
  a = 8 + bits h 7 3; b = 8 + bits h 2 3;
  imm6 = bits h 12 1 * 32 + bits h 2 5;
  case remainder h 4 of
    0 -> quadrant0 h f a b
  | 1 -> quadrant1 h f rd a b imm6
  | 2 -> quadrant2 h f rd rs2 imm6
  | _ -> refuse.
quadrant0 h f a b = case f of
    0 ->
      imm = bits h 7 4 * 64 + bits h 11 2 * 16 + bits h 5 1 * 8 + bits h 6 1 * 4;
      if imm == 0 then refuse else i 19 b 0 2 imm
  | _ ->
    if not (List.has f [2,3,6,7]) then refuse else
      wide = remainder f 2 == 1;
      imm = bits h 10 3 * 8 + (if wide then bits h 5 2 * 64 else bits h 5 1 * 64 + bits h 6 1 * 4);
      size = if wide then 3 else 2;
      if f < 4 then i 3 b size a imm else store size a b imm.
quadrant1 h f rd a b imm6 = case f of
    0 -> i 19 rd 0 rd (signed imm6 6)
  | 1 -> if rd == 0 then refuse else i 27 rd 0 rd (signed imm6 6)
  | 2 -> i 19 rd 0 0 (signed imm6 6)
  | 3 ->
    if rd == 2 then
      imm = bits h 12 1 * 512 + bits h 3 2 * 128 + bits h 5 1 * 64 + bits h 2 1 * 32 + bits h 6 1 * 16;
      if imm == 0 then refuse else i 19 2 0 2 (signed imm 10)
    else if imm6 == 0 then refuse else unsigned (signed imm6 6 * 4096) 32 + rd*128 + 55
  | 4 -> arithmetic h a b imm6
  | 5 ->
    imm = bits h 12 1 * 2048 + bits h 8 1 * 1024 + bits h 9 2 * 256 + bits h 6 1 * 128 + bits h 7 1 * 64 + bits h 2 1 * 32 + bits h 11 1 * 16 + bits h 3 3 * 2;
    jump (signed imm 12)
  | _ ->
    imm = bits h 12 1 * 256 + bits h 5 2 * 64 + bits h 2 1 * 32 + bits h 10 2 * 8 + bits h 3 2 * 2;
    branch (f - 6) a (signed imm 9).
arithmetic h a b imm6 =
  sub = bits h 10 2; kind = bits h 5 2;
  case sub of
    0 -> i 19 a 5 a imm6
  | 1 -> i 19 a 5 a (imm6+1024)
  | 2 -> i 19 a 7 a (signed imm6 6)
  | _ -> if bits h 12 1 == 0 then r 51 a ([0,4,6,7] ! kind) a b (if kind == 0 then 32 else 0)
         else if kind < 2 then r 59 a 0 a b (if kind == 0 then 32 else 0) else refuse.
quadrant2 h f rd rs2 imm6 = case f of
    0 -> i 19 rd 1 rd imm6
  | 2 -> if rd == 0 then refuse else i 3 rd 2 2 (bits h 12 1 * 32 + bits h 2 2 * 64 + bits h 4 3 * 4)
  | 3 -> if rd == 0 then refuse else i 3 rd 3 2 (bits h 12 1 * 32 + bits h 2 3 * 64 + bits h 5 2 * 8)
  | 4 ->
    high = bits h 12 1 == 1;
    if rs2 != 0 then r 51 rd 0 (if high then rd else 0) rs2 0
    else if rd != 0 then i 103 (if high then 1 else 0) 0 rd 0 else refuse
  | 6 -> store 2 2 rs2 (bits h 7 2 * 64 + bits h 9 4 * 4)
  | 7 -> store 3 2 rs2 (bits h 7 3 * 64 + bits h 10 3 * 8)
  | _ -> refuse.
