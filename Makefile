# FP-RISC compiler, interpreter and standalone bare-metal runtime.
# QOS application linking is maintained in qos/fp-risc/qos-app.mk.

HAL     ?= hal
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

RT_CORE = $(HAL)/core/runtime.c $(HAL)/core/actors.c $(HAL)/core/bits.c \
          $(HAL)/core/vec.c $(HAL)/core/sstr.c $(HAL)/core/mod.c $(HAL)/core/buddy.c
RT_VIRT = $(HAL)/virt/crt0.S $(HAL)/virt/ctx.S $(HAL)/virt/ctx_fab.c \
          $(HAL)/virt/hal.c $(HAL)/virt/memshim.c
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
$(FPR_HOST_STAMP):
	@mkdir -p $(BUILD)
	@rm -f build/.fpr-host-*
	@touch $@

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
fpr: $(FPR_HOST_STAMP) compiler/*.hs compiler/Sol/*.hs compiler/cbits/fsx.c compiler/cbits/vecgpu.c compiler/cbits/handjit.c
	@if command -v cabal >/dev/null 2>&1; then \
	  cabal build exe:fpr && cp "$$(cabal list-bin fpr)" fpr; \
	else \
	  gcc -c compiler/cbits/fsx.c -o compiler/cbits/fsx.o && \
	  gcc -c compiler/cbits/vecgpu.c -o compiler/cbits/vecgpu.o && \
	  gcc -c compiler/cbits/handjit.c -o compiler/cbits/handjit.o && \
	  cd compiler && ghc -O0 -i. -o ../fpr Main.hs cbits/fsx.o cbits/vecgpu.o cbits/handjit.o $(GLLIBS); \
	fi
	ln -sf fpr fprc
endif

# build through cabal (declared FFI/libs in fp-risc.cabal).  Uses
# cabal-install when present, else the classic Setup path -- which
# resolves against the installed package db and needs no hackage
# index, so it works offline.
fpr-cabal:
	@if command -v cabal >/dev/null 2>&1; then \
	  cabal build exe:fpr && cp "$$(cabal list-bin fpr)" fpr; \
	else \
	  ghc -o build/Setup Setup.hs >/dev/null && \
	  ./build/Setup configure --ghc >/dev/null && \
	  ./build/Setup build 2>&1 | tail -1 && \
	  cp dist/build/fpr/fpr fpr; \
	fi
	ln -sf fpr fprc

fprc: fpr

# ---- the std proof pass ------------------------------------------------
stdcheck: fprc
	./fprc --stdcheck $(FILE)

# ---- BareMetal profile -------------------------------------------------
$(BUILD)/prog.s: fprc $(PROG) core/prelude.fpr FORCE
	@mkdir -p $(BUILD)
	LC_ALL=C.UTF-8 ./fprc --system=bare-metal $(FPRC_FLAGS) --prelude=core/prelude.fpr $(PROG) $@

# the virt HAL's PLIC and CLINT drivers are FP-RISC (hal/virt/virt.mk)
FPRC ?= ./fprc
include $(HAL)/virt/virt.mk
bare-metal: $(BUILD)/prog.s $(RT_VIRT) $(VIRT_FPR) $(EXTRA_RT) $(RT_CORE) $(HAL)/virt/link.ld
	$(CROSS)gcc $(CFLAGS) -T $(HAL)/virt/link.ld -I$(HAL)/core -I$(HAL)/virt \
	  $(RT_VIRT) $(VIRT_FPR) $(EXTRA_RT) $(BUILD)/prog.s $$(cat $(BUILD)/prog.s.units) $(RT_CORE) -o $(IMAGE)

bare-metal-run: bare-metal
	$(TIMEOUT) 20 $(QEMU) $(ACCEL) -machine virt -smp $(HARTS) -m 256M \
	  -nographic -bios none -kernel $(IMAGE)

# ---- Base profile: an executable for this machine (hal/posix) -----------
# `make posix PROG=x.fpr` is what `./fpr build x.fpr` does, spelled out:
# the program lowered for the host ISA, linked with the shared core and
# the hosted HAL by the host's C compiler.  Harts are pthreads.
POSIXHARTS ?= 2
ifneq ($(filter aarch64 arm64,$(shell uname -m)),)
POSIXCTX = $(HAL)/unix/ctx_a64.S
else
POSIXCTX = $(HAL)/unix/ctx_x64.S
endif
ifeq ($(shell uname -s),Linux)
POSIXLDFLAGS ?= -no-pie
endif
RT_POSIX = $(HAL)/posix/main.c $(HAL)/posix/hal.c $(HAL)/posix/base.c \
           $(HAL)/posix/heap.S $(POSIXCTX)
BIN ?= $(BUILD)/$(basename $(notdir $(PROG)))
$(BUILD)/base.s: fprc $(PROG) core/prelude.fpr FORCE
	@mkdir -p $(BUILD)
	LC_ALL=C.UTF-8 ./fprc --system=posix --prelude=core/prelude.fpr $(PROG) $@

posix: $(BUILD)/base.s $(RT_POSIX) $(RT_CORE)
	$(CC) -O2 -Wall -Wextra -DFPR_POSIX -DFPR_NHARTS=$(POSIXHARTS) $(POSIXLDFLAGS) -I$(HAL)/core -I$(HAL)/posix \
	  $(BUILD)/base.s $$(cat $(BUILD)/base.s.units) $(RT_POSIX) $(RT_CORE) -lpthread -lm -o $(BIN)

posix-run: posix
	$(BIN) $(ARGS)
.PHONY: posix posix-run

# ---- HostedBytecode profile: the sol package ---------------------------
sol: fpr
	@echo "the HostedBytecode profile is: ./fpr sol <script.sol>"

clean-cabal:
	rm -rf dist dist-newstyle build/Setup

clean:
	rm -rf build image.elf app.qa fpr fprc compiler/*.o compiler/*.hi compiler/Sol/*.o compiler/Sol/*.hi compiler/cbits/*.o

FORCE:
.PHONY: all stdcheck bare-metal bare-metal-run sol clean FORCE

# Unsafe standalone Builtin profile: no actors, devices, QOS or prelude.
#
# The allocator is hal/builtin/heap.fpr: FP-RISC over typed layouts
# (docs/LAYOUTS.md), compiled as a LIBRARY unit (--lib) whose exports are
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
BUILTIN_HEAP = $(HAL)/builtin/heap.c
endif
# one line: a backslash continuation inside a variable becomes a space,
# and a space splits the --export= argument
HEAP_EXPORTS = heapInit:fpr_builtin_heap_init,inHeap:fpr_in_heap,alloc:fpr_alloc,free:fpr_free,realloc:fpr_realloc,retain:fpr_builtin_retain,release:fpr_builtin_release,allocAdt:fpr_builtin_alloc_adt,liveAllocations:fpr_builtin_live_allocations,setLayout:fpr_builtin_set_layout,fieldCount:fpr_builtin_field_count,fieldKind:fpr_builtin_field_kind
$(BUILD)/heap.s: fprc $(HAL)/builtin/heap.fpr FORCE
	@mkdir -p $(BUILD)
	./fprc --system=bare-metal --profile=builtin --arc --raw --lib --export=$(HEAP_EXPORTS) $(HAL)/builtin/heap.fpr $@
BUILTIN_RT = $(HAL)/builtin/crt0.S $(HAL)/builtin/virt.c $(BUILTIN_HEAP) \
             $(HAL)/builtin/unsafe.c $(HAL)/builtin/arc.c $(HAL)/builtin/machine.S $(HAL)/builtin/interrupt.S $(HAL)/core/runtime.c $(HAL)/virt/memshim.c
ifeq ($(ARC),1)
BUILTIN_COMPILER_FLAGS = --arc
BUILTIN_CFLAGS = -DFPR_BUILTIN_ARC -DFPR_BUILTIN_RAW
endif

# ---- a library unit: FP-RISC compiled to a linkable object with C exports
#   make builtin-lib LIB=path/to/x.fpr LIB_EXPORT=f:c_f,g   -> $(BUILD)/lib-x.s
# Link the .s into any builtin image (BUILTIN_EXTRA=...) or assemble it
# with $(CROSS)gcc -c for an archive; the exported symbols use the plain
# RV64 C ABI (docs/BAREMETAL-BUILTIN.md, "Library units and C exports").
LIB ?= hal/builtin/heap.fpr
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
bare-metal-builtin: fprc $(BUILTIN_RT) $(HAL)/builtin/link.ld FORCE
	@mkdir -p $(BUILD)
	./fprc --system=bare-metal --profile=builtin $(BUILTIN_COMPILER_FLAGS) $(FPRC_FLAGS) $(PROG) $(BUILD)/builtin.s
	$(CROSS)gcc $(CFLAGS) -UFPR_NHARTS -DFPR_NHARTS=1 -DFPR_BUILTIN $(BUILTIN_CFLAGS) -ffunction-sections -fdata-sections \
	  -Wl,--gc-sections -T $(HAL)/builtin/link.ld -I$(HAL)/core -I$(HAL)/builtin \
	  $(BUILTIN_RT) $(BUILD)/builtin.s $$(cat $(BUILD)/builtin.s.units) $(BUILTIN_EXTRA) $(BUILTIN_LDFLAGS) -o $(IMAGE)

bare-metal-builtin-run: bare-metal-builtin
	$(QEMU) -machine virt -smp 1 -m 128M -nographic -bios none -kernel $(IMAGE)
.PHONY: bare-metal-builtin bare-metal-builtin-run
