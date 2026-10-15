# Live host facts; bounded kernel snapshots can change independently of a txn.
snapshotWith limit = Host.snapshot limit.
snapshot u = snapshotWith 100000.
