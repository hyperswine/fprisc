# virt.mk -- the virt MACHINE LAYER's FP-RISC half, for every Makefile that links it.
#
# clint.fpr is a raw library unit (docs/LAYOUTS.md): compiled to assembly whose
# exports ARE the C symbols the runtime calls (hal_ipi_send, hal_mtime,
# hal_timer_arm, ...), linked beside the C like any other object.  It is here,
# and not in a HAL, because the SCHEDULER needs it: the doorbell that wakes a
# hart and the timer that bounds its sleep.  Device drivers -- the PLIC, the
# virtio net and block devices, the pin bus -- are a HAL's, and live in QOS
# (qos/hal/virt, qos-virt.mk).  docs/HAL.md.
#
# Include this AFTER defining:
#   FPRC      the compiler
#   BUILD     where intermediates go
#   VIRT_HAL  the compiler's hal/ directory (defaults to $(HAL); QOS has a
#             hal/ of its own and says $(FHAL))
# and add $(VIRT_FPR) to the link's inputs and prerequisites.
#
# rv64 only: the raw ABI has no rv32 lowering, so an rv32 image keeps the C
# (hal.c, under #if __riscv_xlen == 32).
VIRT_HAL ?= $(HAL)
VIRT_CLINT_EXPORTS = ipiSend:hal_ipi_send,ipiClear:hal_ipi_clear,mtime:hal_mtime,timerPark:hal_timer_park,timerArm:hal_timer_arm
VIRT_RAWFLAGS = --profile=bare-metal-builtin --arc --raw --lib

$(BUILD)/virt-clint.s: $(VIRT_HAL)/virt/clint.fpr $(FPRC)
	@mkdir -p $(BUILD)
	"$(FPRC)" $(VIRT_RAWFLAGS) --export=$(VIRT_CLINT_EXPORTS) $< $@ >/dev/null

VIRT_FPR = $(BUILD)/virt-clint.s $(VIRT_HAL)/virt/rawunit.c
