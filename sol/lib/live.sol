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

# ---- the whole app: events, commands, subscriptions, sessions, durable state ----
#
#   >! Live.serveApp 8080 { title = "Room", init = model, update = update,
#                           view = view, subs = subs, codec = @Msg } None.
#
#     update : Live.Ev msg -> model -> (model, List (Live.Cmd msg))
#     view   : Int -> model -> G.Node        this SESSION's page (sid 0: GET /)
#     subs   : model -> List (Live.Sub msg)  re-read after every update
#     store  : None, or Some { path, save : model -> String,
#                              load : String -> Result model String }:
#              the model is loaded from `path` at start and written there
#              (now) whenever `save` of it changes
#
# std/live's names and meanings, on View.liveApp (sol-vm/Sol/Web.hs). A page
# gets a structural patch (protocol 2: one splice per array) when its client
# asked for one and it is smaller than the snapshot. Not here: std/live's Run
# (a command run in its own actor) and its per-field durable log.

# Msg sid m: from a page (sid 0: a command or a subscription); Joined/Left: a
# page opened or closed; Refused: a frame the codec did not accept
Ev msg = Type (Msg Int msg | Joined Int | Left Int | Refused Int String).
# After ms m: deliver m later; Navigate sid url / Emit sid name detail: to one
# page (sid 0: every page); Quit: stop serving
Cmd msg = Type (After Int msg | Navigate Int String | Emit Int String String | Quit).
Sub msg = Type (Every Int msg).

serveApp port app store =
  start = (case store of None -> app.init | Some st -> loadModel st app.init);
  View.liveApp port start (appPage app) (appStep app store) (appFrame app) (appSubs app).

loadModel st init =
  if not (exists st.path) then init else
    case st.load (readNow st.path) of
      Ok m -> m
    | Err why -> error "live: cannot load {st.path}: {why}".

appPage app sid m = case G.renderStyled (app.view sid m) of
  (s, d) -> strJoin "" ["<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>",
    G.esc app.title, "</title></head><body><div id=\"lv-root\"></div><script>", bootstrap s d,
    "</script><script>", LJ.src Unit, "</script></body></html>"].

# a message as the frame a page would send for it
frameOf codec msg = J.render (J.object [("msg", J.Text (G.wire codec msg)), ("arg", J.Text "")]).

eventOf codec sid text = case J.parse text of
    Err why -> Refused sid "not JSON: {why}"
  | Ok v ->
      if J.field "joined" v != O.None then Joined sid
      else if J.field "left" v != O.None then Left sid
      else (case decodeWire codec (fieldText "msg" v) (fieldText "arg" v) of
          Ok m -> Msg sid m
        | Err why -> Refused sid why).

effectOf codec cmd = case cmd of
    After ms m -> (1, ms, frameOf codec m)
  | Navigate sid url -> (0, sid, J.render (J.object [("nav", J.Text url)]))
  | Emit sid name detail -> (0, sid, J.render (J.object [("emit", J.Text name), ("detail", J.Text detail)]))
  | Quit -> (2, 0, "").

appStep app store sid text m = case app.update (eventOf app.codec sid text) m of
  (m2, cmds) ->
    _ = (case store of
        None -> Unit
      | Some st -> (if st.save m2 != st.save m then writeNow st.path (st.save m2) else Unit));
    (m2, L.map (effectOf app.codec) cmds).

appSubs app m = L.map (fn s -> case s of Every ms msg -> (ms, frameOf app.codec msg)) (app.subs m).

# this session's frame: nothing when its page is unchanged, else a patch
# against what it shows (protocol 2 and up) or a snapshot, whichever is shorter
appFrame app sid proto prev m = case G.renderStyled (app.view sid m) of
  (s, d) -> (case prev of
      (s0, d0) :: _ ->
        if s0 == s and d0 == d then ("", (s, d))
        else
          full = snapshot s d;
          (if proto < 2 then (full, (s, d)) else
             patch = strJoin "" ["\{\"p\":2,\"s\":", splice s0 s, ",\"d\":", splice d0 d, "}"];
             (if strlen patch < strlen full then patch else full, (s, d)))
    | [] -> (snapshot s d, (s, d))).

# one splice turning old into new: [start, removed, [inserted...]]
splice old new =
  prefix = commonCount old new;
  a = L.drop prefix old;
  b = L.drop prefix new;
  suffix = commonCount (L.reverse a) (L.reverse b);
  removed = L.length a - suffix;
  inserted = L.take (L.length b - suffix) b;
  "[{prefix},{removed},{J.render (J.strings inserted)}]".
# how many leading elements two lists share
commonCount a b = case L.fold (fn acc p -> (n, stopped) = acc; (x, y) = p;
    if stopped or x != y then (n, True) else (n + 1, False)) (0, False) (L.zip a b) of (n, _) -> n.
