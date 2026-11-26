# txnabort.sol -- pins the statement-as-transaction contract
# (docs/2026-11-26-SOL-PROGRESSIVE-COMMITS.md): statement one writes and
# commits; statement two writes and then panics, so ITS write never lands;
# statement three never runs. Afterwards one.txt exists, two.txt and
# three.txt do not. Run by tests/sol-checks/statements.sol in a scratch dir.
boom x | x > 0 = x / 0 .
boom x = x .
> writePath "one.txt" "committed".
> u = writePath "two.txt" "must never exist"; boom 1 .
> writePath "three.txt" "never reached".
