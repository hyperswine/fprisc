# Hosted libcurl in an owned, isolated worker. No curl executable or shell.
# HttpOptions: deadline ms, response body bytes, aggregate header bytes,
# redirect policy, CA file (empty uses system roots), explicit DNS routes.
defaultOptions = HttpOptions 30000 1048576 65536 NoRedirect "" [].
get url = HttpRequest "GET" url [] (Bytes.empty Unit).
head url = HttpRequest "HEAD" url [] (Bytes.empty Unit).
withDeadline ms options = case options of HttpOptions _ body headers redirects ca routes ->
  HttpOptions ms body headers redirects ca routes.
withBodyLimit bytes options = case options of HttpOptions ms _ headers redirects ca routes ->
  HttpOptions ms bytes headers redirects ca routes.
withHeaderLimit bytes options = case options of HttpOptions ms body _ redirects ca routes ->
  HttpOptions ms body bytes redirects ca routes.
withRedirects policy options = case options of HttpOptions ms body headers _ ca routes ->
  HttpOptions ms body headers policy ca routes.
withCA path options = case options of HttpOptions ms body headers redirects _ routes ->
  HttpOptions ms body headers redirects path routes.
withRoute host port address options = case options of HttpOptions ms body headers redirects ca routes ->
  remaining = List.filter (fn route -> case route of HttpRoute name number target ->
    not (and (Str.lower name == Str.lower host) (number == port))) routes;
  HttpOptions ms body headers redirects ca (HttpRoute host port address :: remaining).
header name pairs = List.map (fn pair -> (key,value) = pair; value)
  (List.filter (fn pair -> (key,value) = pair; key == Str.lower name) pairs).
