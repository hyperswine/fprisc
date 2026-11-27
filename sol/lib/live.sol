# sol/lib/live.sol -- a std/view page served from Sol, on std/live's wire.
#
#   L = use "../lib/live".          # or the path to sol/lib/live from the script
#   >! L.serve 8080 { title = "Counter", init = { count = 0 },
#                     update = update, view = view, codec = @Msg }.
#
#     init    : model                     the one shared model
#     update  : msg -> model -> model     one message, in order (a pure function)
#     view    : model -> G.Node           the page, from std/ui or std/view
#     codec   : @Msg                      the app's message type, on the wire
#
# The same app shape, view types and message codec as std/live
# (docs/2026-11-27-SOL-STD-LIBRARIES.md, item 5 of the Sol review): the page
# is std/live's shell with std/view's statics and dynamics and the std/livejs
# client, and a page's frames are std/live's ({"msg": wire, "arg": text},
# decoded by the codec; anything it refuses never reaches update). The
# driver, View.live (sol-vm/Sol/Web.hs), owns the socket: every frame is one
# step under one lock, and every open page gets the new snapshot (std/live's
# protocol 0). Not here yet: commands, subscriptions, durable fields and
# per-session views, which std/live has.
G = use "std/view".
J = use "std/json".
JS = use "std/javascript".
LJ = use "std/livejs".
O = use "std/option".
L = use "std/list".

serve port app = View.live port app.init (page app) (step app) (frame app).

# this model's page as (statics, dynamics)
rendered app m = G.renderStyled (app.view m).

# the snapshot every std/live client takes
frame app m = case rendered app m of (s, d) -> snapshot s d.
snapshot s d = strJoin "" ["\{\"s\":", J.render (J.strings s), ",\"d\":", J.render (J.strings d), "}"].

# the whole document for GET /: std/live's shell
page app m = case rendered app m of
  (s, d) -> strJoin "" ["<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>",
    G.esc app.title, "</title></head><body><div id=\"lv-root\"></div><script>", bootstrap s d,
    "</script><script>", LJ.src Unit, "</script></body></html>"].
bootstrap s d = JS.program [JS.Assign (JS.Field (JS.Name "window") "__LV__")
  (JS.Object [("s", JS.Array (L.map JS.Text s)), ("d", JS.Array (L.map JS.Text d))])].

# one frame from a page: the model after its message, or as it was
step app text m = case message app.codec text of
    Ok msg -> app.update msg m
  | Err why -> m.

# a frame as a message of the app: std/live's eventOf and decodeWire
message codec text = case J.parse text of
    Err why -> Err "not JSON: {why}"
  | Ok v -> decodeWire codec (fieldText "msg" v) (fieldText "arg" v).
fieldText key v = O.withDefault "" (O.andThen J.asString (J.field key v)).

# "=" and the JSON of the message is complete; "+" takes the event's argument
# as its final field (an upload); "*" takes the event's argument, a JSON array
# of the page's values, as its final fields (View.sendWith)
decodeWire codec wire arg =
  kind = substr wire 0 1;
  if kind != "=" and kind != "+" and kind != "*" then Err "not a typed message: {wire}" else
    case J.parse (substr wire 1 (strlen wire)) of
      Err why -> Err why
    | Ok v ->
        if kind == "=" then codec.dec (J.toWire v)
        else if kind == "+" then codec.dec (withArgs [WStr arg] (J.toWire v))
        else (case J.parse arg of
            Ok (J.Sequence vs) -> codec.dec (withArgs (L.map J.toWire vs) (J.toWire v))
          | Ok _ -> Err "the page's values: expected an array"
          | Err why -> Err "the page's values: {why}").
withArgs args w = case w of
    WList xs -> WList (L.append xs args)
  | WCon n as -> WCon n (L.append as args)
  | other -> other.
