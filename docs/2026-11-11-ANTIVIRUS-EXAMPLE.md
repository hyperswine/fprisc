# Expanding the antivirus example

11 November 2026. Implementation proposal for examples/antivirus.fpr at b8518da1.

The example scores rules against fictional decompiler output. Its most valuable next use is as a real FP-RISC workload where a caller can pause a search, predict its resource use and still get exactly the same evidence as the original matcher. A percentage measures the weight of matched rule lines. It has no statistical interpretation as a probability of malware.

## 1. Establish the compatibility and performance baseline

Ship small rules and assembly fixtures alongside the example so the documented command runs from a standalone checkout. Cover full and partial matches, equal scores with different evidence, shared bindings across clauses, a gap adjacent to a block terminator, invalid rules and exhaustion immediately before a winning match. Compare stdout and exit status in text and JSON modes with the sibling Python toyav reference when available. Keep golden outputs in FP-RISC so routine tests run independently.

Benchmark an already-built executable on three fixed inputs: a literal match, many plausible block starts with no match, and ambiguous skips with shared bindings. Record input sizes, elapsed time and peak resident memory. Time parsing and search separately where possible. Use the same inputs and output checks on both revisions.

## 2. Make the matcher resumable

Today clauseCands constructs candidate lists before foldCands charges them. A rule can do substantial work on regions, skip endpoints and token backtracking before its first budget check. Preserve the per-rule meaning and failure boundary of --max-states. Introduce a separate work allowance for advancing the search.

Store a cursor over clauses, regions, lines and tokens, a depth-first frontier of outstanding choices, the current bindings and evidence, and the strongest candidate so far. Expose a step operation returning Finished, Suspended with its continuation, or LimitExceeded with the exhausted limit. Advance skip endpoints and wildcard choices incrementally. Preserve traversal order and replace the best match only on a strictly larger score. Test that repeated one-step resumes and uninterrupted execution yield identical output and consume the same candidate budget. Exercise suspension inside a wildcard and a gap, including on a search that ultimately fails.

## 3. Reduce repeated work and bound space

Tokenize each source line once at parse time. Replace repeated list indexing with sequential cursors or indexed storage and compile binding names into slots while retaining their display order. Accumulate evidence without repeatedly copying the prefix. Add a literal or opcode index only after measuring these changes, and enumerate indexed hits in source order. Compare each change against the fixtures and the three benchmark cases.

Give the frontier, input bytes, tokens and retained evidence explicit limits. Enforce input limits during reading so oversized files cannot be loaded before the check. Specify the maximum work and allocation of one step in terms of the remaining bounded operations, including token comparison and binding updates. Use those contracts for resource inference. A simple-risc cycle claim also needs the target timing model and bounded runtime costs. A QOS caller could then choose a slice size and handle suspension or exhaustion explicitly.

## 4. Expand the example once the matcher is stable

Add parsed-rule output compatible with toyav's --ast and an explanation showing the evidence behind a partial score. A batch mode can parse the rules once and give each input an independent search budget. A later RISC-V disassembly adapter could check project policies such as calls to forbidden runtime entries. Start with assembler fixtures and exact instruction evidence. Rules involving reachability or the value of an MMIO address need control-flow or data-flow analysis before they can support a verdict.

The first implementation milestone is a standalone compatibility suite and a pretokenized, resumable matcher. Its acceptance gate is byte-identical reports and exit status across slice sizes, plus demonstrated bounded progress on the ambiguous no-match case.
