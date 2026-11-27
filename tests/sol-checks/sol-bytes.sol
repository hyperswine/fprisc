# Sol bytes: fixed-width integer codecs, Bytes.set/patch, CRC-32 (the
# standard check value of "123456789" is 0xCBF43926), and transactional
# readBytes/writeBytes, including a statement that panics after writeBytes
# leaving no file. Runs tests/sol-bytes/bytes.sol in a scratch directory.
H = use "helpers".
must what ok detail = if ok then Unit else error "sol-bytes: {what}\n{detail}".
inDir root dir file = unwrap (Proc.runNow (ProcessSpec ["{root}/fpr","sol",file] dir [("FPR_HOME",root)] "" 120000)).
main : unsafe Unit -> Unit.
main u = root = H.root Unit; work = tempDir "fpr-sol-bytes";
  ProcessResult c o e = inDir root work "{root}/tests/sol-bytes/bytes.sol";
  want = readPath "{root}/tests/sol-bytes/bytes.expected";
  _ = must "bytes.sol output" (c == 0 and o == want) "--- want\n{want}--- got\n{o}{e}";
  ProcessResult xc xo xe = H.call ["xxd","-p","{work}/img.bin"] [] 5000;
  _ = must "img.bin bytes on disk" (Str.trim xo == "efbeadde010007") xo;
  _ = H.write "{work}/abort.sol" (unwrap (Utf8.encode "> writeBytes \"x.bin\" (Bytes.putU8 7); 1 / (Str.len \"\").\n"));
  ProcessResult ac ao ae = inDir root work "{work}/abort.sol";
  ProcessResult tc _ _ = H.call ["test","-e","{work}/x.bin"] [] 5000;
  _ = must "a panicking statement's writeBytes never lands" (ac != 0 and tc != 0) ae;
  # serial ports are immediate: refused in a `>` statement, an Err for a missing port in `>!`
  _ = H.write "{work}/serial.sol" (unwrap (Utf8.encode "> print (isOk (Serial.open \"/dev/no-such-port\" 115200)).\n"));
  ProcessResult sc so se = inDir root work "{work}/serial.sol";
  _ = must "Serial in a transactional statement is refused" (sc != 0 and Str.contains "reaches immediate operation(s) Serial.open" se) se;
  _ = H.write "{work}/serial2.sol" (unwrap (Utf8.encode ">! r = Serial.open \"/dev/no-such-port\" 115200; print (case r of Ok p -> _ = Serial.close p; \"opened\" | Err e -> \"err\").\n"));
  ProcessResult tc2 to2 te2 = inDir root work "{work}/serial2.sol";
  _ = must "a missing serial port is an Err" (tc2 == 0 and to2 == "err\n") "{to2}{te2}";
  # child processes: the same operations on pipes (QEMU's console in board-host.sol)
  ProcessResult cc co ce = inDir root work "{root}/tests/sol-checks/child/child.sol";
  _ = must "Child write/expect/read/wait, timeout, end of output, missing program"
    (cc == 0 and co == "(got:hello\n, second\n)\nOk 7\nErr Child.wait: still running after 300 ms; terminated\nErr Child.read: the process closed its output\nOk 0\nChild.open no-such-program-xyz: does not exist (No such file or directory)\n") "{co}{ce}";
  _ = H.write "{work}/child2.sol" (unwrap (Utf8.encode "> print (isOk (Child.open [\"true\"])).\n"));
  ProcessResult c2 o2 e2 = inDir root work "{work}/child2.sol";
  _ = must "Child in a transactional statement is refused" (c2 != 0 and Str.contains "reaches immediate operation(s) Child.open" e2) e2;
  print "sol-bytes: integer codecs, set/patch, CRC-32, transactional binary files, serial and child refusals, child processes PASS".
>! main Unit.
