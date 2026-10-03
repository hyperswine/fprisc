# What the ESP32-P4 host restricts

Date: 2026-10-03. Kind: audit, with one finding confirmed on the board.
Revision `f1ea8b7`.

**Goal:** on the P4, FP-RISC should just work and scale the way it does on
unix. That means POSIX underneath, and no board-specific guardrails or limits
on the core language.

**Method:**
- A read-only audit of every place the ESP build differs from the unix host
  (`machine/esp-idf`, `platform/esp-idf`, the shared `machine/posix` and
  `machine/unix`, `runtime/`, the code generator, the IDF project
  configuration).
- The full board suite (`tests/check_esp_board.py`), which passed all ten
  checks on this revision's predecessor.
- One probe on the board for the stack finding.

This is a list, not a fix. Nothing here was changed.

The kinds used below:
- **fundamental:** hardware or ESP-IDF
- **constant:** chosen, and could grow or come from the system
- **semantic:** the core language differs
- **guard:** a workaround that exists only for the board

Each item also says whether the edge is **loud** (a named error) or **silent**.

## 1. Actor stacks never grow on the board (a bug; silent; confirmed)

- **The cause:** `machine/esp-idf/project/main/CMakeLists.txt:40` sets
  `-DFPR_STACK_SZ=65528`. `runtime/actors.c:401` keeps the default
  `FPR_STACK_HEADROOM` of 64 KiB.
- **The arithmetic:** `stk_window` (actors.c:422-423) computes
  `stk_span = size - FPR_STACK_HEADROOM`. A segment smaller than the
  headroom wraps that to a huge unsigned span.
- **The effect:** the stack check every deep FP-RISC function runs
  (`Codegen.hs`, `bltu t1, t2`) always passes, and `fpr_stack_grow` is never
  called. A recursion that outgrows its first segment writes past it into
  whatever memory is next. On unix (128 KiB segments) the same check works and
  stacks grow.
- **Confirmed on the board:**
  - `deep 50000` (non-tail) printed the right answer, because the overrun
    landed in free memory.
  - `deep 200000` in two actors, each holding a 20,000-element list, reset
    the board: "Guru Meditation Error: Core 0 panic'ed (Store access fault)".
  - The same program passes on unix.
- **Why no check caught it:**
  - The C stack guard is off by default on the board (item 7).
  - The board suite's `stack-guard` check exercises C frames, not deep
    FP-RISC recursion.
  - `docs/2026-09-23-ESP-IDF.md` says "Stacks still grow on demand". On the
    board they do not.
- **Removing it:** derive the headroom from the segment size, for example a
  quarter of it, capped at 64 KiB. Assert at compile time that it is smaller
  than the stack, so no host can configure the wrap again. Then add a deep,
  non-tail recursion beside live heap data to `check_esp_board.py`.

## 2. Int is 31 bits on 32-bit targets (semantic; partly silent)

- **The type:** a tagged word is the Int. On rv32 that is ±2^30; on 64-bit
  hosts it is ±2^62 (`Codegen.hs` `intFits`).
- **Loud:** an over-large literal is a compile error.
- **Silent:**
  - **Arithmetic wraps:** `50000 * 50000` is right on unix and wrong on the
    board.
  - **Host values are cut by `TAG((sw)x)`:**
    - `Sys.timeUs` is masked to 30 bits (`machine/posix/base.c`) and wraps
      after about 18 minutes.
    - `Esp.ms` wraps after about 12 days.
    - File sizes and mtimes truncate (`machine/posix/os_fs.c`).
- **Knock-on:** the wall clock (`machine/unix/os_clock.c`) is kept off the
  board, because epoch seconds do not fit.
- **Removing it:** a language decision. Either a 64-bit Int on 32-bit targets
  (two words, or boxed), or promotion to a bignum on overflow. Short of that,
  checked arithmetic, so the edge is loud.

## 3. No Float on 32-bit targets (semantic; loud)

- **Runtime:** every float primitive, `f64frombits` and `f32frombits`
  included, is behind `#if UINTPTR_MAX > 0xFFFFFFFFu` (`runtime/runtime.c`).
  A float use is therefore a link error.
- **Literals:** a float literal is split into halves whose high half does not
  fit a tagged word, so the compile stops.
- **Vector float kernels:** they emit `fmv.d.x`, which rv32 cannot assemble.
- **Single precision too:** F32 is missing as well, although the P4 has a
  single-precision FPU.
- **Removing it:** a float representation for 32-bit words (boxed doubles, or
  a NaN-boxed 64-bit value), plus F32 in a word. This is "Left open" in
  2026-09-23-ESP-IDF.md.

## 4. Sizes chosen at build time

| What | Board | Unix | Kind | At the edge |
|---|---|---|---|---|
| harts | `FPR_NHARTS=2` (`CMakeLists.txt:39`) | the online CPU count, `FPR_HARTS` honoured | constant | silent: a single-core build keeps `fpr_live_harts` at 2, so actors placed on hart 1 never run |
| heap | the largest PSRAM block minus 1/16, taken once (`machine/esp-idf/hal.c`); `hal_heap_release` is a no-op | a growing reservation | constant | loud ("heap exhausted"), but never grows and never returns memory |
| actor stack segment | 64 KiB | 128 KiB | constant | see item 1 |
| slab | 32 KiB, below `FPR_SLAB_MIN`, so slabs never double | 256 KiB, doubling | constant | performance only |
| sockets / TCP / accept queue | 32 / 32 / 32 (`sdkconfig.defaults`) | ulimit | constant | sockets: loud ("busy"); accept queue: **silent** (lwIP resets the connection) |
| all descriptors | newlib `FD_SETSIZE` 64, shared by sockets, FAT files and eventfds | ulimit | fundamental under IDF 5.3; IDF 5.4+ makes it configurable | — |
| open files | `FPR_ESP_FS_MAX_FILES 16` | ulimit | constant | meant to be an Err; not yet exercised |
| watchers | 24 eventfds (`watch_wake.h`), each a thread with a 16 KiB internal-RAM stack (`os_watch.c`; unix 256 KiB) | ulimit | constant | loud at 24; internal RAM likely runs out first |
| job broker stack | 8 KiB internal (`os_job.c`) | 256 KiB | constant | caught only by FreeRTOS |
| Wi-Fi access point | 4 clients, channel 6 (`platform/esp-idf/wifi.c`) | — | constant | refused by the radio |
| console input | 1 KiB UART buffer (`main.c`) | the tty | constant | **silent**: dropped while nothing reads |
| flash | 4 MiB app, 8 MiB FAT; IDF 5.3 reaches 16 of the chip's 32 MiB | — | fundamental under 5.3 | — |

## 5. Scheduling and timing

- **Priority:** harts run at priority 1, so every IDF task outranks actors.
- **Watchdog:** the idle-task watchdog is off, so a hung hart goes
  unreported.
- **Timers:** they tick at 1 ms (`CONFIG_FREERTOS_HZ=1000`); unix has
  nanoseconds. `usleep` below a tick busy-waits.
- **The park:** a task notification capped at 20 ms, the same cap as unix.
- **Spin-before-block:** the cross-hart spin (`hal_block_spin_ns`, 2 µs
  default) applies on the board through the shared `machine/posix/hal.c`. It
  passed the suite, but its cost there was never measured.
- **Throughput defaults:** PSRAM runs at its default 20 MHz, and the lwIP TCP
  window and buffers are defaults. Both are throughput settings, not
  semantics.

## 6. Code generation on 32-bit targets (constant; speed only)

Several passes are gated on `w == 8`: register promotion, the peephole pass,
`normIn`, the inline arc and primitive expansions, and jumping-code `if`.
Without jumping code, every condition builds a Bool object. Making these
passes word-size generic would bring rv32 code up to the 64-bit backends.

## 7. Board-only guards and workarounds

- **No stack guard for C code by default:**
  - `hal_stack_guard` is a no-op, and IDF's own hardware stack guard is off
    (`sdkconfig.defaults`).
  - The watchpoint guard is opt-in (`FPR_ESP_STACK_GUARD=1`), because armed
    store watchpoints cost about a third of compute speed.
  - Unix uses guard pages and SIGSEGV for a named panic.
  - A cheap always-on backstop (PMP, or a canary checked at every switch)
    would have caught item 1.
- **File and stream calls run on the hart's internal-RAM stack**
  (`FPR_FN_CSTACK`):
  - Flash operations assert an internal stack, and actor stacks are in
    PSRAM. Sockets pay the stack switch too.
  - The hart stack is 32 KiB, with 8 KiB required (`FPR_ESP_CSTACK_NEED`, a
    named panic).
  - A FAT write disables the cache, which stalls PSRAM, and so all actors,
    while it runs.
  - This is fundamental while stacks live in PSRAM. The alternatives are a
    dedicated file worker on an internal stack, or internal-RAM actor
    stacks.
- **HTTPS is not wired:** `std/httpcore` answers Err for HTTPS, although
  mbedTLS and esp-tls are in IDF.

## 8. Facilities the host lacks (all refused by name)

- **Processes:** `Os.run`, `exec` and `exePath` are not linked.
- **Terminal:** raw mode and size.
- **Time:** the wall clock and time zone (blocked on item 2).
- **Program environment:**
  - `Sys.args` is empty, and `Sys.env` answers `Err "unset"`.
  - There is no working directory; paths must be absolute.
  - A program's end parks the board rather than exiting.
- **Wi-Fi station mode:** not exposed (`std/wifi` has info, scan, an access
  point, stations, and stop).
- **DNS errors:** only numeric (no `gai_strerror`).
- **Radio jobs:** they share the single broker thread, so a 5 s BLE scan
  delays Wi-Fi calls. Unix behaves the same.

## Shared with unix (not ESP-specific)

These limits are the same on both hosts: `FPR_HOST_IRQ_MAX` and `IRQ_MAX`
(1024), `SSTR_CAP` (128), `FPR_RBUF_SZ` (4096), the mailbox ring capacities,
and serial job execution.

## Order of work, if taken up

1. Item 1, the stack bug: a few lines, and a board check.
2. The silent edges made loud:
   - the accept-queue reset;
   - console input dropped;
   - masked clocks and host values;
   - Int overflow, at least checked arithmetic.
3. Hart count from `portNUM_PROCESSORS`, and a heap that grows in further
   PSRAM chunks.
4. The constants in item 4 sized from the system. Move to IDF 5.4+ for
   `FD_SETSIZE` and the flash above 16 MiB.
5. The Int and Float representation for 32-bit targets: a language decision.
6. Word-size-generic code generation, and HTTPS through mbedTLS.

The BOUNDS register (`docs/2026-09-19-BOUNDS.md`) carries the ESP rows. Its
silent rows are the ones item 2 of this list is about.
