# fpr sol sol/scripts/checksum.sol FILE
D = use "../lib/digest".
main = case args Unit of
  [path] -> (case D.sha256File path of Ok hex -> print "{hex}  {path}" | Err why -> error why)
| _ -> error "usage: checksum.sol FILE".
