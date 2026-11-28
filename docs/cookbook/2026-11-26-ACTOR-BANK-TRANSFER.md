# Transfer money between accounts with actors

The customer is the `main` actor. It spawns a bank actor that starts
with 100 units in checking and 20 in savings. Every transfer sends a
request to the bank, which decides whether to approve it and sends a
receipt back to the customer.

Save this block as `bank-transfer.fpr`.

```fpr
profile base.
Actor = use "std/actor".

Request = Type (Transfer Int | Close).
Receipt = Type (Approved Int Int | Declined String | Closed).

bank : unsafe Int -> Int -> Int -> Unit .
bank me checking savings =
  message = receive me;
  (from, id, borrowed) = message;
  request = keep borrowed;
  _ = drop message;
  case request of
    Close -> answer (from, id) Closed
  | Transfer amount ->
      if amount <= 0 then
        _ = answer (from, id) (Declined "amount must be positive");
        bank me checking savings
      else if amount > checking then
        _ = answer (from, id) (Declined "insufficient funds");
        bank me checking savings
      else
        debit = checking - amount;
        credit = savings + amount;
        _ = answer (from, id) (Approved debit credit);
        bank me debit credit.

answer : (Int, Int) -> Receipt -> Unit .
answer address receipt = case Actor.reply address receipt of
    Ok u -> u
  | Err why -> error "could not send receipt: {why}".

transfer : Int -> Int -> Int -> Unit .
transfer me service amount = case Actor.call me service (Transfer amount) of
    Ok (Approved checking savings) ->
      print "Transfer {amount} approved. Checking={checking}, savings={savings}."
  | Ok (Declined why) -> print "Transfer {amount} declined. {why}."
  | Ok Closed -> error "unexpected close receipt"
  | Err why -> error "transfer call failed: {why}".

main : unsafe Unit .
main =
  me = myself 0;
  service = spawn (fn self -> bank self 100 20);
  _ = transfer me service 30;
  _ = transfer me service 80;
  _ = transfer me service 10;
  case Actor.call me service Close of
    Ok Closed -> print "Bank closed."
  | Ok _ -> error "unexpected close receipt"
  | Err why -> error "close call failed: {why}".
```

From the FP-RISC checkout, run the file with the Base profile on the
hosted target.

```sh
./fpr run bank-transfer.fpr
```

```text
Transfer 30 approved. Checking=70, savings=50.
Transfer 80 declined. insufficient funds.
Transfer 10 approved. Checking=60, savings=60.
Bank closed.
```

- `spawn` returns the bank's actor ID. The bank receives its own ID
  as `self` and waits at `receive me`.
- `Actor.call` sends a tuple containing the caller's ID, a request ID,
  and the request. `Actor.reply` uses the first two fields to send a
  matching response. The bank uses `keep` to retain the request before
  releasing the received message with `drop`.
- The bank owns both balances and handles one request at a time. On
  approval, it carries both updated balances into the next iteration.
  On a decline, it carries the previous balances forward. The last
  transfer shows that the declined withdrawal left the balances intact.
- The outer `Result` reports a messaging failure or a received receipt.
  A declined transfer is a valid receipt. `Close` gets a final receipt
  and ends the bank actor.

The balances live in memory for the duration of the example. For the
same request and reply pattern in a larger program, see the keeper in
[examples/swarm.fpr](../../examples/swarm.fpr) and the mailbox helpers
in [std/actor.fpr](../../std/actor.fpr).
