# FP-RISC and QOS runtime overhead implementation

The three-hour implementation pass produced local changes across the FP-RISC compiler and actor runtime, QOS services, and both block backends. The results below give workload-specific counts and identify outstanding implementation work. Broad qualification against the saved release baselines is deferred.

## How much overhead has been removed?

There is no measured whole-system percentage. The following figures use different workloads and units.

| Area | Change and scope |
| --- | --- |
| Allocation and copying | The instrumented format application adopted 117,036,608 allocator bytes in one region transfer and matched its saved native output. This measures transferred storage. The number of CPU cycles saved is unknown. |
| Ownership | Native Apps.read uses immutable archive storage and skips one archive-sized allocation and copy per successful lookup. Portable duplicate reads share a worker buffer while each caller owns a separate reference. |
| Scheduling | On the 1,024-worker single-hart fixture, ready entries examined fell from about 35.1 million to 101,235, a 99.7% reduction. The dispatch sequence matched the reference. Multi-hart timing is pending. |
| Device I/O | An eight-page contiguous read can use one Portable worker request or one native virtio chain. The bytes transferred still total 32 KiB. Two callers sharing an identical pending two-page read save an additional 8 KiB worker buffer and one read. |
| Durable publication | Qlog reuses the validated generation and skips four page reads per successful ordinary or packed durable append. An eight-record bulk append uses two flushes for the batch. The two-flush protocol predates this work. |
| Independent durable appends | Two queued same-key appends received successful replies on a fresh Portable disk and advanced the durable generation once. Latest lookup returned the second value and replay returned both in order. Individual device flushes were not counted in this run. |
| Flush bookkeeping | Consecutive Portable flushes still waiting at the queue tail now share one allocation, one host barrier and one result publication. Eight such callers save seven job allocations compared with the earlier worker-side batching. |

For a running Files child, forwarding the incoming key and payload skips two keep operations. Cold starts retain both fields across child initialization. Portable writes still copy caller bytes into worker-owned memory so cancellation cannot invalidate an in-flight request. Each successful read caller copies its requested bytes out of the shared worker buffer. Whole-envelope ownership transfer under mailbox backpressure remains open.

Cross-unit treemap lookup still needs a demonstrated private register-result worker and an allocation count. Single-hart selection has a measured reduction, while multi-hart fairness, migration and contention still need qualification. For paired durable appends, fault injection and reopen after interrupted publication remain outstanding.

The detailed checkpoints below include both intermediate designs and later revisions. The deferred qualification section lists the comparisons needed for an end-to-end speedup and durability assessment.

## FP-RISC allocation and ownership

1. Fuse the materialized range feeding map in the format application. Keep the final list because the application traverses it several times. The existing mapRange worker calls the callback in descending order. Use a forward worker where the callback can trap or has observable effects, preserving the original range construction's endpoint behavior. Exercise this through the unchanged application source.
2. Return the tag and payload of eligible Option and Result values in registers when a private caller immediately matches them. Start with treemap lookup and CSV conversion. Keep the tagged representation at public and indirect calls. Count eliminated allocations by site.
3. Extend destructive reuse to last-use updates of uniquely owned products and map nodes. Carry ownership through the consuming call. Shared inputs must preserve snapshots, including child objects shared independently of the parent.
4. Address format's region-close copy. Transfer eligible slabs into the destination region when the escaping result retains most of their data. Account for attached references and dead bytes retained by adoption. Evaluate substring views for CSV and word counting with a retention policy for short slices of large inputs.

## Scheduling and message transport

5. Reduce ready-actor selection work at large populations. Measure entries examined and lock duration. Prototype indexed selection while preserving priority, aging, weighted choice, weight changes and migration timestamps. Compare against the existing selector at 1, 32 and 1,024 runnable actors on 1, 4 and 8 harts. The single-hart profile attributes 213 ms to selection and 0.28 ms to the clock increment.
6. Use the runtime's blocking receive for native storage requests wherever the pinned ABI supports it. Preserve deadlines and cancellation. Count fallback sleeps, parks and completions through the actual Files gateway.
7. Extend ownership transfer through large-payload forwarding routes. Identify a real relay that gives up its last reference, transfer its payload and preserve mailbox charging. Keep shared messages valid. Check sender death, receiver death and rejected admission at each transfer boundary.

## QOS block I/O and durability

8. Coalesce contiguous payload reads during cold replay. Group adjacent pages within device and request limits, preserve slice order and propagate partial-read errors. Count routed calls, device requests and transferred bytes independently. Compare first replay after reopen, warm replay and latest-value lookup.
9. Route callers with an explicit transaction boundary through durable bulk append. The existing bulk writer already uses two block flushes per batch, including an eight-record batch. For independent requests, implement group commit only where replies can wait for the same durable publication. Bound batch size and waiting time, preserve ordering and generation-conflict semantics, and acknowledge only after the publication flush succeeds.

## Deferred qualification

The implementation worktrees were based on FP-RISC `5aa730044d5fe45aba9b4a18f30d9807d7950499` and QOS `2fd6b1a10cd69c500da3bcd048c91444b30e1272`. The QOS compiler lock specifies FP-RISC `1b4aca1658d44c148496d8e2131138b8d71bc0b4`. Local edits are additional to those commits. The local QOS `fprisc.path` selects the sibling FP-RISC worktree. For a source-tree comparison, set `FPRISC_ROOT` explicitly for each build. QOS derives its compiler executable, runtime and machine sources from that root. An installed QOS tree uses its bundled toolchain. Record the final source revisions and any local edits alongside the measurements. Run the unchanged application output oracles, allocation-site counters, retained-snapshot checks, scheduler fairness and migration fixtures, relay copy/move comparisons, storage-wait counters, and cold/warm block traces. For group commit, exercise data flush failure, publication flush failure, torn publication, capacity exhaustion and fresh-process recovery. Record throughput and acknowledgement latency separately. Use physical-device measurements for board performance claims.

Starting evidence: [allocation sites and outstanding work](2026-11-12-ALLOCATION-SITES-STRINGS-AND-PRODUCTS.md), [QOS runtime and storage implementation](../../qos/docs/2026-11-12-OVERHEAD-IMPLEMENTATION.md), and [relay measurements](../../qos/docs/2026-11-07-PORTABLE-BLOCK-SPIN.md).

## Working-tree checkpoint

The format output matched the saved native oracle with forward range/map fusion. One region adoption transferred 117,036,608 allocator bytes in that instrumented run. Empty and single-byte substrings reuse immutable strings. Map membership and default lookup now traverse directly, and first visits only the left spine. Private result layout analysis now permits a String field while aggregate storage retains its original admission rules. A focused recursive Int/String sum program ran correctly. Its emitted RV64 assembly did not demonstrate a private result worker. The unchanged treemap lookup still calls the ordinary imported getGo entry. General immediate-match specialization, unique map/product reuse coverage and larger substring views remain open.

The scheduler skips weighted selection work once a valid local handoff wins. The indexed ready queue and fairness and contention measurements remain open. Native storage polling can return a message directly when paired with the newer runtime. Block worker and completion paths avoid intermediate keep copies. Ownership transfer of an entire received envelope under backpressure remains open.

Qlog issues range reads through Files and its block service. A seeded eight-page comparison passed through the real Portable worker and RV64 QEMU with virtio v1 and v2. The Portable implementation submits one host disk job, and native submits one virtio descriptor chain. ABI 23 requires matching Portable components. Publication of an archive and its journal row uses a single generation on durable storage; both values survived reopen. General coalescing of independent requests, crash injection on the publication caller, physical timing, and the deferred broader qualification remain open.

The single-hart ordered backlog fast path now uses the aged queue head when it can establish the same winner as the full scan. With 1,024 workers, scanned entries fell from approximately 35.1 million to 101,235 (about 99.7%). A native comparison with the fast path disabled via FPR_ORDERED_BACKLOG found identical dispatch sequences for 1, 32 and 1,024 actors across 68, 1,168 and 34,863 dispatches respectively. This measures scheduler work on those fixtures. Multi-hart contention and end-to-end timing still require qualification.

Native strJoin now reuses immutable empty and one-byte results. When one piece or separator supplies all the output, it reuses static storage or copies a heap-backed source directly into independently owned storage. This avoids the second list traversal for those joins. The runtime passed a host C syntax check. Runtime allocation counts and timing for this change are pending.

QOS native Apps.read now returns an immutable String embedded by the registry generator. A successful lookup avoids one archive-sized allocation and byte copy per read. Apps.list returns an immutable listing built by the registry generator, eliminating all per-call allocation and copying. A two-archive generation produced the exact 19 bytes of HelloProc and TUIClock in input order, each followed by a newline. The generator produced a registry from the saved HelloProc archive, and both the generated registry and loader passed host C syntax checks. Native image execution is pending.

Qlog ordinary and packed durable appends now read the two superblock slots once and reuse the validated generation through publication. This removes two repeated dual-slot lookups (four page reads) per successful durable append or batch. The data flush and publication flush still precede acknowledgement. The working Qlog module passed the compiler check with QOS foreign declarations. Device counters and recovery tests for this change are pending.

On the direct packed-record read path, latest lookup retains the offset and length of the last match and materializes its value once per matching record. An empty last value still overrides an earlier nonempty one. Packed concatenation collects nonempty matching slices and joins them once per record, avoiding repeated copies of the growing prefix. The working module passed the compiler check; runtime allocation measurements are pending.

Routed payload reads include the final partial page in a contiguous range when it fits the eight-page limit. A 4,098-byte payload now requests two pages together and trims padding from the reply. The replay fixture expects six routed requests across its scenario (previously eight), including exact full-page and partial-tail ranges. The updated fixture ran on a matching QOS Portable 23.221 host and returned qlogreplayreads: HOLDS. Its actor checked the six expected routed requests, and replay and latest lookup returned the expected bytes.

Cold Qlog index construction now prepends ordinary and packed entries and reverses the surviving list once. In an append-only log this reduces list construction from quadratic to linear in entry count. Tombstones still scan the accumulated entries to remove their key. The live bulk index builder also avoids repeated prefix copying within a batch. The working module passed the compiler check; reopen timing and allocation counts are pending.

Indexed replay now records only newly cached entries. With no cache fills it returns the existing index, avoiding the two index-list copies on every warm replay. When fills occur it rebuilds the prefix through the last replacement and shares the untouched suffix. A whole-record slice reuses the fetched immutable payload. The compiler check passed. Allocation counts and repeated replay execution are pending.

Qlog's append acknowledgement now indexes the key and small payload already owned by the storage actor. The receive loop keeps the request before releasing its mailbox root. Removing the subsequent string concatenations also avoids copying a large payload merely to classify it as uncached. The compiler check passed; sender-exit and cache-lifetime execution checks remain pending.

Qlog now validates requests before retaining any message fields. Expired and oversized requests release the received envelope without copying it. Accepted requests retain only the key or payload needed after a nested block receive. Statistics and reads retain the key, while compact, verify and generation queries retain neither field. The module passed the compiler check. Message-lifetime tests remain pending.

The Files gateway now checks deadlines and wire sizes before copying. Rejected, stale and quiesce messages release the received root directly. Forwarding retains the key and payload for the potential child-start handshake. The publicationbatch application compiled for QOS Portable with linearity checks. Standalone fs checking reported a Device type mismatch at serve. Gateway execution is pending.

With a running child, Files now sends directly from the received key and payload, then releases the incoming root before waiting for the correlated reply. This removes the gateway's two keep operations from the normal forwarding path. Cold starts retain both fields across the initialization handshake. The publicationbatch Portable compilation passed. Runtime behavior under inbox pressure and child exit still needs qualification.

Files retains its Qlog child when send admission reports a full mailbox or the deadline expires before sending. The caller still receives the refusal. This avoids killing a healthy worker and rebuilding its index on the next request. Both fresh and running children use the same refusal handling. Portable publicationbatch compilation passed; a forced-refusal runtime check is pending.

A second scenario in qlogreplayreads now passes the index returned by cold replay into warm replay and latest lookup. The Portable run returned HOLDS. Cold replay issued one two-page range and one single-page request. Warm replay issued only the range, and latest lookup of the cached final entry issued no block request. Both replays returned ABBC and latest returned C. These counts verify the cache behavior; they do not measure list allocation.

Direct-device Qlog readers now submit the same bounded contiguous ranges as routed readers. A full eight-page payload uses one range submission in place of eight single-page submissions. Both paths share short-reply validation and tail trimming. The working module passed its compiler check. Direct-path execution and device timing are pending.

Payloads spanning two through eight pages now return the checked range directly from the scratch arena, trimming only a partial tail. This removes list construction, reversal and the singleton join's extra payload copy. The Portable replay fixture passed exact-range and partial-tail content checks with the existing request sequence. Arena escape and transport costs are separate.

Unaligned indexed reads now include the first partial page in a contiguous request of up to eight pages. The Portable fixture placed a two-byte value at offset 4,095 and verified AB from exactly one two-page request. Previously that path issued two single-page reads and joined their slices.

Packed-record admission and recovery verification now check canonical lengths, key bytes, separators, record counts and payload bounds directly in the packed string. The validator no longer allocates temporary length and key strings or reconstructs each header for comparison. It bounds the decimal accumulator before multiplication. The module passed its compiler check. The actor's separate pre-count pass and group commit across independent callers remain open.

The Qlog bulk RPC now obtains the record count from its framing validation pass. It constructs the canonical QBLK header from that count and writes through the existing admitted-record path. Malformed batches return an error before metadata reads or writes. Recovery uses the same scanner and compares its count with the persisted header. The working module passed its compiler check. Independent-request group commit and runtime checking of this admission change remain open.

The qlogpackedframing fixture passed on QOS Portable. It checked the count of an empty batch and a two-entry batch with empty and binary values, a mismatched persisted count, and eight malformed frames including a decimal length beyond machine range. This exercises the parser used by admission and recovery; it does not inject a crash or count flushes.

Startup verification of ordinary records now hashes up to eight contiguous pages per request. Each scratch arena returns only the running hash and the final partial page contributes exactly its declared bytes. QOS Portable verified the digest of a 4,098-byte payload against an independent whole-string hash using one two-page request.

Before formatting, Qlog scans blank media in bounded eight-page ranges and checks the returned byte count. On Portable, qlogblankrange verified a nine-page scan used two requests, accepted all-zero data, and refused both a nonzero last byte and an empty tail reply.

Single-hart backlog insertion skips the donation fence because there is no peer to wake. Multi-hart stealing now advances through the neighbor list with an increment and wrap, removing the runtime modulo per candidate. A subsecond check matched the original victim sequence for every owner at one through 256 harts. End-to-end scheduling latency remains unmeasured.

Single-hart idle entry now skips the peer-steal fence and scan. The separate doorbell clear-and-recheck fence remains in place. Hart zero checks peer idle flags only when the deadlock counters indicate a candidate quiet period and stops at the first busy peer. The POSIX scheduler passed a C syntax check; concurrent timing and deadlock qualification are deferred.

The scheduler publishes its per-hart idle flag only when it changes. Consecutive busy dispatches and repeated idle polls avoid rewriting a flag shared with thieves and the deadlock detector. The multi-hart fence before scanning peers remains on every steal attempt. The host C syntax check passed. Concurrent execution and timing are deferred.

Each single-hart admission advances the machine-wide scheduling clock with a relaxed load and store, eliminating one atomic read-modify-write per admission. Refill is the sole writer. Multi-hart admission continues using an atomic increment. The scheduler passed a host C syntax check; timing is deferred.

Maximum backlog wait is now accumulated in cache-aligned, single-writer hart slots. The diagnostic query combines the maxima on demand. Admissions no longer read a shared maximum or contend in a compare-and-swap loop. The host scheduler passed a syntax check. Runtime contention measurements remain deferred.

Successful work steals increment a single-writer counter in the stealing hart's statistics slot. This removes the shared atomic increment per migration. The steals diagnostic sums the slots when queried. The host C syntax check passed; concurrent runtime measurements remain deferred.

Runnable-actor shipment increments an activity counter in the source hart's cache-aligned slot. Hart zero sums these counters when sampling for deadlock. The update remains atomic for overlapping activity on a single hart, while different harts no longer write one shared activity word. A host scheduler syntax check passed. Contention and deadlock stress tests are deferred.

Scheduler phase, loop count and sleep timestamp now occupy a 64-byte-aligned slot per hart. This separates repeated dispatch-path writes by neighboring harts. Readers sample the word-sized phase and loop count atomically, preserving the stronger ordering around sleep used by channel reclamation. Host C syntax passed; cache contention and runtime behavior remain unmeasured.

Compaction now reads up to eight contiguous pages of a retained record per block request and splits the reply into pages for the existing writer. Merkle leaf reconstruction for legacy records without stored hashes now streams the digest through bounded scratch arenas, avoiding full-payload assembly. Qlog passed its compiler check. Compaction recovery and device timing remain deferred.

Compaction's two record-selection passes now prepend each retained entry. The first-pass membership list can stay reversed; the final list is reversed once for disk order. This removes quadratic list-prefix copying during selection. Tombstone and key searches still have their own costs. Qlog passed its compiler check; compaction execution is deferred.

Compaction builds its Merkle leaves directly from the retained-page buffer before publication. This eliminates a separate device read of each retained data header and repeat reads of legacy payloads without stored hashes. Leaves are prepended and reversed once to preserve disk order. Qlog passed the compiler check. Root equivalence and recovery execution remain deferred.

Durable compaction carries the validated seal through its two prepared and two stable publications. Each successful publication returns the next seal only after flushing. This removes four dual-slot lookups (eight metadata page reads) on a successful normal compaction. Recovery also reuses the first stable publication for its second. All six normal-path flushes remain. Qlog passed its compiler check; crash-prefix behavior remains unverified for this revision.

On reopen, Qlog carries the selected seal through staged compaction recovery and through repair of an invalid or prepared alternate slot. Each path avoids rereading both superblock pages before publishing. The staged checksum and data flush still precede stable publication. The module passed its compiler check; interrupted-recovery execution is deferred.

Durable open now uses the two parsed slot results for both generation selection and alternate-slot retirement. Clean reopen eliminates one capacity lookup and one superblock page reread in that decision. Legacy fallback on a dual-slot-sized device also reuses page zero. Qlog passed its compiler check; reopen execution remains deferred.

Compaction's initial scan now prepends record descriptors and packed keys, reversing each list once to recover disk order. This removes quadratic list-prefix copying both across records and within packed batches. Qlog passed its compiler check. Allocation measurements are deferred.

Qlog now uses the working coreutil token reader, which scans to a space, newline or end before taking one substring. This eliminates per-byte concatenation and quadratic copying of long keys in header and packed-record parsing. The historical pinned module remains available to existing clients. Qlog passed its compiler check. Runtime allocation counts are pending.

Qlog formats record and superblock line terminators within the interpolated string, removing the separate full-line concatenation. Canonical record validation now constructs the legacy header only after the hashed form fails and the hash field is zero. The compiler check passed; serialized byte equivalence and allocation counts remain unmeasured.

Durable seal validation finds generation and staging hash in a single trailer scan, skipping unrelated fields by offset. Only the two numeric fields are sliced in this pass. Full canonical encoding and checksum comparison still gate acceptance. Qlog passed its compiler check; reopen and allocation measurements are deferred.

The trailer scanner now parses both numeric fields directly between token offsets with coreutil's existing bounded digit parser. A canonical seal therefore needs no token substring allocations during this scan. Qlog passed the compiler check; runtime allocation measurements are deferred.

Record-header parsing now reads page count, payload size and optional checksum directly from the input bytes. A hashed header avoids all three numeric token substrings. Legacy headers still use zero for an absent checksum. The module passed its compiler check; runtime equivalence remains deferred.

Packed lookup, replay, counting, key collection and index construction now parse lengths directly from byte offsets. Counting all entries also skips key bytes without materializing a key. Qlog passed the compiler check. Runtime allocation measurements are deferred.

Packed latest lookup, concatenation and per-key count compare the requested key directly against bytes in the record. They skip comparison on a length mismatch and stop at the first differing byte. These walkers no longer materialize a key string per entry visited. Qlog passed its compiler check; runtime savings remain unmeasured.

Qlog passes a complete nonempty single-page payload straight to pageWrite. Ordinary append, packed append and replacement avoid the preliminary substring copy when the entire payload fits within 4 KiB. Partial writes and multi-page slicing retain their existing bounds. Qlog passed the compiler check. Transport copying and end-to-end write latency remain unmeasured.

Bulk packing includes the newline in the length/key header and adds a payload fragment only when it contains bytes. Each nonempty record contributes two fragments instead of three; an empty record contributes one and still increments the stored count. The reversal and final join visit the shorter fragment list. The compiler check passed; byte-level runtime qualification is deferred.

Archive publication reuses its prepared journal contents and image key if the pair exceeds the wire limit or the owner explicitly refuses the batch operation. The fallback still appends the image before advertising it, but avoids formatting and copying the full catalog a second time. The publicationbatch fixture compiled for QOS Portable. Fallback execution is deferred.

Files namespace routing scans the original path backward from its end, stopping at the 16-byte service prefix. It slices only the key and operation, removing the prior intermediate copy of the complete path suffix. The standalone module check failed at serve with a signature mismatch. This routing change has no passing check yet.

Declaring Files.serve alone did not fix its standalone check. Files now imports the working lease endpoint with an explicit callback and actor entry signature at simpleUntil. The check preceded the endpoint adjustment, so the final combination remains unverified.

The Files lease sweep now reads the clock only for occupied slots. Empty slots take the lookup path without a timestamp call. The standalone Files check still reports the serve type mismatch with both signatures in place. The sweep edit followed that check and has not been executed.

The storageprotocol application compiled for QOS Portable with the working Files adapter and lease endpoint, including the path-slicing and empty-slot sweep changes. The compiler reported linearity OK. The earlier standalone Files signature diagnostic remains unresolved. Runtime behavior was not tested in this check.

Closing a Files lease now checks the handle generation and owner at the leaf and prunes on the return path. A successful close traverses the slot tree once instead of looking up and then clearing the same path. Failed closes return the original tree. The lease module passed its compiler check; allocation and timing are unmeasured.

Files endpoint dispatch uses one admission timestamp for the request deadline and handle expiry on reads and writes. This removes a second clock call and defines both checks at the same instant. The callback still receives the original absolute deadline. The lease module passed its compiler check; boundary timing tests are deferred.

The lease maintenance cursor now advances past a whole empty subtree in one turn. An empty half of the 64-slot table costs one sweep visit instead of 32. Occupied slots retain individual expiry and liveness checks, and new leases in a skipped interval are visited on wrap. The lease module passed its compiler check; sweep timing remains unmeasured.

Direct handoff now samples backlog length before checking interrupt bindings, scanning incoming rings or taking the backlog lock. A sampled length other than one returns to ordinary scheduling. A candidate still passes the locked checks before ownership changes, and handoff publishes the empty count atomically for concurrent samplers. The eight-hart POSIX configuration passed a C syntax check. Lock counts and handoff timing are pending.

In single-hart builds, waitFromUntil skips the temporary migration pin. For an unpinned actor reaching the sleeper/watch registration path, this eliminates two backlog lock acquisitions and releases per call. A build with multiple harts still pins the actor while the sleeper is linked. The single-hart POSIX C syntax check passed. Wait latency remains unmeasured.

Incoming-ring draining, idle checks and direct handoff now skip the local hart's ring. Local shipping always enqueues directly. Each full scan avoids one acquire load and a single-hart scan touches no ring. The eight-hart POSIX C syntax check passed. Timing is deferred.

Each cross-hart wake-ring producer caches the last consumer position it observed. It can enqueue into known free slots without acquiring the consumer cursor on every message. When that space runs out it refreshes the cursor, waiting if the ring is full. Every entry still receives its own release publication. The eight-hart POSIX syntax check passed. Runtime contention and throughput are unmeasured.

The wake-ring consumer copies up to eight actor pointers to a local array, returns those slots with one release store, then admits the actors in arrival order. Publishing free slots before admission allows the producer to reuse them even if admission forwards work. For N entries in one ring snapshot this issues ceil(N/8) release stores. The eight-hart POSIX syntax check with cost probes enabled passed. Concurrent execution and the cost of staging pointers remain to be measured.

Single-hart builds now omit the backlog lock during insertion, selection and local direct handoff. Only the owner and peer schedulers performing steals participate in this lock. SimpleRisc retains its recursive-entry diagnostic. The lock-time probe skips the clock when the lock is absent, while scan counts remain available. The single-hart POSIX syntax check with cost probes passed. Runtime qualification is pending.

Single-hart builds now select the single-writer admission clock at compile time, removing the live-hart count check per admission. The same predicate specializes ordered backlog selection, donation, peer handling and priority invalidation. Builds supporting multiple harts still consult the live count. The single-hart POSIX C syntax check passed. Timing is pending.

Hart zero now sums activity counters only when actors are blocked, no sleeper or interrupt waiter can wake them, and all sampled peers are idle. Other idle-detector passes skip one atomic read per live hart. The first eligible sample establishes a fresh baseline, which can delay deadlock reporting by one sampling interval. The eight-hart POSIX syntax check passed. Detector execution is deferred.

Direct bulk append and storage actor bulk append now share the same counted packed-record writer. Direct callers validate framing and the supplied record count before hashing or reading device metadata. A valid direct append avoids reparsing and reconstructing the header it just generated. Independent-request group commit is still open. The attempted module check rejected the command-line foreign-declaration option before compilation.

Conditional replacement scans the first eleven bytes of the generation frame in place and compares the token against the request bytes directly. It removes both prefix substrings, retaining the payload slice on success. The module check accepted the foreign-declaration environment setting but stopped before compilation because FPR_HOME resolved the prelude under qos/core. Runtime behavior is unverified.

Conditional write validation now compares generation digits directly against the integer from the seal, eliminating the formatted token allocation. The comparison requires canonical decimal length, including the single-digit zero case. The module check located the compiler prelude but stopped resolving QOS std/blockio before this final edit. Compilation and runtime validation remain pending.

The fresh-process Portable durable fixture now imports the working Qlog module so its append, replace, replay and recovery probes exercise the implementation under development. Previously its import selected a saved module revision. The standalone module check with a combined QOS and FP-RISC module directory stopped at a denied compiler-cache write. For the next check, use a writable XDG_CACHE_HOME. No recovery run was performed.

The Portable durability fixture passed fpr check importing the working Qlog, including the counted bulk writer and in-place generation comparison. The check used a temporary combined module directory and writable XDG_CACHE_HOME and took under one second. Crash recovery, concurrent requests and device timing remain deferred.

Qlog now retains one shared immutable payload for each packed record of up to 4 KiB when building its index from disk or a successful bulk append. Indexed latest reads and replay can slice values directly without rereading that record. This trades up to one payload page of retained memory per indexed batch for fewer device requests. The Portable durability fixture passed its compiler check; device counters and retained heap are unmeasured.

For packed records larger than eight pages, indexed replay reads just the covering pages when the only nonempty match is at most one page long. A scan of the remaining entries for that record detects repeated matches and preserves whole-record sharing in that case. A qualifying replay needs at most two payload pages. The Portable durability fixture passed its compiler check. Sparse replay request counts and index scan time remain unmeasured.

Direct latest-value lookup now carries the page and length of the latest matching ordinary record until the header scan ends. Overwritten or deleted ordinary values incur no payload reads. Packed records still require inspection to identify their keys. The Portable durability fixture passed its compiler check. Execution and device traces are deferred.

Direct replay now gathers matching ordinary and packed fragments into one reverse-order list and joins the surviving fragments once. A matching tombstone clears the list. This removes repeated copying of the growing output across records. The Portable durability fixture passed its compiler check; replay bytes and timing were not measured.

Durable replacement now validates its shared key once and checks both generated header sizes directly. This removes two header parses and canonical re-encodings. Head and capacity refusals precede payload hashing. Both records still share the existing data and publication flushes. The Portable durability fixture passed its compiler check. Recovery and refusal behavior remain untested for this change.

Ordinary QREC appends and QDEL tombstones now validate the generated header size, key and tombstone payload directly. They avoid parsing and reconstructing their own header on each append. The generic path retains packed framing checks. The Portable durability fixture passed its compiler check. Runtime allocation and recovery tests are deferred.

Added appendPairSealed for independent-request group commit. It preflights two ordinary records against one durable head, writes distinct records in order, and returns their page boundaries after the shared data and publication flushes. The storage receive loop still dispatches one request at a time. Deadline-aware collection, ordered handling of a nonmatching next request, index updates and replies are outstanding. The Portable durability fixture passed its compiler check; no runtime flush reduction is claimed yet.

The working Qlog actor now polls once after admitting an ordinary append. A second queued ordinary append can share a durable publication under the earlier deadline. Both index entries are built in order and both replies follow publication. A different operation or pair preflight refusal takes the sequential path, retaining the polled request across the first write and checking its deadline before dispatch. Collection adds no timer wait. The Portable durability fixture passed its compiler check. The live actor, flush counts, crash recovery and service packaging still require qualification.

System and qsys import working std/fs, whose owner starts the working Qlog actor. Portable durability action 13 now submits two ordinary writes before awaiting either reply and checks both acknowledgements plus same-key replay order on a fresh image. The fixture passed its compiler check. Scheduling may still separate the writes; a device flush trace is needed to distinguish the paired path from sequential publication.

Action 13 now gates the storage worker until the initial generation query and both appends have been queued. It requires the final generation to advance exactly once and checks both successful replies and replay order. This distinguishes one durable publication from two on execution. The fixture passed its compiler check. No live generation or device flush count has yet been observed.

Action 13 built and ran against a fresh 1 MiB temporary disk with the saved Portable host. The runtime reported every hart idle with an actor blocked before the success assertion. The probe now provisions its gated storage actor with eight inbox slots, matching the service and accommodating requests queued before the gate opens. That edit followed the run; the cause and fix are unconfirmed. No successful group commit or flush count was observed.

The action-13 build exposed an arity error in the probe's enlarged-inbox spawn. The fixture now uses the storage wire module's spawn wrapper and byte budget, as std/fs does. The run stopped at compilation before launching the host. The corrected fixture awaits execution.

The eight-slot probe built and launched on a fresh 256-page Portable disk. Qlog reported invalid I/O before the deadlock detector fired. The fixture was serving an older pinned block protocol without ReadRange while working Qlog imported current blockio. Both now import working blockio. This removes a concrete protocol mismatch; its role in the observed error and group publication remain unverified.

With matching working blockio on both sides, action 13 passed on a fresh 256-page QOS Portable disk. Two independent queued appends both received success, replay returned firstsecond, and the durable generation advanced exactly once. This confirms shared publication in the running actor. The host trace did not count individual flushes. Crash injection, reopen and physical timing remain deferred.

Group-commit lookahead now validates both borrowed fields before retaining either. Rejected requests retain neither field, and accepted requests retain only the key or payload their operation uses. Ordinary dispatch uses the same field selection. The Portable durability fixture passed its compiler check. Allocation counts and runtime behavior for this edit remain unmeasured.

Private variant-result planning now recognizes a producer whose final expression binds its result and immediately returns that same variable. The planner examines the right-hand side in its original scope, allowing eligible constructors and forwarding calls there to use the register-result convention. The changed Haskell module typechecked. Worker emission and allocation savings on treemap are still unverified.

The private variant-result reader now follows a local alias into its immediate match. Substitution respects let and lambda binders and declines capture of the packet name. Escaping uses still fall back to the boxed convention. The compiler module typechecked. Generated worker selection and treemap allocation counts remain unmeasured.

The variant-result reader can now translate a standalone tag predicate to a test of the returned discriminant, including when the Boolean is returned or passed as an argument. Previously only a predicate used directly as an if condition had that rewrite. The focused compiler probe failed to load its stdin source before exercising the change. Generated code and allocation savings remain unverified.

A focused executable compiler probe passed for the combined alias and standalone tag rewrite. It built a two-variant producer plan and required the aliased caller predicate to become a tag test of returned word zero. This verifies the Core transformation; treemap worker emission and allocation measurements are still pending.

Private variant-result layout inference now admits a constructor field supplied by a generic type variable as one tagged word. This removes the type-layout rejection for Option v in generic Map.getGo. The storage layout predicate still requires its existing scalar types. The inference module typechecked. End-to-end worker selection, region closing with managed payloads, and allocation savings remain unverified.

After rebuilding the compiler, the unchanged treemap benchmark compiled for RV64 base. The emitted lookup call still targets fpr_fn_getGo_x4089e6b37e2c53c693. Generic layout admission alone has not switched this call to a private result worker. The linked Cabal executable was used directly because Cabal could not write its final build log.

The treemap root calls getGo in a separately emitted map unit. The previous compile reused imported assembly with the same cache suffix as before the variant-result changes. The compiler now uses pc6 for those unit paths so the new planner runs on rebuilt imports. This cache change does not by itself make a private worker callable across units. Fresh unit emission and a checked cross-unit worker contract remain pending.

A clean-directory RV64 base compile of unchanged treemap regenerated every unit in two seconds. The caller still calls ordinary getGo and the map unit emits no variant-result getGo worker. The linked compiler included the variant planner changes and predated the pc6 cache-key edit; the empty unit directory excluded stale assembly independently. The cross-unit reader and producer need coordinated worker selection.

Root specialization now receives checked variant-result facts from dependency owners when the qualified imported body and its parameter names match. This supplies evidence for imported producers cloned by specialization. It does not create an external worker or force a clone. The result-fact module typechecked; the compiler driver and treemap emission have not been tested with this change.

Callback specialization previously kept checked result layouts only for renamed local inputs. It now carries a matching source result layout onto each completed callback clone, using the actual clone parameter list after callback captures are substituted. This includes imported sources with transported facts. Mono typechecked; a getGo clone and allocation removal on the treemap workload are not yet demonstrated.

Field-worker creation now copies checked variant-result layouts onto workers with a validated argument expansion. The optimization pipeline carries those updated facts from MakeWorkers to PairReturns. Previously field-worker evidence stopped after scalar worker creation. The Core optimization pipeline typechecked. Emitted worker selection and allocation counts remain unverified.

Variant producer planning now follows a returned value through a pending call-region close. It reuses the packet-aware close used by immediate-match callers, carrying fields together through an active region and forwarding the packet directly on the inactive path. The planner module typechecked. Region lifetime execution and cross-unit treemap worker selection are still pending.

When a returned packet is built entirely from integer literals or static nullary constructors, the compiler now closes the pending call region directly. This removes the active-region test and temporary carrier tuple for those exits, including an empty Option with literal padding. Dynamic fields retain the copy/adopt path. The planner typechecked. Emission and allocation counts remain unverified.

For two-word variant returns, the region close now transfers the payload directly. The immediate or static tag stays in the private packet and is paired with the returned payload afterward. This avoids the active-region query and the temporary two-field heap tuple. The planner typechecked. Native lowering, managed payload survival and runtime allocations remain unverified.

A known wide variant with one dynamic field now transfers only that field across a region close and reassembles the return words in their original order. Literal fields and padding need no carrier tuple. Unknown wide variants and multiple dynamic fields retain the shared copy/adopt path. The compiler module typechecked. Emission and lifetime tests remain deferred.

Region-close carriers for multiple dynamic return fields now contain only those fields, in source order. The returned tag and proven static slots remain outside the carrier and are merged back after the single copy/adopt operation. A tag plus two dynamic values uses a two-field carrier in place of a three-field carrier. The compiler module typechecked. Actual allocator bytes and payload lifetime remain unmeasured.

RV, A64 and x64 lower string literals to static-object addresses. The variant-return pass now excludes literal string fields from region ownership transfer. A focused compiler probe confirmed that returning a variant with a literal string closes the region with an immediate zero and forwards the original packet. No native runtime timing was measured.

For a known variant constructor that repeats a bound local in multiple fields, region close transfers that value once and reuses the transferred result in each original position. A two-field payload containing the same local can now use a single direct transfer without a carrier tuple. Arbitrary repeated expressions keep distinct slots. The planner typechecked. Runtime identity and allocation measurements remain pending.

A focused Core probe confirmed the repeated-payload case emits one region close on the first payload word and uses its returned value in both result fields, preserving their order with no carrier tuple. Native execution and measured allocation counts are still pending.

The storage actor now keeps its index newest first. Single and paired appends prepend one or two entries, eliminating the full index-prefix copy on each successful write. Packed append adds entries directly to the same list. Boot and compaction rebuild in that order, latest lookup stops at the first match, and replay builds chronological output while scanning backward. Standalone chronological index APIs retain their original order. The Portable durability fixture passed its compiler check. Replay, reopen and allocation measurements for this revision are pending.

Action 13 now also requires latest lookup to return second after replaying firstsecond. The build linked the updated FP-RISC compiler but Cabal failed writing its user-cache build log, before building or launching the fixture. The newest-first index therefore still needs a runtime pass. Use the linked compiler directly or a writable Cabal logs directory for the next run.

The paired-index probe built, but compiler discovery picked an older Cabal package and produced ABI 23.143. The 23.221 host refused it before executing any app code. The current linked executable is dist-newstyle/build/aarch64-osx/ghc-9.8.2/fp-risc-0.13.1/x/fpr/build/fpr/fpr in FP-RISC. Select that exact package for the next run; the newest-first assertions remain unverified.

The newest-first index passed paired-write action 13 on a fresh 1 MiB Portable disk using the linked FP-RISC 0.13.1 compiler. Both replies succeeded, generation advanced once, latest returned second, and replay returned firstsecond. This run covers the live index after publication. Reopened index behavior, fault injection and allocation counts remain unmeasured.

Index deletion and replacement now locate the final matching entry and share the untouched suffix. Removing an absent key or a key present only at the head allocates no replacement index nodes. When the final match is deep, the prefix is visited twice. The Portable durability fixture passed its compiler check. Deletion behavior and the CPU/allocation tradeoff remain unmeasured at runtime.

Snapshot and bytes-only indexed replay skip building cache entries and replacement index prefixes that their callers would discard. Ordinary actor replay still fills and retains its cache. Bytes-only replay with an empty prefix returns the joined bytes directly. The Portable durability fixture passed its compiler check; snapshot allocation counts and execution are pending.

Both snapshot paths now include the generation header in the replay join. This removes a separate concatenation of the complete replay payload. The Portable durability fixture passed its compiler check. Snapshot output and copied-byte counts await runtime qualification.

Replay now returns its prefix directly for zero matching pieces and returns the existing immutable piece for one match with an empty prefix. A one-piece snapshot concatenates the header and piece directly. These paths bypass the general join and chronological list reversal. The Portable durability fixture passed its compiler check. Runtime allocation counts remain pending.

Cold replay now folds cache replacements into a reversed index prefix as it reads. This removes the per-fill position tuple, the update list and its reversal. The tail after the final fill is shared directly, and a replay with no fills returns its original index. The Portable durability fixture typechecked. Runtime cache behavior and allocator counts await qualification.

Version 3 actor startup now builds its index during committed-log verification. This eliminates the second header read for each record and the second payload read for each packed record during index construction. The actor receives the index only after the scan succeeds. Standalone verification uses the same checks with index construction disabled. The Portable durability fixture typechecked. Recovery execution, memory use and device request counts remain unmeasured.

During version 3 index recovery, a hashed single-page QREC now enters the cache from its verification read. Latest lookup and replay can reuse those verified bytes immediately after reopen. This retains live small payloads at startup, including those never requested. The Portable durability fixture typechecked. Peak memory and first-read device counts remain unmeasured.

Qlog compaction now groups physically adjacent retained records before reading their pages into the publication buffer. The existing eight-page request limit applies across record boundaries. A gap ends the run. Four adjacent two-page records can now use one eight-page range request during buffering. The Portable durability fixture typechecked. Device traces and compaction timing remain pending.

Durable compaction now counts the header and payload pages from retained record metadata. It checks staging capacity and publication generation room before reading retained pages into the staging buffer or computing its Merkle root. A rejected compaction still verifies and scans the source log. The Portable durability fixture typechecked. Capacity and generation failure cases await runtime qualification.

The durable compaction staging writer now computes the recovery checksum in page order as it writes the staging partition. This removes a separate traversal of the buffered page list. Publication still follows the staging flush. The Portable durability fixture typechecked. Interrupted compaction recovery and elapsed time await qualification.

Single-candidate backlog admission now takes the sole ready actor directly under the existing backlog lock. It skips weight selection, advances the lottery once, and reads the shared admission clock and aging threshold only when a matching handoff hint could affect the next dispatch. Non-ready entries still go through cleanup. The scheduler passed a C syntax check with cost probes enabled. Dispatch sequences and lock time for this change remain unmeasured.

Backlog selection accumulates removals under the admission lock and publishes the new queue length once before releasing it, including before teardown and retry. A scan removing several stale entries and a winner therefore performs one shared count update. A sole ready entry sets the count directly to zero. Thieves may briefly sample the old count before acquiring the lock. The scheduler passed a host C syntax check with probes enabled. Multi-hart contention remains unmeasured.

When an ordinary admission empties the backlog and the FIFO is empty, refill returns the selected actor directly to dispatch. This avoids linking and immediately unlinking one FIFO entry and, for refill capacity above one, another empty selection. Hinted handoffs retain their build option. The dispatch state check still handles blocked or dead actors. Host C syntax with cost probes passed. Dispatch timing remains pending.

Cross-hart shipment now fences after ring publication and rings the destination only if its idle flag is set. On the receiving side the scheduler checks incoming rings after publishing idle and fencing, before stealing or sleeping. This trades unconditional interrupt delivery for a sender fence and idle read plus an idle-side ring check. Four-hart host C syntax with probes passed. Wake races, latency and actual interrupt counts await runtime qualification.

The cross-hart benchmark now reports xship_ipi_n, counting wake-interrupt requests issued by actor shipments. Subtract it from xship_n to count shipments that skipped the interrupt. This excludes interrupts for timers and work stealing. A four-hart host syntax check covered the runtime and benchmark probe. Full-ring producer stalls and wake latency still require execution under contention.

One host probe requested two live harts and ran 100 integer round trips with the worker spawned on hart 1. It returned the expected sum 5050 and counted 200 sends and receives. The measured window recorded zero cross-hart shipments and one drain, so it provides no interrupt-suppression rate. A workload that verifies continued separation of the two actors is needed for that measurement.

The pinned-wake benchmark checks hart placement across 100 round trips and starts counting before worker creation. One two-hart host run passed placement, with 200 sends, 200 receives, two runnable-actor shipments and two shipment interrupt requests. Zero of those two requests were suppressed. This run does not quantify savings under busy-destination traffic.

Multi-hart wake rings now place the consumer cursor, producer cursor and pointer array at separate 64-byte boundaries. Returning slots and publishing new shipments therefore target different 64-byte blocks. The single-hart build retains the compact layout. The change adds padding per source/destination pair. A four-hart C syntax check passed. Cache traffic and throughput remain unmeasured.

Ordinary sends of tagged integers now bypass the message-copy and reference-count helpers. The mailbox slot already holds the entire value. Bounded sends still reserve and publish the charge and retain cancellation bookkeeping. This removes helper calls from the source path. No byte-copy or heap-allocation savings are claimed for immediate values. Four-hart host C syntax with probes passed.

Mailbox dequeue now bypasses receive-root bookkeeping for tagged integers on both FIFO and selective receives. The FIFO path also skips checking the inline cell for an integer. Mailbox budget is released for every consumed slot as before. The syntax check passed with a constant-operand warning; the condition was reordered afterward. Runtime timing is pending.

Selective receive shifts a contiguous prefix using overlapping bulk moves on rings without inline cells, including sender tags and charges when present. Wrapped prefixes and rings with slot-relative values retain individual relocation. That loop now terminates by index equality across unsigned cursor rollover. Four-hart runtime C syntax passed. Selective ordering, rollover execution and timing await qualification.

Mailbox ring replacement now copies contiguous runs from a ring without embedded cells, splitting at source and destination wrap boundaries. Values, sender tags and admission charges are transferred before publishing the replacement. Rings with embedded cells still relocate each live cell. Four-hart host C syntax passed. Queue growth under concurrent receive and elapsed-time savings remain unmeasured.

Sender-channel lookup now stops at the first never-claimed dedicated slot. Dedicated slots are claimed in prefix order and reused by direct sender replacement. Read-only lookups also skip testing other senders for death and checking their queues for reclaimable space. The shared-channel fallback remains available. Four-hart host C syntax passed. Concurrent claim/reuse and scan savings await runtime qualification.

The any-message readiness check now stops scanning dedicated channels at the first unused slot and checks the shared ring separately. With one claimed dedicated slot and an empty mailbox it reads two dedicated sender fields instead of eight sender fields. A pinned two-hart host run passed 100 round trips, counting 200 sends and receives and one wake-interrupt request for two actor shipments. This run did not measure the readiness check in isolation.

Result-message readiness, actor receive and syscall polling now share a channel search that reads the ring backing pointer only after observing a nonempty queue. The readiness predicate also skips unclaimed dedicated channels after the first unused slot and checks the shared channel separately. Four-hart C syntax passed. Runtime syscall and selective-result behavior await qualification.

Routed Qlog record writes with one to seven payload pages now submit the header and payload to the block owner in one request. The worker checks the complete device interval before writing and issues the individual page writes in order. Direct writes and larger records use the existing path. This reduces routed admissions and replies while retaining the existing durability barriers. The Portable durability fixture typechecked. Runtime worker behavior, timeout and recovery remain unverified.

Large routed Qlog records now continue across bounded eight-page write requests. The first request carries the header and seven payload pages. Each subsequent request carries up to eight payload pages and uses the original absolute deadline on bounded routes. A record with fifteen payload pages takes two routed data requests. The worker still submits page writes individually. The Portable durability fixture typechecked. Large-record reopen and fault behavior await runtime qualification.

The block worker now calls blkWriteRecord for a routed record batch. Native virtio fills the existing eight-page DMA buffer with the header and payload, zeroes padding and issues one write descriptor chain. Portable writes from the same source strings with one host job per page, avoiding intermediate FP-RISC substring objects. The native driver passed a host syntax check. Image linking, Portable execution and durable readback remain pending.

Portable ABI 24 adds a record-write job. Submission copies the header and payload into a single zero-padded, worker-owned buffer before returning. The worker issues a contiguous positional write and completes short writes before reporting success. A full eight-page batch requires one host queue admission and one completion wait. The Unix worker passed C syntax checking with fault hooks enabled. Matching app/host packaging, durable readback and timeout behavior remain unverified.

Direct-device Qlog appends now use the same bounded record batches as routed writes. Both the Portable manifest generator and host loader derive the ABI major from qos_abi.h, currently 24. The Portable durability fixture typechecked. A freshly packaged image and direct-device batch readback remain unverified.

A focused Unix worker run wrote an eight-page record to pages 2–9 of a temporary 12-page image. The caller overwrote its payload immediately after submission. After worker completion, flush and process exit, a separate reader matched the original payload, header padding, eleven trailing zero bytes and all four neighboring sentinel pages. This covers the worker ABI operation directly. Packaged Qlog execution and crash recovery remain pending.

Portable flush jobs now allocate only their request metadata, removing 4,096 requested buffer bytes per flush. Single-page async writes use the worker-owned padded buffer directly. Synchronous full-page writes also bypass the temporary copy, and both paths use the positional-write retry loop. The Unix worker passed a C syntax check with fault hooks enabled. Runtime latency and single-page readback remain pending for this revision.

Portable single-page reads now deliver the completed worker result directly into the returned FP-RISC string. This removes a 4,096-byte stack buffer and one full-page copy per successful read. The worker still owns its buffer until completion or abandonment. The app-side HAL passed a host C syntax check. Runtime readback and timing for this path remain pending.

Native single-page reads allocate their result string before taking the block lock. The driver retains the lock through transfer and copying from shared DMA storage. Replay profiling now excludes allocation from the copy interval. The native driver passed C syntax checking with replay profiling enabled. Lock-time savings remain unmeasured.

Native single-page writes stage the payload with a bulk copy and zero only the unused suffix. This removes the per-byte length test from the source loop under the device lock. Record writes use the same padding routine. The driver passed a host C syntax check. Native timing and readback remain pending; native virtio still reports flush as unsupported.

The native virtio driver now negotiates VIRTIO_BLK_F_FLUSH on initialization and reset. A supported flush uses a header/status chain, sector zero and the existing serialized completion and timeout path. Unsupported devices return the existing unsupported result. The RV64 negotiation branch passed a host C syntax check. Device execution and power-loss recovery remain unverified.

Portable disk barriers now sync the backing directory on the first successful flush per open. Later barriers still sync the disk file and request F_FULLFSYNC on macOS, but omit the repeated directory sync because the worker only overwrites file contents. A failed directory sync leaves the first-flush obligation pending. The Unix worker typechecked with fault hooks. Crash behavior and syscall counts remain unmeasured.

On macOS each Portable file barrier now directly requests F_FULLFSYNC, which includes file synchronization and requests a drive-cache flush. This removes one redundant file fsync per barrier. Other hosts still call fsync, and the first directory sync remains separate. A temporary-image test completed two writes and two barriers and matched both padded pages after the writer exited. Physical power-loss behavior remains untested.

Portable disk setup uses pthread_once to publish the descriptor and capacity. Reads, writes, flushes and capacity queries no longer explicitly acquire and release the setup mutex on every call. An eight-thread temporary-image test passed with all callers observing 256 pages. Steady-state timing remains unmeasured.

Portable disk submissions now signal the sole worker only when the number of queued plus running jobs goes from zero to one. Submissions behind an active job preserve FIFO order without another condition-variable signal. A temporary-image test completed three bursts of 32 writes and a flush, and all 32 final pages matched after exit. Signal counts and elapsed-time gains were not measured.

The Portable worker groups adjacent flush jobs already in its FIFO at dequeue time. Every caller gets the same barrier result, and an intervening write starts a new group. No batching delay is added. A fault-injection run queued three flushes, a write and two flushes. The worker made two barrier attempts: all three first-group callers saw the injected failure, the write succeeded, and both final callers saw success. This does not combine Qlog's data and publication barriers across their intervening write.

The block owner now handles requests while their incoming envelope is live. It keeps a command only when admission places it in the pending FIFO. Immediate worker dispatch, rejected requests and owner-local controls avoid the previous unconditional keep of the request and its payload. Worker sends still establish their own ownership. The Portable durability fixture typechecked. Queue lifetime, cancellation and copy counts await runtime qualification.

Block cancellation of an absent queued request now retains the original queue and owner state. A successful removal shares the suffix and reuses each original pending entry while rebuilding the prefix. The Portable durability fixture typechecked. Runtime cancellation behavior and allocation counts remain pending.

The block owner now keeps a FIFO front and a reversed list of incoming requests. Enqueue adds one list node regardless of backlog depth. Dispatch reverses incoming entries when the front empties. Cancellation searches the front first and removes the oldest matching token. Offline failures still reply in FIFO order. The Portable durability fixture typechecked. Runtime queue ordering under cancellation and allocation counts remain pending.

Cancellation in the incoming half of the block FIFO now traverses that bounded list once, selecting the oldest matching caller and token. It shares the entire front and the older suffix, rebuilding only entries newer than the cancelled request. This removes the previous reversal and front concatenation. The Portable durability fixture typechecked. Duplicate-token behavior and allocation counts await runtime qualification.

During active block I/O, empty mailbox polls now retry inside the wait function without reconstructing the running request, owner and loop-state tuples each time. Incoming commands still return to normal handling. The wait checks the deadline after sleeping before consuming another message. Polling still uses a 100-microsecond sleep. The Portable durability fixture typechecked; timeout behavior and allocation counts remain unmeasured.

An active block owner can now park until any incoming mailbox message or its absolute request deadline. The FP-RISC wait shares the existing timer and block/recheck protocol with the sender-specific wait; an any-message wait needs no sender-death watch. Both QOS HALs expose the operation and use the polling fallback when the runtime cannot park. The C runtime and HAL sources passed a syntax check. Packaged linkage, cancellation wakeup and timeout execution remain pending.

The timed-readiness fixture now exercises any-message wakeup and an empty-mailbox deadline for the main actor and a spawned waiter. A two-hart host run passed, including the existing sender-specific cases. The delayed message remained available to receiveNow and the empty deadline returned the parked status. Packaged block-service integration is still pending.

The block owner now dispatches an idle receive directly and returns the next owner state from the active wait. Both paths omit the intermediate Ok envelope around a successful message. The shared handler drops the incoming envelope after processing it. The Portable durability fixture typechecked; emitted allocation counts remain unmeasured.

Qlog now submits paired appends and tombstone-plus-replacement records as one data write when both headers and payloads fit within eight pages. Each record retains its page-aligned on-disk layout. Packing incurs a bounded temporary string and padding work. Larger pairs retain separate record submissions. The data and publication flushes stay ordered. The Portable durability fixture typechecked; pair readback and timing for the packed path are pending.

Paired-record packing now allocates its outgoing payload string once and writes the two interior padding spans directly into it. This removes the intermediate zero strings and join list. The first header is still passed separately and the driver pads the last page. Both HAL translation units passed a host syntax check. Packaged linkage and byte-for-byte readback are pending.

Portable SDK staging now includes hal/blk_pack.h among its hashed platform sources. The app-side HAL resolves it through the existing HAL include directory. A syntax check passed from an isolated SDK-layout tree without a source-checkout include path. Full archive packaging and runtime linkage remain pending.
When both record payloads are empty, the block packer now returns the existing second header directly, eliminating one temporary allocation and its header copy. A standalone C check compared five layouts against independently constructed bytes, including partial pages and an exact eight-page pair, and verified pointer identity for the empty pair. End-to-end device readback and timing remain pending.

Qlog now submits records with one to seven payload pages directly without entering the continuation writer. For a packed-key read with one matching nonempty slice and an empty accumulator, it returns that slice directly, skipping list reversal and the final string join. The Portable durability fixture typechecked. Runtime timing is deferred.

Structured bulk append validates keys while assembling record headers and uses the count from that traversal. It removes the subsequent framing parse for this entry point and rejects an invalid key before joining the payload. Caller-supplied packed bytes still pass through packedCount. Key validation reads each key byte once. The Portable durability fixture typechecked. Runtime measurement is deferred.

Verified log scans now parse the header directly in the loaded page, bounded by its first newline, and compare canonical bytes over that same span. This removes the temporary header-line substring per padded record page. The Portable durability fixture typechecked. Corruption and replay execution are deferred.

Superblock parsing now reads the head and tagged numeric fields directly from page bytes. The v3 seal checker compares the canonical line against the bounded page prefix without copying the input line. A dual-slot lookup uses this path for each slot. The Portable durability fixture typechecked. Recovery execution and timing remain deferred.

Metadata open reuses the primary page for legacy fallback after dual-slot inspection, reducing that path from three page reads to two. Equal-generation selection compares the parsed fields encoded in the v3 seal and the staged-image hash directly, avoiding two canonical-line constructions and checksum recomputations. The Portable durability fixture typechecked. Device recovery tests remain deferred.

Buffered startup uses openMeta to reuse the primary page on legacy fallback. Durable startup repairs an unclean non-compaction seal by publishing from the validated generation already selected by ensureDurable. This removes a second dual-slot lookup while retaining the repair write and flush. The Portable durability fixture typechecked. Crash recovery execution remains deferred.

Durable fresh-disk detection on devices with at least three pages reuses both metadata-slot buffers for the blank check. It requires two full zero pages and scans the interior before formatting. On blank media this saves two pages of device traffic. The Portable durability fixture typechecked. Fresh-media execution is deferred.

Buffered and durable startup now share the metadata reads and blank-media scan. Buffered detection on blank media of at least three pages avoids rereading both slot pages (8 KiB). For one- or two-page media both modes reuse page zero, and zero-capacity devices stop before a page read. All existing pages must still be full and zero before fresh formatting. The Portable durability fixture typechecked. Startup execution is deferred.

Indexed replay now gathers payloads in order and performs at most one final join, removing repeated copies of the growing prefix. Sequential and indexed replay directly return a sole part. The fixture typecheck exposed a helper-name collision. The new helper was renamed after that check and awaits qualification.

The legacy tuple-index latest lookup carries the last matching page and size through the scan and reads only the winning payload. Superseded payload reads and their intermediate results are eliminated. The Portable durability fixture typechecked with this change and the preceding replay-helper rename. Runtime I/O counts remain unmeasured.

The v1 tuple-index scanner prepends each ordinary entry and restores chronological order once at termination, including early termination at an invalid header. For an append-only log this makes list construction linear. The initial typecheck identified a string-specific reversal helper. The scanner now uses a typed tuple reversal, pending the next check.

Storage-actor statistics and legacy tuple-index counts now accumulate matching entries in tail position, removing deferred additions on the return path. Both still scan every entry. The Portable durability fixture typechecked, including the preceding typed tuple reversal. Stack usage and latency remain unmeasured.

FP-RISC binary strcat now reuses canonical empty and one-byte results when either operand is empty. Longer static operands can be returned directly; longer heap operands still receive an independent copy to preserve borrowed-input lifetimes. The two-nonempty allocation checks combined size before allocating. The runtime passed a host C syntax check. Allocation counts and timing remain unmeasured.

Tuple-based string interpolation now sizes tagged integers by decimal width, avoiding the first rendering pass for each such field. The width calculation passed a standalone comparison with snprintf at sign and digit boundaries and the host word extrema. End-to-end interpolation timing remains unmeasured.

Tagged integers in tuple interpolation now write decimal digits directly into the final string. Standalone integer str conversion also bypasses the render buffer and snapshot copy, and returns a static one-byte string for 0 through 9. The runtime passed a host C syntax check. Output equivalence and timing for the new writer remain pending.

Ordinary machine-word decimal rendering now checks the available render-buffer space once and writes digits directly into it. A focused host check matched the shared decimal writer against snprintf for twelve values including signed-word extrema, zero and decimal boundaries. End-to-end timing remains deferred.

Rendering nested strings, literal text and raw floating-point fields now uses a bounded bulk copy into the per-hart buffer. A string field of N bytes needs one capacity check instead of N, and the explicit byte length preserves embedded zero bytes. Runtime C syntax passed. End-to-end rendering and latency qualification remain deferred.

Record field names and formatted boxed floating-point and signed integer values now copy each completed text span into the render buffer with one capacity check. The runtime passed a host C syntax check. Output and timing qualification remain deferred.

POSIX console output now writes each newline-delimited span with fwrite while preserving the newline flush. Runtime print and UART rendering use the span hook. Boards using the default implementation retain their hal_putc device behavior. Both C sources passed a host syntax check; console throughput remains unmeasured.

Log staging now bulk-copies the payload. Console echo emits the prefix, payload and newline as spans, cutting POSIX stderr forwarding from a stdout flush per byte to at most three flush calls per ordinary warning or error. The host syntax check found a duplicate fallback definition, which was removed afterward. Corrected linkage and runtime output remain unverified.

Empty log drains with no drops reuse an immutable result and empty list, removing two result allocations. Nonempty drains reuse the same list terminator and snapshot staged bytes with memcpy under the log lock. The host syntax check found another duplicate diagnostic fallback beside the early praw declaration. That definition was removed after the check. Build and drain behavior remain pending.

Allocator growth-log reads reuse the immutable empty-list terminator, saving one allocation per snapshot. An initial sequence mismatch skips the entry copy and second sequence load. The host C syntax check passed for the runtime and POSIX console, including the corrected diagnostic fallback. Concurrent log behavior and timing remain deferred.

Each successful allocator growth now reserves its diagnostic ring slot using the previous value of the existing atomic growth counter. This removes one global atomic increment per grant. The per-slot release publication and acquire observation still govern event visibility. Runtime C syntax passed. Multi-hart timing and ring stress remain deferred.

Sys.memInfo shares the immutable list terminator, reducing each eight-field snapshot from nine allocations to eight. Its list cells and the Sys.memStats tuple now request the actual two-field object size on both word widths. Host runtime C syntax passed. Target allocation and timing measurements are deferred.

Actor-info and stack-stat snapshots now share the runtime empty-list terminator. Four-field results require four allocations and missing actor results require none. Actor and log list cells request a header plus two target words, saving eight requested bytes per cell on 32-bit targets. Both runtime translation units passed a host syntax check. Target allocator measurements remain deferred.

FP-RISC process cleanup and both QOS loader paths now stop the actor-ledger scan at the first process actor that is live or still running on a hart. Negative quiescence results still examine the full ledger and the count API remains available. Negative actor-info indices return immediately. The actor runtime passed a host syntax check. Loader linkage and concurrent teardown remain deferred.

Process-policy lookup now returns immediately after its first ledger traversal when the requested PID has no live actors. This avoids reserving and retiring a policy record and scanning the ledger again for an absent or exited process. The existing second pass still handles actors that exit during policy creation. Host C syntax passed; concurrent process lifecycle testing is deferred.

Confinement failures that attached no actor skip the rollback traversal, eliminating one full ledger scan for a missing PID or a process whose live actors all already have policies. Partially attached failures still roll back. Kill reasons now use a bounded bulk copy. Actor runtime C syntax passed. Concurrent lifecycle behavior remains deferred.

On process-policy pool growth, the runtime builds the new block of records privately and reserves the requesting PID’s record before linking the block into the shared list. Publication now holds the pool lock for two pointer updates and avoids reacquiring it to find a free record. The actor runtime passed a host syntax check. Multi-hart contention remains unmeasured.

Policy allocation resumes its search after the last reservation. Sequential reservations from a new block now inspect one candidate each while unused records remain. The search wraps once to include earlier reusable records before growing the pool. The actor runtime passed a host syntax check. Concurrent reuse and contention remain unmeasured.

Process memory charging now compares the requested block size with the remaining budget before publishing a reservation. Over-budget requests avoid the previous atomic increment and rollback, and peers cannot observe a provisional over-budget charge. Competing successful reservations retry on a changed balance. Host C syntax passed. Contention and budget-boundary execution remain deferred.

Counted buddy grants now compute usable block size once and pass it to process-budget charging. Successful charged grants avoid a second size lookup, while rejected grants still return a null pointer and zero size. Standalone charging callers retain lazy size lookup. Both runtime C sources passed a host syntax check. Execution and timing remain deferred.

Cold actor stacks and newly allocated growth segments now reuse their usable block size for budget charging and guard bounds. Each successful charged stack allocation avoids one buddy size lookup. Already-guarded warm stacks and spare segments keep their existing paths. Actor runtime C syntax passed. Guard and budget behavior remain pending execution.

Under allocation pressure, cache flush now detaches each hart’s blocks under its cache lock and removes stack guards after unlocking, before returning blocks to the buddy. Cached-byte accounting uses one atomic subtraction per nonempty hart cache instead of one per block. Actor runtime C syntax passed. Pressure and concurrent cache execution remain deferred.

Cached-byte accounting is now computed when Sys.memInfo requests it by inspecting each hart cache under its existing lock. Ordinary and warm cache takes, puts and pressure drains no longer update a shared byte counter. A statistics read pays a bounded traversal per hart and its total is a rolling snapshot. Actor runtime C syntax passed. Concurrent accounting and timing remain unmeasured.

Empty cache probes now read occupancy atomically while another hart may drain it. Slot ownership still transfers under the cache lock. A drain clears each nonempty bucket count once, replacing a shared count write per removed block. The actor runtime passed a host syntax check. Concurrent pressure testing remains deferred.

Returning a block to a full ordinary or guarded-stack cache now bypasses the cache lock using the atomic occupancy hint. A concurrent drain can make space after the hint, in which case the caller follows its usual uncached return path. Admission still checks capacity under the lock. Host C syntax passed; contention and hit-rate effects remain unmeasured.

Buddy size-class lookup now returns immediately for minimum-size blocks and uses bit width for larger requests, replacing the doubling loop in allocation, reallocation and cache probes. Requests whose header would overflow the word are rejected. A focused host check passed at all 25 configured order boundaries and at the maximum word value. Target timing remains unmeasured.

Range release now uses the same aligned power-of-two decomposition as reservation. Each maximal span is freed once, replacing a separate allocator lock and coalescing pass per minimum-size unit. An aligned 1 GiB range with a supported 1 GiB order and 64 KiB minimum needs one free instead of 16,384. The buddy source passed host syntax checking; range lifecycle and host page-release effects remain untested.

Buddy free-space reporting now reads a byte total under the existing allocator lock. Allocation, release, range reservation and resize update that total as blocks change ownership. A host lifecycle test passed across allocation, in-place growth, shrink, free and a three-unit range reserve/release. Contended timing and partial-growth failure paths remain unmeasured.

Blocking and try-lock buddy allocations now reject requests whose rounded block exceeds total free bytes before searching size classes. Both paths share the same locked allocation logic. A focused host test exhausted the arena through normal allocation, observed exhaustion without a busy indication on try-allocation, then freed and reused the arena. Fragmented-arena timing remains unmeasured.

Under pressure, each hart returns its detached, untagged cache blocks to the buddy allocator in one bounded batch. This takes the buddy lock once per nonempty cache instead of once per block. Guard removal still precedes the return, outside the cache lock. Actor and buddy sources passed host syntax checking. Concurrent pressure behavior remains unverified.

The memory actor now skips a queued allocation whose requester has already cancelled. This avoids allocating and immediately freeing the block, or draining caches for a cancelled request under pressure. Cancellation after the initial check still uses the existing reply CAS and cleanup. The actor source passed host syntax checking. Cancellation timing remains pending execution.

Blocking receive, receiveNow and the memory actor now share a round-robin channel lookup that skips the unused suffix of dedicated sender slots. It still visits the shared ring and wraps to earlier channels. Host C syntax passed. Multi-sender fairness and wakeup execution remain deferred.

Selective result receive skips the unused suffix of dedicated sender slots while retaining the existing scan cursor and shared-ring position. A focused ordering model matched the full scan for all 128 combinations of cursor, contiguous dedicated-slot occupancy and shared-slot use. Concurrent publication and wakeup behavior remain untested.

Deferred slab holds now replace the oldest entry in a full 16-slot borrow window using a rotating index. This removes 15 pointer moves per overflow. Draining still releases all occupied slots in one locked batch and resets the index. The actor runtime passed host C syntax checking. Wrapped-window lifetime behavior remains pending execution.

Deferred-release draining groups consecutive holds on the same slab. A run of N references now subtracts N from the hold count once and evaluates release eligibility once under the existing ARC lock. Nonadjacent references remain separate. The runtime passed host C syntax checking. Duplicate-hold lifetimes and lock timing await execution.

Immediate integer and null message copies return before fetching hart state or writing the destination PID in ordinary builds. Instrumented builds still count the call. Actor-entry copies restore their destination PID on the current hart after a slab allocation that may park. The cost-probe runtime passed host C syntax checking. Migration behavior and timing remain untested.

Inline mailbox eligibility now compares static field ownership directly with the destination PID, removing the save, temporary write and restore of per-hart copy state. Generic image checks also skip hart lookup for unowned addresses. Runtime C syntax passed. Cross-image message transfer and timing remain untested.

Image-count queries read a count maintained under the registry lock. Registering or removing an image now updates each affected bitmap byte once, masking partial bytes to retain neighboring ownership bits. Eight aligned units need one atomic bitmap update. Runtime C syntax passed. Concurrent image lifecycle and boundary tests remain deferred.

Image bitmap writers, serialized by img_lock, now publish bytes with release stores. Fully covered bytes need no original-value load and partial bytes retain neighboring bits with a relaxed load. A focused host test of the implementation matched a bit-by-bit reference for all 650 add/remove cases over a patterned three-byte map. Concurrent reader timing remains unmeasured.

Process-image adoption and message ownership checks share a last-image lookup under the existing registry lock. Consecutive addresses in that image skip the list walk. Removal clears the cached pointer under the same lock before the loader can reclaim the image. Host C syntax passed. Concurrent unload and locality effects remain unmeasured.

Repeated successful process-ID lookups now reuse the first matching image under the registry lock. Registration and adoption invalidate that lookup, and removal clears it before the cached record can be reclaimed. The host runtime passed C syntax checking. Loader lifecycle and hit-rate measurements remain pending.

Image-count queries now use one acquire load without taking the registry lock. Serialized writers publish the updated count after list and bitmap changes. Removing an absent record leaves the bitmap intact. Host runtime syntax checking passed. Concurrent observation and timing remain untested.

Portable block jobs now initialize job metadata separately from the transfer buffer. Reads leave the destination for the worker to fill, while writes zero only header and trailing padding. A full eight-page transfer no longer requests pre-zeroing of 32 KiB before overwriting it. Host C syntax passed. Device readback and throughput remain deferred.

Portable block-job references now use release ordering on each decrement and acquire synchronization only on the final release before free. The nonfinal caller or worker release no longer requests acquire ordering. The existing idle-worker signal already avoids signaling during active I/O. Host C syntax passed. Cancellation races and target instruction counts remain unverified.

When another disk job is already queued, the Portable worker claims its next FIFO batch under the same mutex acquisition that retires the previous batch. This saves one queue lock/unlock pair per backlogged handoff. Reply publication and reference release remain outside the mutex and precede execution of the next batch. The next deadline starts at claim. Host C syntax passed. Backlog and timeout execution remain deferred.

Empty single-page writes now use one immutable zero page in the Portable backend. A queued empty write allocates only job metadata, saving a 4 KiB buffer and its zero fill. The direct path also skips building a padded page. Both still submit a full page to disk. Host C syntax passed. Readback and timing remain deferred.

Portable short single-page writes now submit the payload and zero padding with vectored I/O. Queued short writes allocate space for the payload length, saving 4096 minus the payload length in requested buffer bytes per job. The disk still receives the full page. Host C syntax checking passed. Short-write readback and timing remain unverified.

Portable record jobs now copy only the header and payload into worker-owned storage. A vectored write inserts shared zero padding after each span and advances across spans on a partial write. Requested transfer-buffer savings per record equal the unused header-page bytes plus the unused bytes in the final payload page. The on-disk page count and flush protocol are unchanged. Host C syntax passed. Record readback and crash qualification remain deferred.

Portable block completion polling now uses a relaxed load while work is pending. Observing completion executes an acquire fence paired with the worker's release store before reading results or data. The worker keeps its batch result local until publication. Host C syntax passed. Poll latency and the cost of the successful-poll fence remain unmeasured.

Adjacent Portable flush submissions now share the pending FIFO tail's job and completion flag. Each caller owns a reference and consumes one of the 64 admission slots until the worker finishes. A group of N queued flushes uses one allocation and one completion publication, saving N−1 of each over worker-side batching alone. A claimed flush is no longer eligible for joining. Host C syntax passed. Concurrent abandonment and shared failure delivery await qualification.

The focused host flush check now intercepts vectored short writes and verifies that two queued flushes share a handle. Releasing one caller before the preceding write finishes still lets the other caller observe successful completion. The check passed on the fsync backend, including FIFO ordering, injected errors, interrupted sync, admission limits and stall recovery. macOS full-device flush and power-loss behavior were outside this check.

Portable jobs now encode pending state in the result word. The worker publishes the final result with one release store, and result collection loads that word once before reading any payload. This removes the separate completion field and its store while keeping direct result calls safe. The focused host flush check passed. Target timing remains unmeasured.

When a Portable disk job has completed by the actor's first poll, the actor now collects it without registering and clearing a cancellation callback or reading the deadline clock. Jobs that require a sleep register cleanup before yielding and check completion before the deadline on wake. Host syntax checking produced no diagnostics. The immediate-completion rate and actor cancellation behavior remain unmeasured.

The focused host check forced 4,094-byte partial writes of an 8,192-byte record over existing nonzero bytes. Readback matched the submitted header, original payload, and zero padding across both pages after the caller modified its input. The check passed in under one second.

The virtio block driver tracks the known-zero suffix of its first staging page under the disk lock. Consecutive equal-size short writes and record headers skip padding clears. A shorter write clears only the newly exposed bytes. Every device read invalidates the bound before DMA. Host syntax passed. Native execution and transfer timing remain pending.

Virtio record payload staging now remembers an interval already known to contain zeros. It copies the submitted payload and clears only final-page padding outside that interval. A multi-page read removes its DMA destination from the remembered interval before submission. A repeated 512-byte payload can skip all 3,584 padding bytes. Host C syntax passed. Native readback and timing are pending.

Virtio queue setup now initializes the fixed block descriptor addresses, lengths and links at boot and reset. A read or write updates three descriptor fields per submission, down from twelve. A flush updates one. The available ring always names head zero, so advancing its index no longer rewrites the slot. Host syntax passed. Native boot, reset recovery and throughput remain pending.

The virtio completion loop now snapshots the active deadline once per submitted request and computes its tick and fallback park limits once. Incomplete polls no longer reload the active deadline or reset-probe settings. This adds one deadline load for a request already complete at its first poll. Host C syntax passed. The latency tradeoff and native timeout behavior await qualification.

Virtio now checks the used index before calculating deadline limits. Immediate completions skip the active-deadline load and pending requests snapshot it once. The driver also drops a write-only shadow of the used index, removing one volatile ring read on normal completion. Host C syntax passed. Native completion and reset behavior remain unqualified.

An uncontended virtio disk claim now skips the preliminary ownership load, waiting-budget snapshot and wait-start clock read. Contention starts the wait deadline at the first failed claim and computes its limits once. A successful claimant still publishes the active request budget and registers abandonment cleanup. Host syntax passed. Native contention and recovery testing remain deferred.

An incomplete orphan observation now reads its active deadline once to derive both timeout limits, down from two deadline and two reset-probe loads. Completed observations skip those setting reads. Reset execution loads only its probe count. Host C syntax passed. Stalled-device recovery remains untested on the target.

Virtio probe now records disk capacity in whole pages once. Single-page requests use that value directly, and range reads and record writes compare against its full unsigned width without converting through a tagged language integer. Host syntax passed. Large-capacity behavior on RV32 and target timing remain unverified.

Portable range reads and record writes now validate bounds against the host's 64-bit capacity directly after the operation's confinement check. This removes a second confinement check and capacity tagging from each call. A missing read capability is detected before allocating the range result, which can hold up to 32 KiB. Host syntax passed. Capability-denial and large-disk execution remain deferred.

Adjacent identical Portable reads now share the queued worker job, immutable result buffer and device read. Matching requires the same operation, starting page and length at the pending FIFO tail. Each caller retains its own reference and admission slot. This saves one transfer and one 4–32 KiB worker buffer per joined caller. The existing host flush and queue-bound check passed, including abandonment of queued duplicate reads. Multi-caller byte readback and throughput remain unmeasured.

The host readback check now queues two matching two-page reads, a write to the first page, and a third read. Both early callers shared a job and retrieved the exact original 8 KiB after the write completed. The third read used a separate job and returned the updated first page and original second page. The focused check passed in under one second.

Portable single-page reads now use the same internal request as a one-page range read after argument validation. Adjacent requests through either API share one pending transfer and one 4 KiB buffer for the same page. The focused host test confirmed that both calls acquired the same queued job and released their references independently.

Portable block jobs now initialize individual metadata fields during allocation. Writes and record submissions prepare their queue links, references and operation metadata before locking. New read and flush jobs skip a whole-header zero fill under the mutex. The host queue and readback test passed. Lock-hold time remains unmeasured.

The Portable worker now uses its completion lock acquisition to claim the next job or enter the idle condition wait. An empty queue no longer causes an unlock followed immediately by a relock. Result publication and worker-reference release now occur under the mutex, so a final free can extend that critical section. The focused host queue and readback test passed. Net contention and wakeup latency remain unmeasured.

With a backlog, the Portable worker now publishes the completed result, claims the next job under the same queue lock, and releases the previous worker reference after unlocking. This moves any resulting free outside the backlog handoff critical section. An empty queue still releases immediately before waiting. The focused host test passed. Contention impact remains unmeasured.

A full Portable queue now rejects a submission before reading the monotonic clock under its mutex. This removes one clock read per capacity refusal. Write preparation still occurs before admission. The focused host check passed, including refusal of the 65th request and recovery after draining.

Portable writes and records now sample the admission count before allocating. Observing a full queue skips job allocation, input copying and queue locking. A submission that sees space still checks admission under the mutex after preparing its owned input. This adds one relaxed load on the normal write path. The focused host check passed, including full-queue write refusal.

A Portable record with a full header page and page-aligned payload now writes its contiguous worker buffer directly. This skips constructing and submitting four vector entries. The focused host check read back all 8 KiB of a two-page full record successfully. Device byte count is unchanged and timing remains unmeasured.

Header-only Portable records now use the single-page write path. Short headers use two vector entries instead of four, and an empty header writes the shared zero page directly. A focused host readback verified a one-byte header, its zero padding and the neighboring page after forced partial writes.

Portable vectored writes now return as soon as the host reports the remaining transfer complete. Only a short write needs to walk the vector and advance its cursor. The focused host queue test passed, including readback after forced partial record writes. Target timing remains unmeasured.
