"""Generate C3 FTM constants referenced by the pinned Wi-Fi archive."""
import re
from pathlib import Path
import sys

source = Path(sys.argv[1]) / "esp-radio/src/wifi/ftm_calibration.rs"
text = source.read_text()
block = re.search(r"#\[cfg\(esp32c3\)\]\s*mod values \{(.*?)\n\}", text, re.S)[1]
values = dict(re.findall(r"pub const (\w+): u16 = (\d+);", block))
print("#include <stdint.h>")
for symbol, key in dict(re.findall(r"\b(est_PHY_\w+) = values::(\w+);", text)).items():
    print(f"const uint16_t {symbol} = {values[key]};")
