# A std/ui page served from Sol (sol/lib/live.sol, View.live): the example
# counter runs as a Child; GET / is std/live's shell with the std/livejs client;
# over the websocket, std/live's frames step the model and every step pushes a
# snapshot; a frame the codec refuses leaves the model as it was. The
# websocket side needs Node's built-in WebSocket (Node 22); without it the
# check says so and passes. docs/2026-11-27-SOL-VIEW-DRIVER.md.
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
  print "sol-live: std/ui page from Sol, std/live shell and client, frames step the model, refused frames ignored PASS".
>! main Unit.
