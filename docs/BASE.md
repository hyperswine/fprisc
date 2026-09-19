# The Base profile: FP-RISC as a language for this machine

Kind: reference for what ships today; the contract language is SEMANTICS.md.

`fpr build prog.fpr` turns a program into an ordinary executable for the
machine it runs on: the `posix` system of docs/PROFILES.md, for a program
of the `base` profile (the default; `profile base.` says so).  No QOS, no QEMU, no Makefile: the compiler lowers the
program for the host ISA (x86-64 or AArch64, Linux or macOS), and the host's
C compiler links it with the same core runtime every other profile uses
(`runtime`: allocator, actors, mailboxes, fuel preemption, the deadlock
detector) and a HAL whose board is libc (`machine/posix`).  Harts are pthreads.
The result depends on nothing but libc and libpthread.

```sh
fpr build hello.fpr            # -> ./hello
./hello
fpr run hello.fpr a b c        # build to a temp file, run it, return its status
fpr build x.fpr -o out --harts 4 -v   # -v shows the compiler's report; --keep keeps the .s
```

The first build compiles the runtime into `~/.cache/fpr/rt/<arch>-h<harts>/`
and the prelude into `~/.cache/fpr/build/units/`; after that a build is the
program's own compile and a link (about a tenth of a second for hello).
`FPR_CC` picks the C compiler (`cc`), `FPR_HOME` the fprisc checkout when
`fpr` is not run from beside `core/` and `hal/` (compiler/Home.hs).
`make posix PROG=x.fpr` is the same recipe spelled out in the Makefile.

## What a Base program can rely on

Everything Part I of SEMANTICS.md promises -- the language, the prelude,
`use "std/..."` modules, actors and messages, `unsafe`/`measure`, linearity,
deep equality, panics -- exactly as on bare metal and QOS.  Then the
environment a process needs, as builtins the profile's HAL grants
(`machine/posix/base.c`; the types are in `compiler/Infer.hs`):

| name | type | meaning |
|---|---|---|
| `print` | `a -> Unit` | the value rendered to stdout |
| `Sys.stderr` | `String -> Unit` | bytes to stderr, as given |
| `Sys.readLine` | `Unit -> Result String String` | one line of stdin without its newline; `Err "eof"` at the end |
| `Sys.args` | `Unit -> List String` | the command line after the program name |
| `Sys.env` | `String -> Result String String` | a variable, or `Err "unset"` |
| `Sys.exit` | `Int -> a` | end the process with that status (0..255) |
| `Sys.timeUs` | `Unit -> Int` | monotonic microseconds |
| `fileRead` | `String -> String` | the whole file; panics when it cannot |
| `fileWrite` | `String -> String -> Result Unit String` | path, contents; replaces |
| `fileAppend` | `String -> String -> Result Unit String` | path, contents; appends |
| `fileExists` | `String -> Bool` | |

The exit status: `main`'s result when it is an `Int` (masked to 0..255),
otherwise 0; a panic is 1 with the message on the console; `Sys.exit`
ends the process at once.  Nothing is echoed at exit -- the `[fpr] main
=> ...` trailer belongs to the QEMU and QOS hosts.  `FPR_HARTS=n` sets the
live hart count at run time (up to `--harts` at build time; 1 makes a run
deterministic).

## No devices: a process is not a board

A Base program on the posix system is a Unix process. Its world is the table
above -- the command line, the environment, the three streams, files, the
clock, an exit status -- not a register map. It used to carry a pretend
virt board (`device "uart"` as a 16550 modelled over stdio, a CLINT serving
mtime) so that programs written against the board ran unchanged; that went
with `machine/posix/devices.c`. A program that wants to be portable says `print`.

Hardware is reached the way any host facility is: a module declares the
primitives it needs as signatures with no definition, and `fpr build --with
driver.c` links the C that implements them (docs/C-REDUCTION.md). A program
that references a device primitive nobody supplied fails at LINK time on the
`fpr_g_` name: the image's imports are its capability manifest.

Not on the host: RVV, the specialized Vec loops (x86-64 lowers with
vec-loop specialization off, so the two in-place-fusion checks in the
corpus do not hold hosted), plugin loading, QOS services.

## Evidence

`tests/check_base.py`: hello, argv/env/exit status, stdin to EOF, stderr,
files, a panic's status, `tests/actors.fpr` on two pthread harts,
`tests/stduse.fpr`, `fpr run` passing arguments and status through, the
warm cache.  Of the corpus, 30 of the 34 tests that make sense hosted
build and run clean under `fpr build` (the other four: the two in-place
fusion checks above, a typed-hole fixture, and a test with a pre-existing
type error).

## How it is put together

- `--system=posix` (compiler/Compile.hs) picks the lowering for the host
  the compiler was built on: `x64` on x86_64, `a64` on aarch64 Linux,
  `a64mac` on macOS.  The rv64 emission stays the IR.
- `machine/posix/main.c` boots as crt0.S would: `fpr_rt_init`, one pthread per
  hart, `fpr_hart_main(0)`.  `hal.c` answers the board obligations (console,
  poweroff, the sleep/wake doorbells as a 200 us poll, mtime, no external
  interrupts).  `base.c` is the table
  above; the heap is a reservation of address space made in `hal.c` (`hal_heap_span`), with no size of its own.
- `compiler/Build.hs` is `fpr build`/`fpr run`: the compiler as a quiet
  subprocess, the runtime object cache, the link.
