# A64 sized-frame validation in progress

Codegen 85, A64 selection 23 builds on the fully validated codegen-84
[RISC-V/runtime increment](../2026-10-23-sized-frames/README.md).
No commits or main sync have been made for either working-tree increment.

Dynamic A64 frames beyond the previous 32 KiB ceiling reserve their entire
decrement before full-frame writes. A bounded entry shim preserves all
64 incoming words and the link through the runtime call and thread-local
lookup. A third header word holds the original SP for return and tail exit.
The large prologue computes its frame base before saving the link, so large
displacement expansion cannot overwrite the size register. Smaller frame
emission, context ABI, FP allocation and save sets are unchanged.

- `native-oracles.*`: all six native Mach-O cases passed, global/x28/TLV
  hart access, self loops off/on. The direct IR uses 72,032-byte and
  40,032-byte frames, all 64 distinct incoming values, hostile runtime calls,
  canaries, exact SP restoration, foreign tails and integer/FP callee saves.
- `elf-assembly.*`: large-frame global, x28 and local-exec TLS ELF variants
  assemble with clang. This is not Linux execution evidence.
- `actor-runtime.*`: the same independently verified 9,000-field IR frame
  linked into the real actor runtime, nine nested calls, forced yields,
  one and four harts. Every returned field is checked independently.
  This is a real runtime/IR interoperability test, not a claim that a huge
  source fixture compiled quickly.
- `selected-ir.*`: portable selection/layout and refusal boundaries; a
  diagnostic fixture was corrected to respect A64's existing RISC-V-only
  builtin-profile boundary. The final rerun passes.
- `integrated.*`: complete final regression, portable assembly, all six native
  cases and both real actor runtimes, exit 0.
- `initial-global.*`: initial native global-hart probe, both loop modes.
- `development/`: deliberately stopped large source-fixture compiles and
  an oracle-only header-field typo. These are not acceptance results.

The integrated A64 regression now also assembles ELF TLS and Mach-O TLV on
non-A64 hosts, and runs all native/runtime cases on matching hosts. It is
registered in Base and CI. A final complete sweep is still required.
X64 sized-frame support and the complete migration goal remain open.
