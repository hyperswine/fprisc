# Hosted SHA-256 file convenience. Bytes/Hex/Base64/Sha256.* are preprovided.
# Exact bytes, no external command, immediate reads follow guarded retry policy.
# std/digest.fpr remains a separate native API, without a Sol parity claim.
sha256FileWith chunk path = case Stream.openRead path chunk of
  Err why -> Err why
| Ok reader ->
    (result,reader2) = Sha256.stream reader;
    closed = Stream.closeRead reader2;
    case closed of Err why -> Err why | Ok u -> mapOk Hex.encode result.
sha256File path = sha256FileWith 65536 path.
