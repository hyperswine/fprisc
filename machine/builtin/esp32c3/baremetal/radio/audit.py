"""Check pinned C3 binaries and report imports reachable from BLE and Wi-Fi APIs."""
import argparse
from hashlib import sha256
import json
from pathlib import Path
import subprocess
import tempfile

PACKAGE = Path("esp-wifi-sys-esp32c3")
COMMON = ("libphy.a", "libcoexist.a", "libprintf.a")
MODES = {
    "ble": (
        ("libbtdm_app.a", "libbtbb.a") + COMMON,
        ("btdm_osi_funcs_register", "btdm_controller_init", "btdm_controller_enable",
         "btdm_controller_disable", "btdm_controller_deinit", "API_vhci_host_send_packet",
         "API_vhci_host_check_send_available", "API_vhci_host_register_callback"),
    ),
    "wifi": (
        ("libcore.a", "libespnow.a", "libmesh.a", "libnet80211.a", "libpp.a",
         "libregulatory.a", "libsmartconfig.a", "libwapi.a", "libwpa_supplicant.a") + COMMON,
        ("esp_wifi_init_internal", "esp_wifi_start", "esp_wifi_stop", "esp_wifi_scan_start",
         "esp_wifi_set_config", "esp_wifi_connect_internal", "esp_wifi_disconnect_internal", "esp_wifi_internal_tx"),
    ),
}


def audit(source, mode, prefix):
    lock = json.loads(Path(__file__).with_name("archives.json").read_text())
    for name, expected in lock["sha256"].items():
        if sha256((source / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f"SHA-256 mismatch for {name}")

    archives, roots = MODES[mode]
    symbols = [argument for root in roots for argument in ("-u", root)]
    inputs = [source / PACKAGE / "libs" / library for library in archives]
    with tempfile.TemporaryDirectory(prefix="fpr-c3-radio-") as directory:
        obj = Path(directory) / "radio.o"
        subprocess.run([prefix + "ld", "-r", "--gc-sections", "-o", obj, *symbols,
                        "--start-group", *inputs, "--end-group"], check=True)
        output = subprocess.check_output([prefix + "nm", "-g", "-P", obj], text=True)
    entries = [line.split() for line in output.splitlines() if line.strip()]
    defined = {entry[0] for entry in entries if entry[1] in ("T", "W")}
    if missing := set(roots) - defined:
        raise ValueError(f"Missing expected API exports: {', '.join(sorted(missing))}")
    imports = sorted(entry[0] for entry in entries if entry[1] in ("U", "v", "w"))
    print(f"{mode} {lock['revision']}: {len(imports)} external symbols")
    print("\n".join(imports))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="pinned esp-wifi-sys checkout")
    parser.add_argument("mode", choices=MODES)
    parser.add_argument("--prefix", default="riscv32-esp-elf-", help="RV32 GNU tool prefix")
    args = parser.parse_args()
    audit(args.source, args.mode, args.prefix)
