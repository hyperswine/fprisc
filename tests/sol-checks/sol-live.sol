# A std/ui page served from Sol (sol/lib/live.sol, View.live): the example
# counter runs as a Child; GET / is std/live's shell with the std/livejs client;
# over the websocket, std/live's frames step the model and every step pushes a
# snapshot; a frame the codec refuses leaves the model as it was. The
# websocket side needs Node's built-in WebSocket (Node 22); without it the
# check says so and passes. docs/2026-11-27-SOL-VIEW-DRIVER.md and
# docs/2026-11-27-SOL-LIVE-APP.md (live-room.sol, room.mjs).
H = use "helpers".
fetch port = H.call ["curl","-s","--max-time","2","http://127.0.0.1:{port}/"] [] 5000.
waitUp : unsafe Int -> Int -> String .
waitUp port tries = ProcessResult code out _ = fetch port;
  if code == 0 and Str.contains "lv-root" out then out
  else if tries == 0 then error "sol-live: the server did not answer"
  else _ = Sys.sleepUs 200000; waitUp port (tries - 1).
main : unsafe Unit -> Unit.
main u = root = H.root Unit;
  port = 8000 + (Sys.uptimeMs Unit % 1000) + 700;
  child = unwrap (Child.open ["{root}/fpr","sol","{root}/sol/examples/live-counter.sol","{port}"]);
  pageText = waitUp port 50;
  # no node at all (the CI container) is the same as a Node without WebSocket
  hasWs = case Proc.runNow (ProcessSpec ["node","-e","process.stdout.write(typeof WebSocket)"] "" [] "" 10000) of
      Ok (ProcessResult nc no _) -> nc == 0 and no == "function"
    | Err _ -> False;
  ProcessResult wc wo we = (if hasWs
    then H.call ["node","{root}/tests/sol-checks/live/client.mjs","{port}"] [] 30000
    else ProcessResult 0 "skipped" "");
  _ = Child.kill child;
  _ = (if Str.contains "Count 0" pageText and Str.contains "__LV__" pageText and Str.contains "WebSocket" pageText then Unit
       else error "sol-live: GET / is not the std/live page");
  _ = (if wo == "skipped" then print "sol-live: no Node WebSocket here; the websocket half was skipped"
       else if wc == 0 and Str.trim wo == "0 5 5 15 0" then Unit
       else error "sol-live: snapshots {Str.trim wo}, want 0 5 5 15 0\n{we}");
  # the whole app shape: sessions, joined/left, After, patches, Quit and a durable count
  _ = (if wo == "skipped" then Unit else
    store = "{tempDir "fpr-live-room"}/count";
    port2 = port + 1;
    room = unwrap (Child.open ["{root}/fpr","sol","{root}/sol/examples/live-room.sol","{port2}",store]);
    _ = waitUp port2 50;
    ProcessResult rc ro re = H.call ["node","{root}/tests/sol-checks/live/room.mjs","{port2}"] [] 60000;
    status = Child.wait 5000 room;
    _ = (if rc == 0 and Str.trim ro == "a joined, a sees 2 online, count 5 on b, count 105 later, ticker ticks, ticker stopped, a sees 1 online, patches used" then Unit
         else error "sol-live room: {Str.trim ro}\n{re}");
    _ = (if status == Ok 0 then Unit else error "sol-live room: the server did not stop on Quit: {status}");
    (if Str.trim (readNow store) == "105" then Unit else error "sol-live room: the durable count is {readNow store}, want 105"));
  print "sol-live: std/ui pages from Sol on std/live's wire: a counter, and an app with sessions, joined/left, After, a subscription, patches, Quit and a durable count PASS".
>! main Unit.
