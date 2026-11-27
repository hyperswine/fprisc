# A std/ui page served from Sol (sol/lib/live.sol): the same view types and
# message codec a native std/live app uses.
#   ./fpr sol sol/examples/live-counter.sol [PORT]      then open http://localhost:PORT
Live = use "../lib/live".
UI = use "std/ui".
G = use "std/view".

Msg = Type (Bump Int | Reset).
codec = @Msg.

update msg m = case msg of
    Bump n -> { m | count = m.count + n }
  | Reset -> { m | count = 0 }.

view m = UI.page UI.day { UI.stack | gap = 4, pad = 4 } [
  UI.label { UI.txt | size = UI.Title } "Count {m.count}",
  UI.hstack { UI.stack | gap = 2 } [
    UI.button UI.btn [G.send codec (Bump 1)] "+1",
    UI.button UI.btn [G.send codec (Bump 10)] "+10",
    UI.button { UI.btn | kind = UI.Quiet } [G.send codec Reset] "reset" ] ].

port u = case args Unit of p :: _ -> parseInt p | [] -> 8080.

>! Live.serve (port Unit) { title = "Counter", init = { count = 0 }, update = update, view = view, codec = codec }.
