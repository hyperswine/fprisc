# End-to-end workloads: specification

Whole applications driven the way their users drive them, measured from outside. The other suites
(`../clbg`, `../apps`) are single-file batch programs; these are the programs FP-RISC is for.

## pos1: cashiers making sales

Subject: `examples/pos1.fpr` as built by `fpr build`, on a fresh shop log with six products (stock
large enough never to run out), one cashier and 10% tax.

Driver: `posdrive.c`. It speaks the page's own wire (std/livejs): a websocket to `/ws?lv=3` and
text frames `{"msg":..,"arg":..}`. One session is one browser tab:

1. sign in (`Login`);
2. for each sale: mirror a cart (`ClientState`, quantities 0 to 3 of each product from the suite's
   LCG, never empty), then pay: `Card`, or `Cash` with 500.00 on every third sale;
3. before every eighth sale, mirror the Receipts tab first, as a cashier looking at the receipts.

All sessions run at once, each in a closed loop: the next sale is sent when the previous one is
acknowledged. The acknowledgement is the frame the server sends to that session alone when its cart
empties (`{"emit":"locals",...}`), so a broadcast caused by another cashier is not mistaken for it.
The driver reads and counts every frame. There is no think time: this is the server's ceiling, not
a model of a shop's pace.

Measured:

- from the driver: sales a second, the latency of a sale (mirror sent to acknowledgement received;
  p50, p90, p99, max), frames and bytes received;
- from `/usr/bin/time` around the server: wall and CPU time, peak memory, instructions where the
  platform reports them.

Correctness: every sale must be acknowledged, and the shop log must hold exactly
SESSIONS x SALES `sale` lines afterwards.

Run: `sol run.sol` from this directory (`FPR` selects the compiler, `PORT` the port). Default runs:
one cashier making 25, 50 and 200 sales, and eight cashiers making 25 each.

## Games: Dungeon and Terra II

Subjects: the two games as their own repositories build them (`qos build` with the installed QOS
Portable SDK), run as `qos run` runs them: a 3D window, the app in the SDK's host.

Driver: `gamedrive.c feed` writes evdev key events into the fifo the game reads as `FPR_EVDEV`
(the same door the games' own checks use). One key starts a game; then a fixed cycle of keys plays
it for the given time; then the quit key, repeated until the game has gone.

- Dungeon: move and turn around the first room, interact, and restart every sixteen keys so a
  death cannot end the session; one key every 250 ms.
- Terra II: move the cursor, pick and confirm, end the turn; one key a second. The game queues keys
  and takes them between animations, so a faster script only builds a backlog (the quit key then
  waits behind it).

Measured:

- frames the app drew (its own count, printed when it ends) and frames a second;
- the host's time in a frame and in its draw, from `FPR_GFX_PROFILE=1` (the console echo is
  rate-limited, so about a quarter of the frames have a line: a sample);
- the host's resident memory once a second: first, peak, last;
- `/usr/bin/time` on the whole run: CPU time, peak memory, instructions.

There is no correctness check beyond a clean quit: the game's own repository tests its rules.

Run: `sol game.sol dungeon|terra-ii GAME_CHECKOUT [SECONDS]` from this directory (default 120 s).
The window opens on the desktop for the length of the run.

## Not yet here

- `examples/logbook.fpr` (per-session state, server-filled inputs).
- QOS Main on the Pi 4B: exec to "Main Profile ready", and a scripted interaction (belongs in the
  QOS repository). The games have not been run on the Pi either.
