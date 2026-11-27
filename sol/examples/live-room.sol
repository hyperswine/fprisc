# A std/live app in Sol (sol/lib/live.sol's serveApp): per-session pages,
# joined/left events, a delayed message, a ticker subscription and a durable
# count.
#   ./fpr sol sol/examples/live-room.sol [PORT] [STORE]     then open http://localhost:PORT
Live = use "../lib/live".
UI = use "std/ui".
G = use "std/view".

Msg = Type (Bump Int | Later | Tick | Toggle | Stop).
codec = @Msg.

update ev m = case ev of
    Live.Joined sid -> ({ m | online = m.online + 1 }, [])
  | Live.Left sid -> ({ m | online = m.online - 1 }, [])
  | Live.Refused sid why -> (m, [])
  | Live.Msg sid msg -> (case msg of
        Bump n -> ({ m | count = m.count + n }, [])
        # a hundred, half a second later
      | Later -> (m, [Live.After 500 (Bump 100)])
      | Tick -> ({ m | ticks = m.ticks + 1 }, [])
      | Toggle -> ({ m | ticking = not m.ticking }, [])
      | Stop -> (m, [Live.Quit])).

subs m = if m.ticking then [Live.Every 200 Tick] else [].

view sid m = UI.page UI.day { UI.stack | gap = 3, pad = 4 } [
  UI.label { UI.txt | size = UI.Title } "Count {m.count}",
  UI.text UI.txt "you are session {sid}; {m.online} online; {m.ticks} ticks",
  UI.hstack { UI.stack | gap = 2 } [
    UI.button UI.btn [G.send codec (Bump 1)] "+1",
    UI.button UI.btn [G.send codec Later] "+100 later",
    UI.button UI.btn [G.send codec Toggle] (if m.ticking then "stop ticking" else "tick"),
    UI.button { UI.btn | kind = UI.Quiet } [G.send codec Stop] "quit" ] ].

argAt i fallback = case List.drop i (args Unit) of a :: _ -> a | [] -> fallback.

fresh = { count = 0, online = 0, ticks = 0, ticking = False }.
# only the count is durable: it is saved as its digits and comes back into a fresh model
store path = Some { path = path, save = fn m -> "{m.count}",
                    load = fn t -> case Try.parseInt (Str.trim t) of Ok n -> Ok { fresh | count = n } | Err e -> Err (str e) }.

>! Live.serveApp (parseInt (argAt 0 "8080"))
     { title = "Room", init = fresh,
       update = update, view = view, subs = subs, codec = codec }
     (case argAt 1 "" of "" -> None | path -> store path).
