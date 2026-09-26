# Preliminary Base library design

**Date:** 19 September 2026  
**Status:** planning proposal; not an approved specification or implementation inventory.  
**Scope:** FP-RISC Base for applications/systems programming, Sol for scripting,
scientific programming and interactive use, and their shared ExtBase libraries.

This document captures the proposed API from the library-design discussion. Names,
module boundaries and signatures are candidates. Examples are schematic, not
necessarily accepted by the current compiler. Inclusion here does not imply that
an operation exists or is supported by the current BareMetal ARC subset.

## 1. Purpose and design direction

Provide a small, coherent library that makes ordinary programs directly writable.
The initial target is roughly the most important 80% of everyday work. That is a
planning heuristic, not a measured coverage claim or a requirement to find the
perfect inventory before implementation.

The intended influences are the explicit module organization of Standard ML, the
approachable data APIs of Elm, and the practical concurrency/system orientation
of Erlang. FP-RISC need not copy Haskell's library structure or reproduce any of
these languages' exact APIs.

Choose representative programs, provide the operations they need, and use repeated
helpers and awkward workarounds as evidence for the next additions. Ecosystem
usage research can inform choices between concrete candidates without becoming
a prerequisite for every decision.

Principles:

- Use one vocabulary across profiles wherever operations have the same meaning.
- Supply composable foundations and convenient complete operations for common tasks.
- Make ownership, failure and effects explicit enough to reason about.
- Keep raw systems access available without making it the default application API.
- Allow scripts to start with flexible data and progressively introduce records
  and validation.
- Prefer a small set of useful standard algorithms/protocols over exhaustive lists.
- Do not equate library membership with purity, totality, bounded cost or safety.
- Do not make a type fundamental language machinery merely because it is prominent
  in the standard library.

## 2. Proposed organization

| Layer | Purpose | Initial scope |
| --- | --- | --- |
| Builtin | Minimal language and execution primitives | Fundamental values/operations and primitive ownership/effect mechanisms |
| Base | Everyday values, transformations and minimal environmental interaction | Text, bytes, collections, sorting, basic parsing, files/streams, memory and concurrency interfaces |
| ExtBase | Complete common application tasks | JSON, configuration, HTTP/TCP, hashing, encodings, logging and task helpers |
| Profile prelude | Select convenient defaults | Base emphasizes explicit resources; Sol emphasizes data, automation and exploration |
| Additional standard packages | Larger domains with explicit imports | Plotting, richer numerical algorithms, GUI widgets and supervision helpers |

**ExtBase** is the provisional spelling in this document; BaseExt has also been
used in discussion. Final naming is still open. These categories do not settle
the older Core/Std source-directory or verification-tier proposals.

Base and Sol should share ordinary value semantics and API names. Profiles can
supply different operational mechanisms, but differences in transactions,
ownership, scheduling or externally observable effects must be documented rather
than hidden behind apparently identical calls.

Base's OS-facing interfaces require a supporting execution environment. Their
inclusion does not require BareMetal–Builtin to provide files, processes or a
network stack. QOS may implement those contracts, but should not be the only
possible implementation.

Related policy: [2026-09-16-PLATFORM.md](2026-09-16-PLATFORM.md). This proposal refines candidates; it
does not declare conformance to a completed Base specification.

## 3. Signature conventions

The examples use `Result value error`, with the successful value first. `Option`
represents ordinary absence, while `Result` represents an operation that can fail.
`Ordering` has less-than, equal and greater-than outcomes.

Signatures mostly show value types. They do not introduce a finished effect system,
borrowing syntax, module syntax or type-class hierarchy. Higher-order operations
are intended library goals even where current compiler/runtime subsets cannot yet
support their ownership behavior.

Collection updates are written as transformations returning a collection. Whether
an implementation reuses uniquely owned storage must follow the eventual ownership
contract; the spelling alone does not permit mutation visible through aliases.

## 4. Shared foundation

Both profiles should expose the following modules with consistent meanings.

| Module | Candidate operations |
| --- | --- |
| `Bool` | `not`; short-circuit control remains distinct from strict function application |
| `Int`, `Word`, `F32`, `F64` | Arithmetic, comparison, conversion, parsing and formatting |
| `Math` | `abs`, `min`, `max`, `clamp`, `sqrt`, `pow`, `sin`, `cos`, `log`, `exp` |
| `Option` | `map`, `andThen`, `withDefault`, `toResult` |
| `Result` | `map`, `mapError`, `andThen`, `collect` |
| `String` | `split`, `join`, `trim`, `replace`, `startsWith`, `contains`, UTF-8 conversion |
| `Bytes` | `length`, `slice`, `concat`, encoding/decoding |
| `List` | `map`, `filter`, `fold`, `find`, `take`, `drop`, `zip`, `indexed`, `sortWith`, `sortBy` |
| `Vector` | Construction, indexed access, traversal, updates and slicing |
| `Map`, `Set` | Construction, lookup, insertion, removal, traversal and combination |

```text
String.split  : String -> String -> List String
String.join   : String -> List String -> String
Int.parse     : String -> Result Int ParseError

List.map      : (a -> b) -> List a -> List b
List.fold     : (b -> a -> b) -> b -> List a -> b
List.find     : (a -> Bool) -> List a -> Option a
List.sortWith : (a -> a -> Ordering) -> List a -> List a

Map.get       : k -> Map k v -> Option v
Map.insert    : k -> v -> Map k v -> Map k v
Map.remove    : k -> Map k v -> Map k v
Map.entries   : Map k v -> List (k, v)
```

For ordering and key equality, begin with explicit functions or the existing
signature/structure mechanism. The map signatures omit those requirements for
readability; a real implementation must specify how keys are compared or hashed.
There is no requirement to introduce a large type-class hierarchy first.

Contracts to decide early:

- Whether sorting is stable; stable sorting is the proposed default.
- Whether map iteration is deterministic and what ordering, if any, it promises.
- Integer widths, overflow behavior and checked conversions.
- String indexing units, slice boundaries and invalid UTF-8 behavior.
- Bounds errors for indexed storage and empty-collection behavior.
- Whether slices copy, share immutable storage or borrow an owned buffer.

Use one canonical public name for each concept. `String` is used provisionally
here; migration from existing `Str` APIs needs a deliberate compatibility decision.

## 5. Base: applications and systems programming

Base should support ordinary programs without requiring QOS-specific service names.
Implementations can route these contracts through QOS, a host OS or another suitable
runtime.

| Area | Types | Candidate operations |
| --- | --- | --- |
| Program environment | `Arguments`, `ExitCode` | `Program.args`, `env`, `exit` |
| Console | Text/byte streams | `Console.readLine`, `write`, `writeError` |
| Files | `Path`, `File`, `OpenMode`, `FileInfo` | `File.open`, `read`, `write`, `seek`, `close`, `info` |
| Directories | Directory entries | `Directory.list`, `create`, `remove` |
| Time | Monotonic instant, `Duration` | `Clock.monotonic`, `sleep` |
| Memory | `Buffer`, `Addr`, `Layout` | `Buffer.alloc`, `resize`, `read`, `write`, `free` |
| Binary data | `Endian`, readers/writers | `Binary.readU32`, `writeU32`, `readF64` |
| Concurrency | `Actor msg`, `Mailbox msg` | `Actor.spawn`, `send`, `receive`, `receiveWithin` |
| Synchronization | Atomic values | `Atomic.load`, `store`, `exchange`, `compareExchange` |

### Memory and ownership

Owned buffers should be the normal systems-level storage API. Arbitrary address
operations remain available through an explicitly unsafe interface.

```text
Buffer.alloc  : Int -> Result Buffer AllocError

Mem.read8     : Addr -> Int
Mem.readWord  : Addr -> Word
Mem.write8    : Addr -> Int -> Unit
Mem.writeWord : Addr -> Word -> Unit
```

These raw memory signatures reflect the existing machine API shape. Address
validity, access permissions, alignment and lifetime remain caller obligations
except where the implementation explicitly checks them. An `Addr` is not ownership
of its pointee.

A possible linear file interface is:

```text
File.read  : Int -> File -> (File, Result Bytes IOError)
File.write : Bytes -> File -> (File, Result Unit IOError)
File.close : File -> Result Unit IOError
```

An ordinary read/write error returns the resource handle rather than losing
ownership. The final contract must distinguish EOF, partial progress, a permanently
unusable resource and recoverable failure. Close consumes the handle; error reporting
must not imply that retrying close is always valid.

Scoped helpers can make resource use concise once their borrowing and cleanup
contracts are settled. Base should not require applications to repeat manual
cleanup code at every return path.

### Concurrency and machine-specific operations

Typed message passing can be standard without requiring an entire supervision
framework in minimal Base. Decide per-sender ordering, mailbox capacity and
backpressure, send failure, cancellation and timeout semantics before fixing
signatures.

Target-specific instructions belong in target modules, for example `CPU.RiscV`.
They should not become mandatory operations on every Base platform. Precise atomic
memory ordering also needs its own contract.

## 6. Sol: automation and flexible data

Sol inherits the common vocabulary but makes the following tools prominent:

```text
String, List, Map, Set, Option, Result
Path, File, Directory, Program, Proc
Value, Decode, Encode
Array, Math, Stats
```

Prominent need not mean every function is unqualified. A small prelude can expose
common types while keeping operations grouped under recognizable modules.

### Maps, external values and records

Use `Map` as the canonical collection name rather than competing Map/Dictionary
APIs. Sol can provide convenient literals for string-keyed maps without introducing
a different collection model.

`Map String String` fits environment variables and simple textual configuration.
Nested or heterogeneous data needs a representation that preserves its types:

```text
Value =
    Null
  | Boolean Bool
  | Integer Int
  | Real F64
  | Text String
  | Sequence (List Value)
  | Object (Map String Value)

Decode.value  : Decoder a -> Value -> Result a DecodeError
Decode.fields : Decoder a -> Map String String -> Result a DecodeError
```

The proposed path is:

```text
external data -> map or Value -> decode/validate -> typed record
```

A decoder should support required/optional fields, defaults, conversion and
validation. Errors should identify the field or nested path and explain the
failure. Flexible data is useful at boundaries; users should be able to add
structure without rewriting the whole program.

### File and process automation

Candidate conveniences:

```text
Path.join              Path.extension       Path.withExtension
Directory.walk         Directory.glob
File.readText          File.readBytes       File.lines
File.writeText         File.writeBytes
Proc.query             Proc.afterCommit     Proc.runNow
Proc.pipeline
```

Process descriptions should carry executable, argument list, working directory,
environment, input and timeout. Standard output, standard error and exit status
remain distinct. Shell parsing should be an explicit operation, not an implicit
interpretation of an argument list.

Retain the execution distinctions in the current [transaction model](2026-08-25-TRANSACTION.md):

- `Proc.query` is intended for read-only queries and can execute again on retry.
- `Proc.afterCommit` queues execution with the documented commit/recovery contract.
- `Proc.runNow` is an explicit immediate escape, subject to the existing ordering
  restrictions and outside rollback guarantees.

These names do not prove that an arbitrary subprocess is read-only or can run
exactly once. Pipelines need the same explicit effect classification. Network
requests, interactive input and external displays likewise need documented
transaction/retry behavior; they cannot silently inherit file-journal guarantees.

## 7. Sol: scientific and interactive programming

Begin with dense numerical arrays and useful analysis operations. A complete
dataframe system is not a prerequisite for the first usable release.

| Module | Candidate operations |
| --- | --- |
| `Array` | `fromList`, `shape`, `reshape`, `slice`, `map`, `zipWith`, `reduce`, `sum`, `min`, `max` |
| `Linear` | `dot`, `matmul`, `transpose`, `solve` |
| `Stats` | `mean`, `variance`, `stddev`, `quantile`, `histogram`, `correlation` |
| `Random` | Generators, seeds, `uniform`, `normal`, `sample`, `shuffle` |
| `CSV` | Read/write rows, headers and typed decoding |
| `Plot` | `line`, `scatter`, `histogram`, `heatmap`, `save` |
| `Display` | `show`, `table`, `image` |
| `Inspect` | `typeOf`, `describe`, `help` |

```text
Linear.solve : Array F64 -> Array F64 -> Result (Array F64) LinearError
Stats.mean   : Array F64 -> Option F64

Random.normal : Int -> Generator -> (Array F64, Generator)
```

Array rank and shape are explicit runtime properties in this first sketch; the
notation does not require dependent shape types. Initially avoid implicit
broadcasting. Add it only after deciding clear rules from actual use cases.

Specify shape errors, empty data, singular systems, missing/non-finite values,
sample versus population statistics, and copying versus shared views. Seeded
random generators support reproducible experiments; interactive conveniences may
supply a session generator. Statistical randomness and security-sensitive random
bytes need distinct contracts.

`Vector` is the general indexed collection; `Array` is a candidate numerical
interface for shaped storage. Whether they share implementation or become one
public abstraction remains open.

Plotting and richer numerical routines can be standard, separately importable
packages. Interactive display requires a supported frontend and must have an
explicit behavior when one is unavailable.

## 8. ExtBase: complete application facilities

Both profiles should be able to import these facilities where supported:

| Family | Initial commitment |
| --- | --- |
| `JSON`, `Decode`, `Encode` | Parse, validate, construct and serialize structured data |
| `HTTP`, `TCP` | Requests/responses, connections, streaming, timeouts and cancellation |
| `Digest` | SHA-256 candidate, incremental hashing and file-digest conveniences |
| `Encoding` | UTF-8, hexadecimal, Base64 and URL encoding |
| `Time` | Wall-clock timestamps, parsing and formatting |
| `Log` | Structured events, levels and configurable destinations |
| `Config` | Combine defaults, files, environment and arguments |
| `Task` / actor helpers | Parallel work, cancellation and bounded worker groups |

A usable HTTP offering should cover HTTPS, with a defined TLS/certificate-validation
contract. A convenient request API should coexist with explicit request/response
values and streaming access. Exposing TCP alone does not fulfill the HTTP use case.

Keep collection hashing, checksums, cryptographic digests and password hashing
separate. An API named `hash` should not ambiguously stand for all four. Algorithm
selection is provisional; compatibility algorithms require a concrete use case
rather than admission solely because they have historically been popular.

Examples of the intended convenience/composition pairing:

| Common task | Convenient operation | Underlying composition |
| --- | --- | --- |
| Sort records | Sort by a selected key | Comparator-based sorting |
| Download structured data | HTTP request plus decoding | Requests, responses, byte streams and decoders |
| Hash a file | File-digest helper | Incremental byte hashing |
| Read configuration | Decode directly into a record | Field decoders, defaults and validation errors |
| Run a tool | Capture output and exit status | Process descriptions and explicit stream handling |

## 9. First-release acceptance examples

Use three complete programs to establish the first useful scope:

1. **Concurrent service:** load typed configuration, handle requests, maintain
   state, perform bounded concurrent work, log failures and shut down cleanly.
2. **Automation script:** traverse files, filter/group/sort metadata, generate
   digests or a report, and invoke an external tool with explicit failure and
   transaction behavior.
3. **Numerical analysis:** load CSV, decode columns, transform arrays, compute
   statistics, plot results and save output reproducibly.

Supplement these with focused examples for HTTPS/JSON and streaming a dataset
larger than the desired in-memory working set. Record every repeated helper,
manual resource workaround and inconsistent conversion. Use that evidence to
revise the inventory rather than expanding it speculatively.

Acceptance includes comprehensible errors and documented ownership/effects, not
just successful output. There is no claim yet that these examples establish a
measured 80% coverage of all application or scientific programming.

## 10. Decisions deliberately left open

- Final Base/ExtBase naming, module membership and prelude exports.
- Compatibility with existing `Str`, `String`, `Vec` and related names.
- Exact ordering/hash constraints and the initial Map implementation.
- Persistent versus linear collection APIs and borrowing/scoped-resource syntax.
- Actor placement, task cancellation and supervision-package boundaries.
- Numeric widths, array/view semantics and supported numerical backends.
- Detailed effect/retry contracts for network, process and interactive operations.
- Mandatory versus optional facilities on each target and profile.
- Additional digest algorithms, protocols, formats and scientific routines.

Implementation should proceed from representative programs and explicit contracts.
The goal is a coherent first edition that can evolve, not a final enumeration of
all facilities FP-RISC will ever need.
