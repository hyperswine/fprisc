# Manual board check (not run by CI; needs the Tang Nano 20K running Spectre-84
# with a qlink console, as QOS installs it): a Sol Serial session at 96774 baud.
#   ./fpr sol tests/boards/qlink-hello.sol
# Passed 2026-11-27: the board answered HELLO with our nonce. See
# docs/2026-11-27-SOL-BYTES-AND-SERIAL.md.
port = "/dev/cu.usbserial-20250303171".
baud = 96774.
nonce = 90.
crcByte crc b = List.fold (fn c i -> if band c 32768 != 0 then band (bxor (BITSHIFTL c 1) 4129) 65535 else band (BITSHIFTL c 1) 65535) (bxor crc (BITSHIFTL b 8)) (List.range 1 8).
crc16 bytes = List.fold crcByte 65535 bytes.
escape b = if b == 126 or b == 125 or b == 3 then [125, bxor b 32] else [b].
frame ch payload =
  body = List.append [ch, 0, 255, List.len payload] payload;
  c = crc16 body;
  all = List.append body [BITSHIFTR c 8, band c 255];
  List.concat [[126], List.concat (List.map escape all), [126]].
bytesOf xs = unwrap (Bytes.fromList xs).
hello = bytesOf (frame 128 [72, 69, 76, 76, 79, nonce]).
bye = bytesOf (frame 128 [66, 89, 69]).
# one HELLO and 300 ms of listening: Some what arrived when it holds HELLO+nonce
try1 p = (w, p1) = Serial.write hello p; (r, p2) = Serial.read 4096 300 p1;
  got = (case r of Ok b -> Bytes.toList b | Err e -> []);
  (got, p2).
holdsHello xs = Bytes.contains (bytesOf [72, 69, 76, 76, 79, nonce]) (bytesOf xs).
drain p = List.fold (fn acc i -> (n, q) = acc; (r, q2) = Serial.read 4096 150 q; (n + (case r of Ok b -> Bytes.len b | Err e -> 0), q2)) (0, p) (List.range 1 5).
>! p0 = unwrap (Serial.open port baud);
  (stale, p1) = drain p0;
  _ = print "opened {port} at {baud}; discarded {stale} stale byte(s)";
  (heard, seen, p2) = List.fold (fn acc i -> (h, s, q) = acc;
      if h then acc else (got, q2) = try1 q; (holdsHello (List.append s got), List.append s got, q2)) (False, [], p1) (List.range 1 10);
  _ = print (if heard then "board answered HELLO with our nonce ({List.len seen} bytes)" else "no HELLO answer in 10 tries ({List.len seen} bytes: {List.take 40 seen})");
  (w1, p3) = Serial.write bye p2;
  (w2, p4) = Serial.write bye p3;
  (w3, p5) = Serial.write bye p4;
  (tail, p6) = drain p5;
  _ = print "sent BYE; {tail} byte(s) after it, then quiet";
  Serial.close p6.
