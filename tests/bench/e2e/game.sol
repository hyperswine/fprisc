# Run from tests/bench/e2e: sol game.sol dungeon|terra-ii GAME_CHECKOUT [SECONDS] < /dev/null
# Builds the game with the installed QOS Portable SDK (`qos build`), plays it from a
# key script for SECONDS (default 120) in its window, and prints what it cost:
# gamedrive's JSON line (frames, frames a second, the host's time in a frame,
# resident memory at the start, peak and end) and the process totals from
# /usr/bin/time. SPEC.md says what the scripts are.
unsafe program.
B = use "../../../sol/lib/build".
# evdev codes: 28 Enter, 103 up, 108 down, 105 left, 106 right, 57 Space, 16 Q, 1 Escape, 19 R
script name =
  if name == "dungeon" then ["16","28","106","106","103","105","105","108","57","106","103","103","57","108","19","28"]
  else if name == "terra-ii" then ["16","28","106","28","106","28","103","28","105","28","57","108","28","57"]
  else error "expected dungeon or terra-ii".
# Terra II queues keys and takes them between animations: a faster script only builds a backlog
pace name = if name == "terra-ii" then "1000" else "250".
# $0 work directory, $1 game checkout, $2 seconds, $3 time flag, $4 ms between keys, then QUIT FIRST CODES...
play = "w=$0; game=$1; secs=$2; flag=$3; pace=$4; shift 4; cd \"$w\" || exit 1; rm -rf run; mkdir run; mkfifo run/keys; ( exec 3<> run/keys; FPR_EVDEV=\"$w/run/keys\" FPR_GFX_PROFILE=1 /usr/bin/time \"$flag\" qos run \"$game\" --disk \"$w/run/disk\" --trace > run/game.log 2> run/time.log ) & n=0; until grep -q 'desktopgl\\] GLFW' run/game.log 2>/dev/null; do n=$((n+1)); if [ $n -gt 150 ]; then echo 'the game window did not open'; cat run/game.log run/time.log; exit 1; fi; perl -e 'select(undef,undef,undef,0.1)'; done; sleep 1; ( while parent=$(pgrep -f \"$w/run/disk\" | head -1); [ -n \"$parent\" ]; do host=$(pgrep -P \"$parent\" | head -1); if [ -n \"$host\" ]; then ps -o rss= -p \"$host\" >> run/rss.txt 2>/dev/null; fi; sleep 1; done ) & ./gamedrive feed run/keys \"$pace\" \"$secs\" \"$@\" || exit 1; n=0; while pgrep -f \"$w/run/disk\" > /dev/null; do n=$((n+1)); if [ $n -gt 100 ]; then pkill -f \"$w/run/disk\"; echo 'the game did not quit'; exit 1; fi; sleep 0.2; done; wait; ./gamedrive summary run/game.log run/rss.txt || exit 1; grep -E ' real |maximum resident|peak memory footprint|instructions retired|Elapsed|Maximum resident' run/time.log".
> case args Unit of
    name :: checkout :: rest ->
      seconds = (case rest of [s] -> s | [] -> "120" | _ -> error "usage: sol game.sol dungeon|terra-ii GAME_CHECKOUT [SECONDS]");
      keys = script name;
      here = B.query ["pwd","-P"];
      work = "{here}/bin";
      game = B.query ["/bin/sh","-c","cd \"$0\" && pwd -P",checkout];
      flag = (if B.query ["uname","-s"] == "Darwin" then "-l" else "-v");
      _ = B.command ["mkdir","-p",work];
      _ = B.command ["cc","-O2","-Wall","-Wextra","-o","{work}/gamedrive","gamedrive.c"];
      _ = B.inDirectory game [] ["qos","build"];
      _ = print "== {name}, {seconds} s of scripted play";
      B.command (List.append ["sh","-c",play,work,game,seconds,flag,pace name] keys)
  | _ -> error "usage: sol game.sol dungeon|terra-ii GAME_CHECKOUT [SECONDS]".
