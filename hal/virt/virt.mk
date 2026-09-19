# virt.mk -- the virt HAL's FP-RISC half, for every Makefile that links it.
#
# plic.fpr and clint.fpr are raw library units (docs/LAYOUTS.md): compiled to
# assembly whose exports ARE the C symbols the runtime calls, and linked
# beside the C like any other object.  Include this AFTER defining:
#   FPRC      the compiler
#   BUILD     where intermediates go
#   VIRT_HAL  the compiler's hal/ directory (defaults to $(HAL); QOS has a
#             hal/ of its own and says $(FHAL))
# and add $(VIRT_FPR) to the link's inputs and prerequisites.
#
# rv64 only: the raw ABI has no rv32 lowering, so an rv32 image still needs a
# C driver and says so at link time (hal_irq_open ... undefined).
VIRT_HAL ?= $(HAL)
VIRT_PLIC_EXPORTS  = irqOpen:hal_irq_open,irqClaim:hal_irq_claim,irqAck:hal_irq_ack
VIRT_CLINT_EXPORTS = ipiSend:hal_ipi_send,ipiClear:hal_ipi_clear,mtime:hal_mtime,timerPark:hal_timer_park,timerArm:hal_timer_arm
VIRT_RAWFLAGS = --profile=bare-metal-builtin --arc --raw --lib

$(BUILD)/virt-plic.s: $(VIRT_HAL)/virt/plic.fpr $(FPRC)
	@mkdir -p $(BUILD)
	"$(FPRC)" $(VIRT_RAWFLAGS) --export=$(VIRT_PLIC_EXPORTS) $< $@ >/dev/null
$(BUILD)/virt-clint.s: $(VIRT_HAL)/virt/clint.fpr $(FPRC)
	@mkdir -p $(BUILD)
	"$(FPRC)" $(VIRT_RAWFLAGS) --export=$(VIRT_CLINT_EXPORTS) $< $@ >/dev/null

VIRT_FPR = $(BUILD)/virt-plic.s $(BUILD)/virt-clint.s $(VIRT_HAL)/virt/rawunit.c
