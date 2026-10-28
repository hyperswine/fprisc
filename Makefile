# FP-RISC compiler, interpreter and standalone bare-metal runtime.
# QOS application linking is maintained in qos/fp-risc/qos-app.mk.

# the language RUNTIME, and the MACHINE LAYER under it, one per system (docs/2026-09-19-HAL.md)
RUNTIME ?= runtime
MACHINE ?= machine
FPR_TOOLCHAIN ?= .
HARTS   ?= 2
CROSS    = riscv64-unknown-elf-
PROG    ?= tests/demo.fpr
FILE    ?= std/checkdemo.fpr
QA_OUT  ?= app.qa
# where per-program intermediates go (qos.py points this at the
# project's .qos/build so an installed tree is never written to); the
# host stamp and the compiler's own build stay under build/
BUILD   ?= build
IMAGE   ?= image.elf

RT_CORE = $(RUNTIME)/runtime.c $(RUNTIME)/i32.c $(RUNTIME)/actors.c $(RUNTIME)/bits.c \
          $(RUNTIME)/vec.c $(RUNTIME)/sstr.c $(RUNTIME)/mod.c $(RUNTIME)/buddy.c
RT_VIRT = $(MACHINE)/virt/crt0.S $(MACHINE)/virt/ctx.S $(MACHINE)/virt/ctx_fab.c \
          $(MACHINE)/virt/hal.c $(MACHINE)/virt/memshim.c
# EXTRA_RT: sources a HAL ABOVE the machine layer adds to a bare-metal image
# (QOS Native's drivers: `make bare-metal` run from the qos tree passes them)
EXTRA_RT ?=

ARCHFLAGS = -march=rv64imafdc_zicsr -mabi=lp64 -mcmodel=medany
# hosted (qosp) apps grant memory in QOSSLAB-byte slabs: the 256 KiB
# machine default is a per-actor and per-message floor that caps a
# thousand-session server at a few dozen; 32 KiB keeps the recycler's
# exact-fit reuse and makes a session cost what its state weighs
QOSSLAB ?= 32768
# the per-actor stack for hosted apps; an app whose loops are accumulator
# shaped (fprlive) builds with QOSSTACK=65536 for four times the sessions
QOSSTACK ?= 262144
QOSCFLAGS_EXTRA ?=
CFLAGS = $(ARCHFLAGS) -DFPR_NHARTS=$(HARTS) \
         -ffreestanding -nostdlib -nostartfiles -O2 -Wall -Wextra \
         -fno-builtin -fno-stack-protector
QEMU  = qemu-system-riscv64
ACCEL = -accel tcg,thread=multi

# ---- RVV: the vector tier, now shippable -------------------------------
# `make bare-metal-run PROG=... RVV=1` compiles Vec loops with --rvv
# (strip-mined vsetvli/vle/vadd), assembles with the V extension, and
# boots QEMU with a V-capable cpu.  The enable shim is emitted link-once
# (COMDAT), so multi-unit programs link cleanly.  Without RVV=1 nothing
# changes: no unit touches mstatus.VS and the images run on V-less cores.
ifeq ($(RVV),1)
FPRC_FLAGS += --rvv
ARCHFLAGS = -march=rv64imafdcv_zicsr -mabi=lp64 -mcmodel=medany
ACCEL += -cpu rv64,v=true
endif
TIMEOUT := $(shell command -v timeout 2>/dev/null || echo "")

all: fpr

# Explicit development step: generated exports are checked in so fresh Cabal /
# installed builds need no running FP-RISC generator. CI checks reproducibility.
.PHONY: sol-web-assets sol-web-assets-check
sol-web-assets: fpr
	./fpr build tools/generate_sol_web.fpr -o build/generate-sol-web
	./build/generate-sol-web
	$(MAKE) fpr
sol-web-assets-check: fpr
	./fpr build tools/generate_sol_web.fpr -o build/generate-sol-web
	./build/generate-sol-web --check

# ---- THE tool: one binary, profiles as subcommands ---------------------
# fpr compile|sol|stdcheck|commit|versions.  The sol pipeline is linked
# in as Sol.* modules — sol is a profile of this binary, not a second
# executable.  `fprc` stays as a symlink for fprc-compatible callers
# (the qos/ Makefile): bare flags fall through to `fpr compile`.
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
FPR_HOST_STAMP := build/.fpr-host-$(UNAME_S)-$(UNAME_M)
ifeq ($(UNAME_S),Darwin)
GLLIBS :=
else
GLLIBS := -lEGL -lGL
endif
# Homebrew's libarchive is keg-only. Standard Linux pkg-config paths and an
# explicit caller override work unchanged; do not pin a Cellar version.
NATIVE_PKG_CONFIG_PATH ?= $(firstword $(wildcard /opt/homebrew/opt/libarchive/lib/pkgconfig /usr/local/opt/libarchive/lib/pkgconfig))
NATIVE_PKG_ENV = PKG_CONFIG_PATH="$(NATIVE_PKG_CONFIG_PATH):$${PKG_CONFIG_PATH}"
$(FPR_HOST_STAMP):
	@mkdir -p $(BUILD)
	@rm -f build/.fpr-host-*
	@touch $@

# Every compiler module is an input, including nested Core/Type owners.
FPR_COMPILER_HS := $(if $(wildcard compiler),$(shell find compiler -type f -name '*.hs'))

# an INSTALLED tree (../.installed, written by `qos.py install`) ships
# the binary: the rule is then a presence check, so `make qos-app` never
# reaches for ghc through the fprc prerequisite
ifneq ($(wildcard ../.installed),)
fpr:
	@test -x fpr || { echo "installed tree without fpr: reinstall (qos.py install / brew reinstall qos-fpr)"; exit 1; }
else ifneq ($(FPR_TOOLCHAIN),.)
.PHONY: fpr
fpr:
	$(MAKE) -C "$(FPR_TOOLCHAIN)" fpr
else
fpr: $(FPR_HOST_STAMP) $(FPR_COMPILER_HS) compiler/cbits/fsx.c compiler/cbits/vecgpu.c compiler/cbits/handjit.c compiler/cbits/native_git.c compiler/cbits/native_archive.c compiler/cbits/native_host.c compiler/cbits/sol_digest.c compiler/cbits/sol_http.c fp-risc.cabal Makefile
	@set -e; fresh=$$(mktemp ./.fpr.tmp.XXXXXX); trap 'rm -f "$$fresh"' 0; \
	if command -v cabal >/dev/null 2>&1; then \
	  $(NATIVE_PKG_ENV) cabal build exe:fpr; cp "$$(cabal list-bin fpr)" "$$fresh"; \
	else \
	  gcc -c compiler/cbits/fsx.c -o compiler/cbits/fsx.o; \
	  gcc -c compiler/cbits/vecgpu.c -o compiler/cbits/vecgpu.o; \
	  gcc -c compiler/cbits/handjit.c -o compiler/cbits/handjit.o; \
	  $(NATIVE_PKG_ENV) pkg-config --atleast-version=8.4 libcurl; \
	  $(NATIVE_PKG_ENV) pkg-config --cflags --libs libgit2 libarchive libcurl > build/native-libs.flags; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libgit2 libarchive) -c compiler/cbits/native_git.c -o compiler/cbits/native_git.o; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libgit2 libarchive) -c compiler/cbits/native_archive.c -o compiler/cbits/native_archive.o; \
	  gcc -c compiler/cbits/native_host.c -o compiler/cbits/native_host.o; \
	  gcc -c compiler/cbits/sol_digest.c -o compiler/cbits/sol_digest.o; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libcurl) -c compiler/cbits/sol_http.c -o compiler/cbits/sol_http.o; \
	  (cd compiler && ghc -O1 -threaded -rtsopts "-with-rtsopts=-V0.001 -A64m" -i. -o ../"$$fresh" Main.hs cbits/fsx.o cbits/vecgpu.o cbits/handjit.o cbits/native_git.o cbits/native_archive.o cbits/native_host.o cbits/sol_digest.o cbits/sol_http.o $$(cat ../build/native-libs.flags) $(GLLIBS)); \
	fi; chmod 755 "$$fresh"; mv -f "$$fresh" fpr
	ln -sf fpr fprc
endif

# ---- the compiler's own build level (docs/2026-10-19-COMPILER-DEFAULTS.md)
# `make fpr` is the compiler deploys ship and the suites run: -O1, with a
# 64 MiB GHC nursery (-A64m) baked in beside the 1 ms tick.  Measured: a
# warm `fpr compile` 2x faster than the -O0 build, the compiler's own
# from-scratch and incremental rebuilds the same to the second, 64 MiB
# more peak RSS.  `make fpr-dev` is the -O0 build of the same sources,
# written to the same ./fpr, in its own cabal build dir (dist-dev) so
# the two never clobber each other's objects; `make fpr` after it is a
# no-op until a source changes.  `make fpr-opt` is the -O2 experiment
# (GHCOPT=-O2, build/fpr-opt; 2026-10-18-COMPILER-BUILD-OPT.md found it
# equal to -O1).  Without cabal the classic ghc path builds each level
# into its own build/ghc-* dir for the same reason.
.PHONY: fpr-dev
fpr-dev: $(FPR_HOST_STAMP) $(FPR_COMPILER_HS) compiler/cbits/*.c fp-risc.cabal Makefile
	@set -e; mkdir -p build; fresh=$$(mktemp ./.fpr.tmp.XXXXXX); trap 'rm -f "$$fresh"' 0; \
	if command -v cabal >/dev/null 2>&1; then \
	  $(NATIVE_PKG_ENV) cabal build exe:fpr -f dev --builddir=dist-dev; \
	  cp "$$($(NATIVE_PKG_ENV) cabal list-bin fpr -f dev --builddir=dist-dev)" "$$fresh"; \
	else \
	  mkdir -p build/ghc-dev; \
	  gcc -c compiler/cbits/fsx.c -o build/ghc-dev/fsx.o; \
	  gcc -c compiler/cbits/vecgpu.c -o build/ghc-dev/vecgpu.o; \
	  gcc -c compiler/cbits/handjit.c -o build/ghc-dev/handjit.o; \
	  $(NATIVE_PKG_ENV) pkg-config --atleast-version=8.4 libcurl; \
	  $(NATIVE_PKG_ENV) pkg-config --cflags --libs libgit2 libarchive libcurl > build/native-libs.flags; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libgit2 libarchive) -c compiler/cbits/native_git.c -o build/ghc-dev/native_git.o; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libgit2 libarchive) -c compiler/cbits/native_archive.c -o build/ghc-dev/native_archive.o; \
	  gcc -c compiler/cbits/native_host.c -o build/ghc-dev/native_host.o; \
	  gcc -c compiler/cbits/sol_digest.c -o build/ghc-dev/sol_digest.o; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libcurl) -c compiler/cbits/sol_http.c -o build/ghc-dev/sol_http.o; \
	  (cd compiler && ghc -O0 -threaded -rtsopts "-with-rtsopts=-V0.001 -A64m" -i. -outputdir ../build/ghc-dev -o ../"$$fresh" Main.hs ../build/ghc-dev/*.o $$(cat ../build/native-libs.flags) $(GLLIBS)); \
	fi; chmod 755 "$$fresh"; mv -f "$$fresh" fpr
	ln -sf fpr fprc

GHCOPT ?= -O2
.PHONY: fpr-opt
fpr-opt: $(FPR_HOST_STAMP) $(FPR_COMPILER_HS) compiler/cbits/*.c fp-risc.cabal Makefile
	@set -e; mkdir -p build; fresh=$$(mktemp ./.fpr.tmp.XXXXXX); trap 'rm -f "$$fresh"' 0; \
	if command -v cabal >/dev/null 2>&1; then \
	  $(NATIVE_PKG_ENV) cabal build exe:fpr --ghc-options="$(GHCOPT)" --builddir=dist-opt$(GHCOPT); \
	  cp "$$($(NATIVE_PKG_ENV) cabal list-bin fpr --ghc-options="$(GHCOPT)" --builddir=dist-opt$(GHCOPT))" "$$fresh"; \
	else \
	  mkdir -p build/ghc$(GHCOPT); \
	  gcc -c compiler/cbits/fsx.c -o build/ghc$(GHCOPT)/fsx.o; \
	  gcc -c compiler/cbits/vecgpu.c -o build/ghc$(GHCOPT)/vecgpu.o; \
	  gcc -c compiler/cbits/handjit.c -o build/ghc$(GHCOPT)/handjit.o; \
	  $(NATIVE_PKG_ENV) pkg-config --atleast-version=8.4 libcurl; \
	  $(NATIVE_PKG_ENV) pkg-config --cflags --libs libgit2 libarchive libcurl > build/native-libs.flags; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libgit2 libarchive) -c compiler/cbits/native_git.c -o build/ghc$(GHCOPT)/native_git.o; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libgit2 libarchive) -c compiler/cbits/native_archive.c -o build/ghc$(GHCOPT)/native_archive.o; \
	  gcc -c compiler/cbits/native_host.c -o build/ghc$(GHCOPT)/native_host.o; \
	  gcc -c compiler/cbits/sol_digest.c -o build/ghc$(GHCOPT)/sol_digest.o; \
	  gcc $$($(NATIVE_PKG_ENV) pkg-config --cflags libcurl) -c compiler/cbits/sol_http.c -o build/ghc$(GHCOPT)/sol_http.o; \
	  (cd compiler && ghc $(GHCOPT) -threaded -rtsopts "-with-rtsopts=-V0.001 -A64m" -i. -outputdir ../build/ghc$(GHCOPT) -o ../"$$fresh" Main.hs ../build/ghc$(GHCOPT)/*.o $$(cat ../build/native-libs.flags) $(GLLIBS)); \
	fi; chmod 755 "$$fresh"; mv -f "$$fresh" build/fpr-opt

# the compiler with GHC's profiler (late cost centres: the -O1 code, with
# a cost centre per top-level function), in its own cabal build dir, at
# build/fpr-prof.  tools/compile_profile.py runs it and prints where a
# compile spends its time and allocation (docs/2026-10-26-COMPILE-TIME-BUDGET.md).
.PHONY: fpr-prof
fpr-prof: $(FPR_HOST_STAMP) $(FPR_COMPILER_HS) compiler/cbits/*.c fp-risc.cabal Makefile
	@set -e; mkdir -p build; \
	$(NATIVE_PKG_ENV) cabal build exe:fpr --enable-profiling --profiling-detail=late --builddir=dist-prof; \
	cp "$$($(NATIVE_PKG_ENV) cabal list-bin fpr --enable-profiling --builddir=dist-prof)" build/fpr-prof

# build through cabal (declared FFI/libs in fp-risc.cabal).  Uses
# cabal-install when present, else the classic Setup path -- which
# resolves against the installed package db and needs no hackage
# index, so it works offline.
fpr-cabal:
	@set -e; fresh=$$(mktemp ./.fpr.tmp.XXXXXX); trap 'rm -f "$$fresh"' 0; \
	if command -v cabal >/dev/null 2>&1; then \
	  $(NATIVE_PKG_ENV) cabal build exe:fpr; cp "$$(cabal list-bin fpr)" "$$fresh"; \
	else \
	  ghc -o build/Setup Setup.hs >/dev/null; \
	  $(NATIVE_PKG_ENV) ./build/Setup configure --ghc >/dev/null; \
	  ./build/Setup build; \
	  cp dist/build/fpr/fpr "$$fresh"; \
	fi; chmod 755 "$$fresh"; mv -f "$$fresh" fpr
	ln -sf fpr fprc

fprc: fpr

# The Haskell checks in tests/*.hs as cabal test suites (fp-risc.cabal):
# built once against the compiler library, run in the package root.
# UNIT=TypedCore runs one suite.
.PHONY: unit-tests
unit-tests:
	$(NATIVE_PKG_ENV) cabal test $(if $(UNIT),test:$(UNIT),all) --test-show-details=direct

# ---- the std proof pass ------------------------------------------------
stdcheck: fprc
	./fprc --stdcheck $(FILE)

# ---- BareMetal profile -------------------------------------------------
$(BUILD)/prog.s: fprc $(PROG) core/prelude.fpr FORCE
	@mkdir -p $(BUILD)
	LC_ALL=C.UTF-8 ./fprc --system=bare-metal $(FPRC_FLAGS) --prelude=core/prelude.fpr $(PROG) $@

# the virt HAL's PLIC and CLINT drivers are FP-RISC (machine/virt/virt.mk)
FPRC ?= ./fprc
include $(MACHINE)/virt/virt.mk
bare-metal: $(BUILD)/prog.s $(RT_VIRT) $(VIRT_FPR) $(EXTRA_RT) $(RT_CORE) $(MACHINE)/virt/link.ld
	$(CROSS)gcc $(CFLAGS) -T $(MACHINE)/virt/link.ld -I$(RUNTIME) -I$(MACHINE)/virt \
	  $(RT_VIRT) $(VIRT_FPR) $(EXTRA_RT) $(BUILD)/prog.s $$(cat $(BUILD)/prog.s.units) $(RT_CORE) -o $(IMAGE)

bare-metal-run: bare-metal
	$(TIMEOUT) 20 $(QEMU) $(ACCEL) -machine virt -smp $(HARTS) -m 256M \
	  -nographic -bios none -kernel $(IMAGE)

# ---- Base profile: an executable for this machine (machine/posix) -----------
# `make posix PROG=x.fpr` is what `./fpr build x.fpr` does, spelled out:
# the program lowered for the host ISA, linked with the shared core and
# the hosted HAL by the host's C compiler.  Harts are pthreads.
POSIXHARTS ?= 2
ifneq ($(filter aarch64 arm64,$(shell uname -m)),)
POSIXCTX = $(MACHINE)/unix/ctx_a64.S
else
POSIXCTX = $(MACHINE)/unix/ctx_x64.S
endif
ifeq ($(shell uname -s),Linux)
POSIXLDFLAGS ?= -no-pie -rdynamic -ldl
endif
ifeq ($(shell uname -s),Darwin)
POSIXLDFLAGS ?= -Wl,-export_dynamic
endif
# x28 is reserved on aarch64: ctx_a64.S does not save it (compiler/Build.hs says why)
ifneq ($(filter aarch64 arm64,$(shell uname -m)),)
POSIXFIXED = -ffixed-x27 -ffixed-x28 -DFPR_HART_X28
endif
RT_POSIX = $(MACHINE)/posix/hal.c $(MACHINE)/posix/base.c $(MACHINE)/posix/base_file.c $(MACHINE)/posix/os_fs.c $(MACHINE)/posix/os_io.c $(MACHINE)/posix/os_watch.c $(MACHINE)/posix/os_net.c $(MACHINE)/posix/os_owned.c $(MACHINE)/posix/os_connection.c $(MACHINE)/posix/os_frame.c $(MACHINE)/posix/os_resolver.c $(MACHINE)/posix/os_tls_unavailable.c $(MACHINE)/posix/os_job.c $(MACHINE)/posix/os_module.c $(MACHINE)/unix/main.c $(MACHINE)/unix/park.c $(MACHINE)/unix/host.c $(MACHINE)/unix/os_proc.c $(MACHINE)/unix/os_term.c $(MACHINE)/unix/os_clock.c $(POSIXCTX)
BIN ?= $(BUILD)/$(basename $(notdir $(PROG)))
$(BUILD)/base.s: fprc $(PROG) core/prelude.fpr FORCE
	@mkdir -p $(BUILD)
	LC_ALL=C.UTF-8 ./fprc --system=posix --prelude=core/prelude.fpr $(PROG) $@

posix: $(BUILD)/base.s $(RT_POSIX) $(RT_CORE)
	$(CC) -O2 -Wall -Wextra $(POSIXFIXED) -DFPR_POSIX -DFPR_POSIX_CODEGEN_REV=$(shell sed -n 's/^codegenRev = \([0-9]*\).*/\1/p' compiler/Codegen.hs) -DFPR_NHARTS=$(POSIXHARTS) $(POSIXLDFLAGS) -I$(RUNTIME) -I$(MACHINE)/posix -I$(MACHINE)/unix \
	  $(BUILD)/base.s $$(cat $(BUILD)/base.s.units) $(RT_POSIX) $(RT_CORE) -lpthread -lm -o $(BIN)

posix-run: posix
	$(BIN) $(ARGS)
.PHONY: posix posix-run

# ---- HostedBytecode profile: the sol package ---------------------------
sol: fpr
	@echo "the HostedBytecode profile is: ./fpr sol <script.sol>"

clean-cabal:
	rm -rf dist dist-newstyle dist-dev dist-opt-O* build/Setup

clean:
	rm -rf build image.elf app.qa fpr fprc compiler/*.o compiler/*.hi compiler/Sol/*.o compiler/Sol/*.hi compiler/cbits/*.o

FORCE:
.PHONY: all stdcheck bare-metal bare-metal-run sol clean FORCE

# Unsafe standalone Builtin profile: no actors, devices, QOS or prelude.
#
# The allocator is machine/builtin/heap.fpr: FP-RISC over typed layouts
# (docs/2026-09-19-LAYOUTS.md), compiled as a LIBRARY unit (--lib) whose exports are
# the C symbols the runtime calls (fpr_alloc, fpr_free,
# fpr_builtin_release, ...).  It is written over Word/Addr and must not
# allocate to allocate, so it needs the raw ABI: ARC=1 selects it, and the
# legacy manual ABI (no ARC) keeps heap.c.  HEAP=c forces the C one, which
# is also what check_builtin.py builds natively under ASan/UBSan.
ifeq ($(ARC),1)
HEAP ?= fpr
else
HEAP ?= c
endif
ifeq ($(HEAP),fpr)
ifneq ($(ARC),1)
$(error HEAP=fpr needs ARC=1: the FP-RISC allocator uses the raw Word/Addr ABI)
endif
BUILTIN_HEAP = $(BUILD)/heap.s
else
BUILTIN_HEAP = $(MACHINE)/builtin/heap.c
endif
# one line: a backslash continuation inside a variable becomes a space,
# and a space splits the --export= argument
HEAP_EXPORTS = heapInit:fpr_builtin_heap_init,inHeap:fpr_in_heap,alloc:fpr_alloc,free:fpr_free,realloc:fpr_realloc,retain:fpr_builtin_retain,release:fpr_builtin_release,allocAdt:fpr_builtin_alloc_adt,liveAllocations:fpr_builtin_live_allocations,setLayout:fpr_builtin_set_layout,fieldCount:fpr_builtin_field_count,fieldKind:fpr_builtin_field_kind
$(BUILD)/heap.s: fprc $(MACHINE)/builtin/heap.fpr FORCE
	@mkdir -p $(BUILD)
	./fprc --system=bare-metal --profile=builtin --arc --raw --lib --export=$(HEAP_EXPORTS) $(MACHINE)/builtin/heap.fpr $@
BUILTIN_RT = $(MACHINE)/builtin/crt0.S $(MACHINE)/builtin/virt.c $(BUILTIN_HEAP) \
             $(MACHINE)/builtin/unsafe.c $(MACHINE)/builtin/arc.c $(MACHINE)/builtin/machine.S $(MACHINE)/builtin/interrupt.S $(RUNTIME)/runtime.c $(RUNTIME)/i32.c $(RUNTIME)/bits.c $(MACHINE)/virt/memshim.c
BUILTIN_BOARD ?= virt
BUILTIN_RAM ?= bram
BUILTIN_RVC ?= 0
BUILTIN_LINK = $(MACHINE)/builtin/link.ld
BUILTIN_ARCHFLAGS = $(CFLAGS)
ifeq ($(BUILTIN_BOARD),tangnano20k)
ifeq ($(ARC),1)
$(error tangnano20k currently supports manual ownership only, not ARC=1)
endif
BUILTIN_LINK = $(MACHINE)/builtin/tangnano20k/link.ld
ifeq ($(BUILTIN_RAM),sdram)
BUILTIN_LINK = $(MACHINE)/builtin/tangnano20k/link-sdram.ld
else ifneq ($(BUILTIN_RAM),bram)
$(error unknown Tang Nano memory option BUILTIN_RAM=$(BUILTIN_RAM))
endif
BUILTIN_RT = $(MACHINE)/builtin/tangnano20k/crt0.S $(MACHINE)/builtin/tangnano20k/board.c \
             $(MACHINE)/builtin/tangnano20k/machine.c $(MACHINE)/builtin/heap.c \
             $(MACHINE)/builtin/unsafe.c $(RUNTIME)/runtime.c $(RUNTIME)/i32.c $(RUNTIME)/bits.c $(MACHINE)/virt/memshim.c
ifeq ($(BUILTIN_RAM),sdram)
BUILTIN_CFLAGS += -DFPR_BUILTIN_HEAP_MAX_BYTES=8388608
else
BUILTIN_CFLAGS += -DFPR_BUILTIN_HEAP_MAX_BYTES=65536
endif
BUILTIN_RV32_MARCH = rv32im_zicsr_zifencei
ifeq ($(BUILTIN_RVC),1)
BUILTIN_RV32_MARCH = rv32imc_zicsr_zifencei
else ifneq ($(BUILTIN_RVC),0)
$(error BUILTIN_RVC must be 0 or 1)
endif
BUILTIN_ARCHFLAGS = -march=$(BUILTIN_RV32_MARCH) -mabi=ilp32 -mcmodel=medany \
                   -ffreestanding -nostdlib -nostartfiles -Os -Wall -Wextra \
                   -fno-builtin -fno-stack-protector -DFPR_SIMPLE_RISC
BUILTIN_COMPILER_FLAGS = --target=rv32
# Keep the board's soft IM library even for IMC. The toolchain's IMAC
# multilib can otherwise declare/use atomic instructions absent here.
BUILTIN_LDFLAGS += $(shell $(CROSS)gcc -march=rv32im -mabi=ilp32 -print-libgcc-file-name)
else ifneq ($(BUILTIN_BOARD),virt)
$(error unknown BUILTIN_BOARD=$(BUILTIN_BOARD))
endif
ifeq ($(ARC),1)
BUILTIN_COMPILER_FLAGS = --arc
BUILTIN_CFLAGS = -DFPR_BUILTIN_ARC -DFPR_BUILTIN_RAW
endif

# ---- a library unit: FP-RISC compiled to a linkable object with C exports
#   make builtin-lib LIB=path/to/x.fpr LIB_EXPORT=f:c_f,g   -> $(BUILD)/lib-x.s
# Link the .s into any builtin image (BUILTIN_EXTRA=...) or assemble it
# with $(CROSS)gcc -c for an archive; the exported symbols use the plain
# RV64 C ABI (docs/2026-09-18-BAREMETAL-BUILTIN.md, "Library units and C exports").
LIB ?= machine/builtin/heap.fpr
LIB_EXPORT ?=
LIB_FLAGS ?=
builtin-lib: fprc FORCE
	@mkdir -p $(BUILD)
	./fprc --system=bare-metal --profile=builtin --arc $(LIB_FLAGS) --lib --export=$(LIB_EXPORT) $(LIB) $(BUILD)/lib-$(basename $(notdir $(LIB))).s
.PHONY: builtin-lib
ifneq ($(BUILTIN_HEAP_BYTES),)
BUILTIN_CFLAGS += -DFPR_BUILTIN_HEAP_BYTES=$(BUILTIN_HEAP_BYTES)
endif
ifeq ($(ARC_CHECK),1)
BUILTIN_CFLAGS += -DFPR_ARC_CHECK
endif
bare-metal-builtin: fprc $(BUILTIN_RT) $(BUILTIN_LINK) FORCE
	@mkdir -p $(BUILD)
	./fprc --system=bare-metal --profile=builtin $(BUILTIN_COMPILER_FLAGS) $(FPRC_FLAGS) $(PROG) $(BUILD)/builtin.s
	$(CROSS)gcc $(BUILTIN_ARCHFLAGS) -UFPR_NHARTS -DFPR_NHARTS=1 -DFPR_BUILTIN $(BUILTIN_CFLAGS) -ffunction-sections -fdata-sections \
	  -Wl,--gc-sections -T $(BUILTIN_LINK) -I$(RUNTIME) -I$(MACHINE)/builtin \
	  $(BUILTIN_RT) $(BUILD)/builtin.s $$(cat $(BUILD)/builtin.s.units) $(BUILTIN_EXTRA) $(BUILTIN_LDFLAGS) -o $(IMAGE)
ifeq ($(BUILTIN_BOARD),tangnano20k)
	$(CROSS)objcopy -O binary $(IMAGE) $(basename $(IMAGE)).bin
	$(CROSS)size $(IMAGE)
endif

bare-metal-builtin-run: bare-metal-builtin
ifeq ($(BUILTIN_BOARD),virt)
	$(QEMU) -machine virt -smp 1 -m 128M -nographic -bios none -kernel $(IMAGE)
else
	python3 tools/run_simple_risc.py $(basename $(IMAGE)).bin $(SIMPLE_RISC_FLAGS)
endif
.PHONY: bare-metal-builtin bare-metal-builtin-run

# Host-specific source-plus-runner distribution, with atomic version activation.
SOL_PREFIX ?= $(HOME)/.local
SOL_BUNDLE ?= build/sol-bundle.tar.gz
.PHONY: sol-bundle sol-install
sol-bundle: fpr
	python3 tools/sol-install.py --output "$(SOL_BUNDLE)"
sol-install: fpr
	python3 tools/sol-install.py --prefix "$(SOL_PREFIX)"
