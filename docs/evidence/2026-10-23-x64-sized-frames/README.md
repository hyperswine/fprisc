# x64 sized-frame acceptance

Codegen 86 / x64 selection 22 removes the 32 KiB dynamic-frame refusal.
Frames above the old ceiling reserve the full decrement plus the incoming
return-PC word. The entry shim stages all 64 words, including the seventh
and eighth TLS cells, with a C-aligned stack. A new segment gets a return-PC
copy for the standard frame header; a third header word restores the original
entry RSP on ordinary returns and foreign or generated tail transfers.

`oracles.log` / `.exit` retain four Rosetta runs: TLS/borrowed hart access,
self loops off/on, all 64 distinct arguments, hostile clobbers and borrowed
block switches, 72 KiB frames, canaries, fast/same/new stack paths, exact SP
and return-PC restoration, foreign tails and callee saves. Each complete ELF
unit also assembles before the harness substitutes its TLS cells.

The final test also links the same independently emitted frame into the real
Linux x64 actor runtime on matching hosts, for one and four harts. That branch
is registered in CI but is skipped on this macOS A64 machine. Rosetta execution
with modeled TLS is not a real x64 QOS or Linux scheduler result.

The [combined codegen-86 sweep](../2026-10-23-native-sized-frames-final/README.md)
passes all 123 Base jobs. The complete migration goal remains open and no
working-tree changes have been committed or synced to main.
