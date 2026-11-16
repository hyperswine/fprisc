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

## Not yet here

- `examples/logbook.fpr` (per-session state, server-filled inputs).
- QOS Main on the Pi 4B: exec to "Main Profile ready", and a scripted interaction (belongs in the
  QOS repository).
