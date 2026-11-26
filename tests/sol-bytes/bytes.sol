# Run by tests/sol-checks/sol-bytes.sol in a scratch directory: Sol's byte
# library (integer codecs, set/patch, CRC-32) and transactional binary files.
h = Bytes.concat [Bytes.putU16le 513, Bytes.putU32be 3735928559, Bytes.putU8 (0 - 1), Bytes.putU64le 1].
> print (Bytes.toList h).
> print (Bytes.u16le 0 h, Bytes.u32be 2 h, Bytes.u8 6 h, Bytes.u64le 7 h, Bytes.u32le 13 h).
> print (Bytes.crc32 (unwrap (Utf8.encode "123456789")), Bytes.crc32 (Bytes.empty Unit)).
> print (Bytes.toList (unwrap (Bytes.set 1 9 (Bytes.putU32le 0))), Bytes.toList (unwrap (Bytes.patch 1 (Bytes.putU16be 258) (Bytes.putU32le 0)))).
> print (isOk (Bytes.set 4 1 (Bytes.putU32le 0)), isOk (Bytes.set 0 256 (Bytes.putU32le 0)), isOk (Bytes.patch 3 (Bytes.putU16le 0) (Bytes.putU32le 0))).
> writeBytes "img.bin" (Bytes.concat [Bytes.putU32le 3735928559, Bytes.putU8 255, Bytes.putU16be 7]).
> b = unwrap (readBytes "img.bin");
  print (Bytes.len b, Bytes.u32le 0 b, Bytes.u8 4 b).
> b = unwrap (readBytes "img.bin");
  u = writeBytes "img.bin" (unwrap (Bytes.patch 4 (Bytes.putU8 1) b));
  print (Bytes.u8 4 (unwrap (readBytes "img.bin")), isOk (Try.readPath "img.bin"), isOk (readBytes "missing.bin")).
