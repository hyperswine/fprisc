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
          $(HAL)/virt/hal.c $(HAL)/virt/plic.c $(HAL)/virt/net.c $(HAL)/virt/blk.c $(HAL)/virt/memshim.c

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
	LC_ALL=C.UTF-8 ./fprc --profile=bare-metal $(FPRC_FLAGS) --prelude=core/prelude.fpr $(PROG) $@

bare-metal: $(BUILD)/prog.s $(RT_VIRT) $(RT_CORE) $(HAL)/virt/link.ld
	$(CROSS)gcc $(CFLAGS) -T $(HAL)/virt/link.ld -I$(HAL)/core -I$(HAL)/virt \
	  $(RT_VIRT) $(BUILD)/prog.s $$(cat $(BUILD)/prog.s.units) $(RT_CORE) -o $(IMAGE)

bare-metal-run: bare-metal
	$(TIMEOUT) 20 $(QEMU) $(ACCEL) -machine virt -smp $(HARTS) -m 256M \
	  -nographic -bios none -kernel $(IMAGE)

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
BUILTIN_RT = $(HAL)/builtin/crt0.S $(HAL)/builtin/virt.c $(HAL)/builtin/heap.c \
             $(HAL)/builtin/unsafe.c $(HAL)/builtin/arc.c $(HAL)/builtin/machine.S $(HAL)/builtin/interrupt.S $(HAL)/core/runtime.c $(HAL)/virt/memshim.c
ifeq ($(ARC),1)
BUILTIN_COMPILER_FLAGS = --arc
BUILTIN_CFLAGS = -DFPR_BUILTIN_ARC -DFPR_BUILTIN_RAW
endif
ifneq ($(BUILTIN_HEAP_BYTES),)
BUILTIN_CFLAGS += -DFPR_BUILTIN_HEAP_BYTES=$(BUILTIN_HEAP_BYTES)
endif
ifeq ($(ARC_CHECK),1)
BUILTIN_CFLAGS += -DFPR_ARC_CHECK
endif
bare-metal-builtin: fprc $(BUILTIN_RT) $(HAL)/builtin/link.ld FORCE
	@mkdir -p $(BUILD)
	./fprc --profile=bare-metal-builtin $(BUILTIN_COMPILER_FLAGS) $(FPRC_FLAGS) $(PROG) $(BUILD)/builtin.s
	$(CROSS)gcc $(CFLAGS) -UFPR_NHARTS -DFPR_NHARTS=1 -DFPR_BUILTIN $(BUILTIN_CFLAGS) -ffunction-sections -fdata-sections \
	  -Wl,--gc-sections -T $(HAL)/builtin/link.ld -I$(HAL)/core -I$(HAL)/builtin \
	  $(BUILTIN_RT) $(BUILD)/builtin.s $$(cat $(BUILD)/builtin.s.units) $(BUILTIN_EXTRA) $(BUILTIN_LDFLAGS) -o $(IMAGE)

bare-metal-builtin-run: bare-metal-builtin
	$(QEMU) -machine virt -smp 1 -m 128M -nographic -bios none -kernel $(IMAGE)
.PHONY: bare-metal-builtin bare-metal-builtin-run
