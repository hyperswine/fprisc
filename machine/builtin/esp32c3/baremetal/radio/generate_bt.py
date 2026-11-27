"""Extract C3 PHY bytes and C config layout from the pinned reference trees."""
import re
import sys
from pathlib import Path

from audit import rom_scripts, verify_package

package = Path(sys.argv[1])
reference = Path(sys.argv[2])
lock = verify_package(package)
scripts = rom_scripts(reference, lock["esp_radio_reference"])
Path("ble_rom.ld").write_text("".join(f'INCLUDE "{script.absolute()}"\n' for script in scripts))
bindings = (package / "esp-wifi-sys-esp32c3/src/include.rs").read_text()
layout = re.search(r"pub struct esp_bt_controller_config_t \{(.*?)\n\}", bindings, re.S)[1]
types = {"u8": "uint8_t", "u16": "uint16_t", "u32": "uint32_t", "bool": "bool",
         "*mut esp_bt_hci_tl_t": "void *"}
print('#include <stdbool.h>\n#include <stdint.h>\nstruct c3_btdm_config {')
for name, ty in re.findall(r"^    pub (\w+): ([^,]+),", layout, re.M):
    print(f"    {types[ty]} {name};")
print("};")

phy = (reference / "esp-phy/src/phy_init_data/phy_init_data_esp32c3.rs").read_text()
max_power = int(re.search(r"CONFIG_ESP32_PHY_MAX_TX_POWER: u8 = (\d+)", phy)[1])
data = re.search(r"params: \[(.*?)\n    \]", phy, re.S)[1]
data = re.sub(r"//[^\n]*", "", data)

def replace_limit(match):
    low, high = (int(x, 0) for x in match.groups())
    return hex(min(max(max_power * 4, low), high))

data = re.sub(r"limit\(CONFIG_ESP32_PHY_MAX_TX_POWER \* 4, (0|0x\w+), (0|0x\w+)\)",
              replace_limit, data)
values = [int(x, 0) for x in data.split(",") if x.strip()]
if len(values) != 128:
    raise ValueError(f"Expected 128 PHY initialization bytes, got {len(values)}")
print("#ifdef C3_PHY_INIT_DATA_IMPLEMENTATION")
print("const uint8_t c3_phy_init_data[128] __attribute__((aligned(4))) = {")
for i in range(0, 128, 16):
    print("    " + ", ".join(f"0x{x:02x}" for x in values[i:i+16]) + ",")
print("};")
print("#endif")
