# Edge cases: what FP-RISC does when pushed from outside

Date: 2026-10-11. Kind: findings from a battery, with the battery kept
(`tests/edge/`, `python3 tests/edge/run.py` and `--src`). Base profile on
macOS arm64, compiler at `6412d70`. Eighty probes: arithmetic and
strings, JSON, lists and recursion, actors, files, sockets and HTTP, the
process environment, and thirty malformed or extreme source files. Each
was built and run under a timeout and its outcome recorded; nothing here
was fixed. Severity is by the bounds rule (`docs/2026-09-19-BOUNDS.md`:
limits from fundamentals, never silent) and the failure-honesty rule (a
failure is an answer by name, never a signal, a wrong value or a halt).

## What held

Most of the surface answers by name, and the big inputs were not a
problem: a 100 MB string, a 10 MB JSON string, 100,000 levels of JSON
nesting, a 5,000,000-element list, 3,000,000 non-tail frames (the stack
grew), 100,000 actors spawned in 2.2 s, 20,000 files opened (the runtime
raises the descriptor limit), a 2 MB environment variable, argv with
invalid UTF-8 and empty strings, 20,000 nested parentheses, a 300-tuple,
CRLF, tabs and a raw NUL byte in the source. Files, directories, sockets
and the HTTP client answer `Err` with the system's own text for every
misuse tried: missing, directory, permission, empty path, NUL in path,
5,000-byte path, symlink loop, bad mode, wrong direction, closed twice,
descriptor 999, descriptor -1, refused, unroutable, privileged port, port
in use, accept on a closed listener, read and write on a closed stream, a
peer that closed (both `Broken pipe` and `Connection reset` by name, and
the process survived: sockets are protected from SIGPIPE). Stdin closed is
`Err(eof)`. `readWithin 0` and a negative deadline time out at once. The
deadlock detector catches an actor waiting on itself and two actors
waiting on each other in about 2.3 s, and names it.

## Findings

Ordered within each group by severity. **S** = silent (a wrong or
clamped value with no word), **H** = halts or kills where an answer was
due, **D** = a diagnostic that misleads, **P** = performance, **Q** = a
question of policy.

### Arithmetic and strings

| # | Probe | What happens | Class |
| --- | --- | --- | --- |
| 1 | `4611686018427387903 + 1` | wraps to `-4611686018427387904`; `a * 2` is `-2`, `a * a` is `1`, `3037000500 * 3037000500` is `145474192` | **S** -- the draft's "pin integer widths and overflow" is not met; nothing in the language says Int wraps at 63 bits, and no checked form exists (`tests/edge/int_edge.fpr`) |
| 2 | `S.toInt "4611686018427387904"` | `Ok -4611686018427387904`; `"9223372036854775808"` is `Ok 0`; twenty-three nines is `Ok 200376420520689663` | **S** -- a parser that answers `Err "not a number"` for `"+5"` answers `Ok` with garbage for an overflow (`str_toint`) |
| 3 | `chr 1114112`, `chr (0 - 1)` | a replacement character, no refusal; `chr 255` is one invalid UTF-8 byte | **S** -- out of range by name, or document that `chr` makes bytes (`chr_range`) |
| 4 | `substr "abc" (0 - 1) 5` | the whole string: a negative offset clamps | **S**, documented as clamping (`str_substr`) |
| 5 | `strlen "é"` is 2, `charAt "é" 0` is 195 | strings are bytes | not a defect; the register should say so where `charAt` is described |

### JSON (`std/json`)

| # | Probe | What happens | Class |
| --- | --- | --- | --- |
| 6 | `"9223372036854775808"`, `"1e400"`, `"-0"`, `"00"` | all `Ok`, rendered back as the same text; a number is kept as its lexeme until converted, and `00` (invalid JSON) is accepted | **S** for `00`; the rest is a design the page should state (`json_numbers`) |
| 7 | `{"a":1,"a":2}` | `Ok {"a":2}`: the last duplicate wins, silently | **Q** (`json_numbers`) |
| 8 | `"\ud800"` | `Ok "�"`: a lone surrogate becomes U+FFFD | lenient, say so |
| 9 | control bytes, `[1,]`, trailing text, empty, blank | all refused by line and column | held |

### Actors

| # | Probe | What happens | Class |
| --- | --- | --- | --- |
| 10 | `kill (myself 0)` from actor 0 | nothing prints; 2.3 s later the deadlock detector panics the machine | **H** -- killing actor 0 should be refused by name (SUPERVISION S7) or end the program with a status (`actor_kill_self`) |
| 11 | `receiveFrom me me`; main waiting on a child waiting on main | the deadlock detector halts the machine, by name, after 2.3 s | **H** by design (U6): the only escape from a wait with no deadline is the machine's end |
| 12 | `AC.Static 0` | queued: clamped to 8 silently | **S** (SUPERVISION Q5) (`actor_static_zero`) |
| 13 | `kill` twice, `send` to self, `sleepUs` of -5 and 0, `sleepUs` of 2^40 | all fine: idempotent, delivered, no-ops, sleeps | held |

### Files and descriptors

| # | Probe | What happens | Class |
| --- | --- | --- | --- |
| 14 | `Os.read fd (0 - 1)` | `Ok ""`: a negative count is treated as zero | **S** (`file_fd_errors`) |
| 15 | `Os.seek fd 1000000000000` on a read-only file | `Ok 1000000000000` | as the system does; fine |
| 16 | `Os.close 1`, then `print` | the line vanishes, exit 0 | **Q** -- a closed stdout is not an error anywhere (`file_fd_errors`, `env_stdout_closed`) |

### Sockets and HTTP

| # | Probe | What happens | Class |
| --- | --- | --- | --- |
| 17 | `print` into a pipe whose reader has gone | the process dies of SIGPIPE, status 141, nothing said | **H** -- sockets ignore SIGPIPE, stdout does not; a Base program behind `head` dies (`env_epipe`) |
| 18 | HTTP server, a 5 MB request line | read whole into memory and served (`200`, path length 5,000,002) | **Q** -- no bound on a request line or headers; a client decides the server's memory (`http_huge_request`) |
| 19 | HTTP server, `Content-Length: 999999999999`, three bytes sent | the handler's actor waits for the body with no deadline; the client times out; the server actor stays until the peer closes | **Q** -- a read deadline per request, or a body bound, or both; today a slow client holds an actor and its buffers for ever |
| 20 | HTTP server, `Content-Length: -5` | accepted, served as an empty body | **S** |
| 21 | HTTP client, a server that closes after a short body, or sends no status line | `Err "Connection reset by peer"` in both cases: macOS answers a close with unread data by RST, and the client reports the RST instead of "truncated body" or "not an HTTP response" | **D** (`http_garbage_server`) |
| 22 | `O.connect "10.255.255.1" 80` | `Err "Operation timed out"` after 75 s, the system's own limit; no deadline parameter exists on `connect` | **Q** -- whether the actor holds a hart for those 75 s is not answered by this probe (`net_connect_unroutable`) |
| 23 | `O.connect "127.0.0.1" 70000`, port -1, `listen "300.1.1.1"` | `Err "nodename nor servname provided, or not known"`: the resolver's text for a port out of range | **D** |

### The process environment

| # | Probe | What happens | Class |
| --- | --- | --- | --- |
| 24 | `FPR_HARTS=0`, `=abc` | one hart; `=999` is ten; `FPR_HEAP_MB=0` and `FPR_STACK_MAX_MB=0` are ignored | **S** (Q5, now measured) (`env_harts`) |
| 25 | `Sys.exit 300` | status 44 | **S** -- say the status is 0..255 or refuse |
| 26 | SIGTERM during a sleep | status 143, the default | fine for Base; nothing runs at exit |
| 27 | `main` returning a String | status 0, nothing printed | as documented |

### The compiler (`tests/edge/src`)

| # | Probe | What happens | Class |
| --- | --- | --- | --- |
| 28 | `4611686018427387904` (2^62), `9223372036854775807`, a 26-digit literal, `0 - 9223372036854775809` | `fpr: int literal ... does not fit a tagged rv64 word` and a Haskell `CallStack` from `Codegen.hs:1300`: no file, line or column | **D** -- an uncaught `error` where a diagnostic was due (`literal_overflow`, `literal_negbig`) |
| 29 | a source file with invalid UTF-8 | `hGetContents: invalid argument (cannot decode byte sequence ...)`, no position | **D** -- uncaught (`non_utf8`) |
| 30 | a 50,000-element list literal | not compiled in 300 s | **P** (`big_list_literal`) |
| 31 | a 600-parameter function | compiled in 276 s | **P** (`many_params`) |
| 32 | a 2 MB string literal on one line | not compiled in 300 s | **P** (`long_line`) |
| 33 | an empty file, a file of comments, a file with no `main` | a LINKER error: `_fpr_fn_main` undefined, `ld: symbol(s) not found` | **D** -- "no main" is the compiler's to say (`empty`, `comments_only`, `no_main`) |
| 34 | `prüfung x = x + 1` | parsed and typed, then the ASSEMBLER refuses `.quad _fpr_fn_prüfung` | **D** -- either names are ASCII (say so at the parser) or they are mangled (`unicode_ident`) |
| 35 | a UTF-8 BOM | `unexpected '﻿'` | **D** -- editors write them; skip it or name it (`bom`) |
| 36 | `"{"` inside a string literal; `<<` inside an interpolation | the error is reported at the START OF THE NEXT STATEMENT as `unexpected "_ = "`, expecting an expression | **D** -- the interpolation's own position is lost; this cost an hour of this campaign (`int_edge`, `json_numbers` in their first form) |
| 37 | `0x` | `unbound name: x` | **D** |
| 38 | `f x = 1. f x = 2.` | compiles; the second clause is never reached | **S** -- the coverage pass refuses an unreachable case ARM; a clause is not checked (`duplicate_def`) |
| 39 | `f x = g x. g x = f x.` in an `unsafe` program | compiles, runs for ever | as the profile says; a safe program is refused |
| 40 | `1e999`, `0.0 / 0.0`, `5e-324` | `Inf`, `NaN`, `4.94065645841246e-324` | IEEE, fine |
| 41 | unterminated string, unterminated block, a typo in `profile`, a non-exhaustive case, a type mismatch, a missing module, a traversal path, a module using itself | refused with position and expectation | held |

## What to do with this

The findings fall into four pieces of work, each small:

1. **Overflow is a decision**, then an afternoon: Int arithmetic (1),
   `S.toInt` (2), `chr` (3), `Sys.exit` (25). The bounds rule says never
   silent. The cheapest honest form is refusal by name at the boundary
   (`toInt`, `chr`, `exit`) and a stated wrap for arithmetic with checked
   forms beside it.
2. **The compiler's own edges** (28, 29, 33, 34, 35, 36): every one is a
   diagnostic that exists somewhere being reported from the wrong place
   or not at all. The three performance cases (30 to 32) share a cause to
   find: something is quadratic in the size of one expression.
3. **stdout and SIGPIPE** (17): one `signal(SIGPIPE, SIG_IGN)` at start
   turns a silent death into `print`'s `Err`, which then has to go
   somewhere; today `print` answers Unit.
4. **The HTTP server's bounds** (18, 19, 20): a request-line and header
   bound, a body bound, and a read deadline per request, all three
   derived from configuration rather than constants. The register's
   Files entry has the same shape of gap.

Rerunning `tests/edge/run.py` after any of these and diffing the result
files is the acceptance test; the battery is kept for that.

## Fixed on 2026-10-11 (the same day, after the battery)

Work items 2, 3 and 4 above, and the parts of item 1 that are bugs rather
than policy, are done. The overflow DECISION was taken on 2026-10-12:
Int arithmetic TRAPS (docs/2026-10-12-INT-OVERFLOW.md); `chr` and
`Sys.exit` refuse out of range.

| # | Now |
| --- | --- |
| 1 | (2026-10-12) Int `+ - * /` trap by name with the operands when the result does not fit; in the C primitives, the inline fast paths, the unboxed kernels and the NEON lanes. I64 is the type that wraps. Int pairs still fuse, by the 2026-10-13 relaxation in docs/2026-10-03-FUSION-EFFECT-ORDER.md (tests/base/vecfuse_effects.fpr) |
| 2 | `S.toInt` answers `Err "out of range: ..."` past 63 bits, and reaches the most negative Int (digits accumulate negatively) |
| 3 | (2026-10-12) `chr` outside 0..255 is refused by name (chr makes one byte; String.fromCodes makes UTF-8) |
| 10 | `kill` refuses actor 0, the memory actor, the irq router and the timer by name (not the log actor: a program installs its own, and a dead logger is handled, tests/base/logdead.fpr) |
| 12 | `Static 0` and any `spawnCap n` with `n < 1` or `n > 1048576` are panics by name; rounding up to a power of two from 8 stays and is documented |
| 17 | `signal(SIGPIPE, SIG_IGN)` at the start of `main` (machine/unix/main.c); the program behind `head` finishes, status 0 |
| 18, 19, 20 | `std/httpcore limits` `{ header = 65536, body = 1048576, readMs = 10000 }`: 431 / 413 / 408, a non-numeric or negative content-length 400; `serveWith`, `serveOnWith`, `readRequestWith` take other limits; `std/stream readUntilWithin`, `readExactlyWithin`. tests/std/httplimits.fpr. Open: a Poller connection's wait in its mailbox has no deadline, so `readMs` bounds nothing there (stated in `fillBy`) |
| 24 | `FPR_HARTS`, `FPR_HEAP_MB`, `FPR_STACK_MAX_MB` refused by name (exit 2) when not what they claim |
| 25 | (2026-10-12) `Sys.exit` outside 0..255 is refused by name |
| 28 | the parser refuses an Int literal past 63 bits at its position (`integerN`); `-4611686018427387904` parses |
| 29 | the source is read as bytes; a byte that is not UTF-8 is refused by name with its offset |
| 30, 31, 32 | four super-linear passes, all in the compiler's own data handling, none in the algorithms it implements. (a) `Codegen.normIn` substituted with `substE` and re-walked the body per let (quadratic) and tested free variables with `freeVars`, which lists them all and filters by the parameter list at every lambda (cubic in arity): now one env-carrying pass and `occurs`, which stops at the first hit. (b) The let-SINK rule (`let x = a in let y = b in r -> let y = (let x = a in b) in r`), applied per let bottom-up, re-descended the nest the inner sinks had built: CUBIC IN THE LENGTH OF ANY BLOCK (a 4000-statement block, `x_i = x_{i-1} + i`, took 114 s; nothing to do with literals). Now `letChain` walks a chain top-down once, with occurrence counts for "used later". (c) Code generation appended the code that follows a let's right-hand side, a call's last argument and a constructor's last field with `++`, copying the deep part once per level: now `goThen` passes the following code down (`rest`) and the innermost level appends it. (d) The string lexer made a segment per character and merged adjacent segments two at a time (`a ++ b` with a growing `a`): now a run at a time, merged once. (e) `externals` kept the let-bound names in a LIST and tested every variable against it (quadratic in a body's lets), and `normIn.binders`, `fuseVec.walk` and the `Peephole` label lookup had the same `concatMap`/list shapes. Measured (compile to asm, this Mac): 400 parameters 67 s to 0.29 s; list literal of 8000 / 16000 / 32000 elements 86 s / - / - to 3.4 / 5.2 / 9.5 s (linear now; about 1.5 s of that is the prelude); 4000-statement block 104 s to 0.9 s; 2 MB string literal (300 s timeout) to 1.1 s. The generated code is unchanged (label numbering aside) |
| 33 | `error: FILE has no \`main\`` from the compiler; `--module` builds are exempt |
| 34 | names are mangled ASCII-only (`isAscii && isAlphaNum`), so `prüfung` assembles |
| 35 | a UTF-8 BOM is skipped |
| 36 | an interpolation that fails to parse is a DELAYED error (`registerParseError`) at its own position; the braces are skipped and the parse goes on |
| 37 | `0x1F`: `0x...: FP-RISC has no hexadecimal literal; write the number in decimal` |
