# ESP32-C3 wireless ABI and BLE observer

The lock pins the exact esp-wifi-sys package revision used by the listed
esp-radio reference. Its C3 BLE archive expects OSI callback ABI
0x0001000B. The earlier raw archive identified by the esp-radio README
expects 0x00010007. Keep the packaged archives and bindings together.

    python3 audit.py /path/to/esp-wifi-sys ble
    python3 audit.py /path/to/esp-wifi-sys wifi

The audit verifies the locked package digests and performs relocatable
links rooted at the controller entry points. The reported imports include
ROM exports, compiler helpers and platform services. Services accessed
indirectly through callback tables require inspection of the matching
callback ABI. The lock also records the upstream Apache and MIT license
digests.

## BLE advertisement

The HCI helper encodes a controller reset and a nonconnectable
advertisement for a 128-bit service UUID, then validates the corresponding
command completions. The controller adapter must send commands in order
and retain each command buffer until VHCI signals send availability.

Run the host packet vectors and build the CoreBluetooth observer on macOS
from this directory.

    cc -std=c11 -Wall -Wextra -Werror hci.c hci_vectors.c -o hci-vectors
    ./hci-vectors
    swiftc observe.swift -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker BluetoothInfo.plist -o c3-ble-observer
    ./c3-ble-observer 43AA9E7E-1EA0-4AB4-A7C2-1A280B18B13C

The Mac reports success only if CoreBluetooth sees the service UUID in
an advertisement. A live Bluetooth scan can be checked independently of
controller initialization. See the [Bluetooth Core HCI specification](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core_v7.0/out/en/host-controller-interface/host-controller-interface--hci--functional-specification.html)
and [CoreBluetooth CBCentralManager documentation](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager).

## Controller services

btdm_abi.h describes the pinned C3 BTDM and VHCI callback layouts for
RV32. Its sizes and critical offsets are checked at compile time.
Copyright and license for the adapted ABI declarations are in
LICENSE-ESP-RADIO-MIT.

The service layer has bounded task slots, caller-owned stacks and FIFO
storage, priority-ordered wakeups, and deadline-aware waits. Task context
switches occur at explicit yield or blocking points with interrupts
masked. An ISR can make a waiter ready. The current service layer does
not preempt a running task.

Run tests/check-tasks.sh with the C3 GCC toolchain and qemu-system-riscv32.
It exercises the actual RV32 context switch, timed and indefinite waits,
ISR-style wakeups, full and empty queues, and semaphore limits. Clock
and idle are test hooks in this check.

btdm_services.c installs the task, queue, semaphore, mutex and clock
callbacks into the pinned table. It reserves up to two controller task
stacks of 8 KiB each and four 1 KiB queue buffers. The adapter translates
controller ticks to 1 ms and reserves UINT32_MAX for indefinite waits.
task_clock.c supplies the SYSTIMER clock and deadline wakeup for the C3.
The callback vectors run with a simulated clock on RV32 and cover
blocking, ISR wake notification, and deletion of a blocked task. Board
interrupt registration, the allocator, and PHY initialization are
separate from these services.
