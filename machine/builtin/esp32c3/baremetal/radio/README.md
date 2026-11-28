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

btdm_irq.c maps the controller's BT baseband request to separate BT_BB
and RWBT CPU lines, and the RWBLE request to its own line. It preserves
the timer and GPIO lines and marks callback execution as ISR context.
The RV32 test checks the route, enable, disable, and release sequences
with a simulated interrupt-matrix register block. RF interrupt delivery
requires a physical controller test.

Use --rom-reference with the pinned esp-hal checkout to resolve C3 ROM
symbols during the audit. The audit reads the active ROM map includes and
keeps additional software fallbacks in the unresolved set. The pinned
BLE roots leave nine imports after this step. The Wi-Fi roots leave 59.
These counts cover the root-selected link, with controller callbacks and
runtime initialization outside the import count.

## Build the BLE bring-up image

Set C3_RADIO_SYS and C3_RADIO_REF to checkouts at the commits in
archives.json. The esp-hal reference checkout needs esp-phy and
esp-rom-sys. From the FP-RISC repository root, run the C3 build script
with the BLE example.

    machine/builtin/esp32c3/baremetal/build.sh build/c3-ble ble flash

The build generates the C controller configuration layout and PHY data
from the pinned sources, then links the FP-RISC guest, C adapter, C3 ROM
map, and BLE controller archives. Its linker script gives code and data
separate SRAM ranges. The allocation callbacks use a 24 KiB radio arena.
The flash image prints each initialization phase over USB after the
console identity query. The end-to-end test requires the C3 to print
FPR BLE ADVERTISING and the Mac to discover the service UUID over the air.

On the C3 bench board, the Mac discovered the service UUID on the
initial start and after three controller stop/start cycles. Peak radio
heap use was 23,488 bytes. Each stop returned live radio allocations to
zero. The OTA test restored the original firmware and selection and
verified the journal digest.

## Wi-Fi callback ABI

Generate C declarations for the version 9 Wi-Fi adapter and its
configuration and scan types from the locked bindings.

    python3 generate_wifi.py /path/to/esp-wifi-sys > wifi_config.h
    python3 check_wifi_layout.py /path/to/esp-wifi-sys

The layout check compares every struct size, alignment, and field offset
produced by RV32 GCC against the pinned Rust bindings. It uses rustc with
the riscv32imc-unknown-none-elf target installed. The C generator itself
requires Python. The RV32 task vectors also cover queue front insertion
and event groups, including multiple waiters observing the same bits.

The Wi-Fi callback binder shares controller task slots with BLE and adds
thread-local semaphores, timer callbacks, allocation services, and Wi-Fi
MAC and power interrupt routing. A dedicated task dispatches one-shot
and repeating timers using microsecond deadlines. Set C3_RADIO_SYS when
running tests/check-tasks.sh to generate the locked Wi-Fi header and
exercise the callbacks through the vendor ABI. The emulator uses a
simulated clock and interrupt matrix.

## Build the passive Wi-Fi scan image

Use the same C3_RADIO_SYS and C3_RADIO_REF pins as the BLE build.

    machine/builtin/esp32c3/baremetal/build.sh build/c3-wifi wifi flash

The image includes the C3 driver's compiled IRAM functions, mapped flash
code and constants, and a 64 KiB SRAM allocation arena. The FP-RISC scan
guest starts a station with power saving disabled, requests a passive
scan of channels 1 through 11, reports the AP count over USB, and stops
the controller. This image uses no network credentials. It prints
FPR WIFI SCAN APs and FPR DONE when the scan and shutdown complete.
The C3 bench board detected three access points in a standalone passive
scan and shut down cleanly. The OTA runner verified restoration of the
original firmware and journal digest.

## Station packet probe

The station data-path helper answers ARP and IPv4 ICMP echo on a local
test network. It uses a caller-supplied IPv4 and MAC address. The receive
callback queues up to four vendor RX buffers. The main task releases
each buffer once and uses the vendor's copy-on-transmit API for replies.
Traffic outside the supported local packet formats is ignored.

From this directory, the host vectors check whole reply frames, packet
truncation, checksum failures, and RX buffer ownership.

    cc -std=c11 -Wall -Wextra -Werror -I. net_probe.c wifi_probe.c tests/net_vectors.c -o net-vectors
    ./net-vectors

The station test configuration is provisioned over USB at runtime. The
decoder accepts an open or WPA2-personal test SSID and a caller-selected
IPv4 address on the test network. The configuration field layouts are
checked against the pinned RV32 bindings. The password is held in the
configuration buffer in SRAM and can be cleared after the driver has
copied it.

Build the station qualification image with the same two pinned checkouts
used by the scan image.

    machine/builtin/esp32c3/baremetal/build.sh build/c3-station wifi-sta flash

After booting the image in a test slot, run check_station.py on a Mac
connected to the test access point with the board serial port, SSID, and
an unused private IPv4 address in that subnet. The host prompts locally
for the WPA2 passphrase. Add --open for an open test AP. The firmware
uses the driver's RAM configuration and clears its temporary passphrase
buffer after configuration. It sends no credentials back over USB.

The verifier requires a Mac ping reply and a matching rise in the
device's ICMP echo count. With --reconnect it waits for link loss and a
second association after restarting the test AP. Entering Q over USB
stops the station and releases the Wi-Fi controller.

The C3 bench board associated with a 2.4 GHz phone hotspot, reported
link loss when the hotspot was turned off, and associated again after
it was turned back on. The station shut down cleanly and the OTA
runner verified firmware and journal restoration. That setup still
needs packet-path verification. The Mac received no ICMP reply and
did not resolve the station's static IPv4 address over ARP. A temporary
ESP-IDF reference image on the same board and hotspot received a DHCP
lease and an ICMP reply from the phone. A diagnostic bare-metal build
reported successful radio transmissions of DHCP discovery frames, with
zero receive callbacks during the test window.

## Combined BLE and Wi-Fi image

    machine/builtin/esp32c3/baremetal/build.sh build/c3-coex coex flash

The combined station image registers the vendor coexistence adapter,
then starts BLE advertising and the Wi-Fi station from the same Builtin
program. Both controllers share an SRAM allocator, task services, and a
reference-counted PHY. Each has its own interrupt routes. The firmware
reports device time, radio heap residency and peak, dropped RX frames,
and TX errors while the station is connected. The app releases BLE and
then Wi-Fi when it receives Q over USB.

RV32 emulator vectors exercise shared PHY acquisition and release and
retry of arbiter pre-initialization through mocked vendor entry points.
Use the Mac BLE observer and station echo checker for on-air verification.

The combined image reached Wi-Fi configuration on the C3 and advertised
the BLE service UUID while the station searched for a test SSID. The Mac
observed the advertisement at −40 dBm. Radio heap use peaked at 42,608
bytes and dropped to 18,880 bytes after BLE stopped, while Wi-Fi was
still initialized. The image then stopped Wi-Fi and returned normally.
A second run verified three BLE stop/start cycles while Wi-Fi continued
searching for the test SSID. The Mac observed every restart. The shared
radio heap returned to 18,880 live bytes after each BLE stop and peaked at
44,096 bytes. The original firmware, OTA selection, and journal digest
verified after the run. The associated-traffic endurance test requires
a test access point.

After installing the BLE or combined test image, use the compiled
CoreBluetooth observer with the matching Mac checker.

    python3 check_ble.py PORT PATH_TO_BLE_OBSERVER
    python3 check_coex.py PORT SSID STATION_IPV4 PATH_TO_BLE_OBSERVER --reconnect

The BLE verifier exercises repeated controller stop and restart while
checking post-stop heap occupancy. The coexistence verifier defaults
to a 30-minute window and repeats concurrent pings and BLE scans
throughout. It checks device sample intervals, records heap and packet
counters, then restarts BLE while the station is connected.
The optional AP restart verifies recovery in a second association.
Use an isolated test AP and an unused private station IPv4 address.

## Temporary radio qualification on the journal partition layout

radio_ota.py checks the board identity and verifies its original
partition table, slot images, OTA selector, and protected flash against
the supplied 4 MiB backup. It selects slot 0 before staging the radio
image in slot 1. On exit it restores the original slot bytes and
selection, and verifies the journal digest from just before the test.

    python3 radio_ota.py PORT ble BLE_IMAGE --mac BOARD_MAC --reference FULL_BACKUP --observer MAC_OBSERVER
    python3 radio_ota.py PORT wifi WIFI_IMAGE --mac BOARD_MAC --reference FULL_BACKUP --ssid TEST_SSID
    python3 radio_ota.py PORT wifi-sta STATION_IMAGE --mac BOARD_MAC --reference FULL_BACKUP --ssid TEST_SSID --address STATION_IPV4 --reconnect
    python3 radio_ota.py PORT coex COEX_IMAGE --mac BOARD_MAC --reference FULL_BACKUP --ssid TEST_SSID --address STATION_IPV4 --observer MAC_OBSERVER --reconnect

For station and coexistence, connect the Mac to the test AP first. Enter
the passphrase at the local prompt or pass --open for an open network.

The scan verifier checks shutdown and the AP count. With an SSID
argument it also checks for that access point without printing the
names or addresses of other APs.
