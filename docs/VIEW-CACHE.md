# Explicit per-session view caching

This is component memoization, not a model, response, or process-wide cache.
`std/viewcache` reuses rendered fragments only when both their stable key and
complete input value match. It compares values directly, not hashes or object
addresses. The component renderer must be pure and must read all variable
inputs from its argument. The compiler does not currently prove this contract.

## API and ownership

- `empty Unit` creates a typed `Cache input` seed.
- `begin version verify cache` starts a render. A different version discards
  the previous cache. The current render begins empty.
- `item key input renderer frame` returns `(fragment, nextFrame)`.
- `many keyOf renderer inputs frame` preserves input order and threads the frame.
- `finish frame` keeps only entries used in THIS render; off-page/removed
  components are evicted. Only the last input/output per key survives.
- `stats frame` reports `(hits, misses, retainedEntries)`; `size cache` reports
  retained entries. Duplicate keys in one frame are errors.

Use one renderer and input type per cache namespace. If its implementation or
constant rendering configuration changes without discarding the session,
change `version`. Different component kinds should have separate typed caches.
Inputs should be immutable data, not function values or mutable foreign handles.
Every variable dependency (entry content, edit state, locale, permissions, etc.)
belongs in the input. Keys alone never authorize cache reuse.

`Live.serveCached cfg app` expects `app.cache` as an empty immutable seed and:

```text
view : Int -> model -> cache -> ((List String, List String), cache)
```

The session ID is the first argument. Each writer actor owns its own evolving
cache. The register's shared model never owns those caches. Outputs and the next
cache are retained with `keep` before dropping the model reply, and are included
in the writer's normal tidy boundary. Ending the session releases its actor
state; reconnect begins from the empty seed. POSIX reload replaces the process
and likewise starts cold. This does not change the older QOS plugin driver's
reload contract.

`Live.serve` remains compatible: it adapts the old stateless view to this path
with a Unit cache. No wire protocol changes are introduced by memoization.

## Fragment composition

A cached output contains local static/dynamic arrays plus the component's CSS
classes. `View.Fragment` composes those arrays into the parent's render context;
it never retains global slot numbers or DOM references. Reordering/inserting
components assigns slots anew, and the existing v2 patches transmit the result.
CSS collection also traverses fragments, so cached and fresh class inventories
agree. Apply `View.key` to the element inside the renderer before caching it.

## Logbook and verification

Logbook caches at most its visible page of 20 entry cards per session. Its
`CardInput` is the entire Entry record plus an editing Bool. Query and page
select the inputs; they are not hidden dependencies of the card renderer. The
outer layout and filtering are recomputed, including the online count and toast.

Set `FPR_VIEW_VERIFY=1` before launching logbook. Every cache hit is rerendered
and compared with the cached arrays/classes. The assembled page is also compared
with the original uncached view. A mismatch fails loudly with a cache diagnostic.
This mode intentionally gives up performance to detect incomplete dependencies
and composition errors. It tests exercised cases; it is not a purity proof.

Run `python3 tests/check_viewcache.py` with the existing compiler binary built.
The test builds its own programs and runs disposable servers/stores. It covers:

- cold misses and a hit that must NOT call the supplied renderer;
- text/edit-state invalidation and reordered/inserted fragments;
- eviction, empty pages, version changes and independent cache seeds;
- exact cached/fresh render and CSS equality;
- deliberately stale renderer and duplicate-key rejection;
- logbook in both normal and verification modes, plus 25 entries across
  pagination, searches, concurrent sessions, edits and reconnects.

## Costs and remaining work

This saves component tree construction, markup generation and escaping on hits.
It still compares inputs, assembles the whole page, compares rendered arrays,
and copies retained state according to the runtime's ownership rules. It adds
per-session memory for inputs and fragments. No end-to-end speedup or heap-usage
bound is claimed from the functional tests. Rendering performance and long-run
memory measurements should precede broader adoption. There is no TTL or manual
per-entry invalidation API; freshness comes from explicit values and versions.
