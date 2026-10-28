# Stream a validated response into a staged file, publishing only a 2xx result.
# fpr sol sol/scripts/http-fetch.sol URL DESTINATION [--replace]
H = use "../lib/http".
fetch url target replace = case Http.download H.defaultOptions (H.get url) target replace of
  Ok (HttpInfo status headers count) -> log "HTTP {status}: {count} bytes"
| Err e -> error (str e).
main = case args Unit of
  [url,target] -> fetch url target False
| [url,target,"--replace"] -> fetch url target True
| _ -> error "usage: http-fetch.sol URL DESTINATION [--replace]".
