# Fetch bounded JSON, require a string field, then update a file transactionally.
# fpr sol sol/scripts/http-json-field.sol FIELD URL OUTPUT
H = use "../lib/http".
J = use "../lib/json".
fetch key url target =
  response = case Http.request H.defaultOptions (H.get url) of Ok value -> value | Err e -> error (str e);
  case response of HttpResponse status headers bytes ->
    if or (status < 200) (status >= 300) then error "HTTP response {status}"
    else text = unwrap (Utf8.decode bytes |>? J.parse |>? J.get key |>? J.text);
         writePath target "{text}\n".
main = case args Unit of
  [key,url,target] -> fetch key url target
| _ -> error "usage: http-json-field.sol FIELD URL OUTPUT".
