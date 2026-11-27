"""Translate the pinned C3 Wi-Fi bindgen ABI into C declarations."""
import argparse
from pathlib import Path
import re

from audit import verify_package

STRUCTS = (
    "wifi_osi_funcs_t", "wpa_crypto_funcs_t", "wifi_init_config_t",
    "wifi_active_scan_time_t", "wifi_scan_time_t", "wifi_scan_channel_bitmap_t",
    "wifi_scan_config_t", "wifi_country_t", "wifi_pmf_config_t",
    "wifi_scan_threshold_t", "wifi_bss_max_idle_config_t", "wifi_ap_config_t",
    "wifi_sta_config_t", "wifi_nan_sync_config_t", "wifi_config_t",
    "coex_adapter_funcs_t", "wifi_he_ap_info_t", "wifi_ap_record_t",
)
CONSTANTS = ("ESP_WIFI_OS_ADAPTER_VERSION", "ESP_WIFI_OS_ADAPTER_MAGIC",
             "WIFI_INIT_CONFIG_MAGIC", "COEX_ADAPTER_VERSION", "COEX_ADAPTER_MAGIC")
OPTION = "::core::option::Option<"
FUNCTION = 'unsafe extern "C" fn('
PRIMITIVES = {
    "()": "void", "bool": "bool", "usize": "size_t", "isize": "ptrdiff_t",
    **{f"{prefix}{width}": f"{signed}int{width}_t"
       for prefix, signed in (("u", "u"), ("i", "")) for width in (8, 16, 32, 64)},
}
C_TYPES = {
    "c_void": "void", "c_char": "char", "c_int": "int", "c_uint": "unsigned int",
    "c_uchar": "unsigned char", "c_schar": "signed char",
    "c_short": "short", "c_ushort": "unsigned short",
    "c_long": "long", "c_ulong": "unsigned long",
    "c_longlong": "long long", "c_ulonglong": "unsigned long long",
}


def arguments(text):
    """Split a Rust parameter list outside nested callback types."""
    depth, start = 0, 0
    for i, char in enumerate(text):
        if char in "(<[":
            depth += 1
        elif char in ")]" or (char == ">" and text[i-1] != "-"):
            depth -= 1
        elif char == "," and depth == 0:
            yield text[start:i].strip()
            start = i + 1
    if text[start:].strip():
        yield text[start:].strip()


class Bindings:
    def __init__(self, source):
        self.source = source
        self.aliases = dict(re.findall(r"^pub type (\w+)\s*=\s*(.*?);", source, re.M | re.S))

    def declaration(self, name):
        return re.search(rf"^pub (struct|union) {name} \{{(.*?)^\}}", self.source, re.S | re.M)

    def fields(self, struct):
        body = self.declaration(struct)[2]
        body = re.sub(r"^    #\[.*?\]$", "", body, flags=re.M)
        parts = re.split(r"^    pub (\w+):\s*", body, flags=re.M)
        if parts[0].strip() or len(parts) % 2 != 1:
            raise ValueError(f"Unexpected {struct} field layout")
        return [(name, value.strip().rstrip(",").strip())
                for name, value in zip(parts[1::2], parts[2::2])]

    def c_type(self, ty, name="", qualification=""):
        if ty.startswith(OPTION):
            ty = ty[len(OPTION):-1].strip().rstrip(",").strip()
        if ty.startswith(FUNCTION):
            body = ty[len(FUNCTION):]
            count, close = 1, 0
            for close, char in enumerate(body):
                count += (char == "(") - (char == ")")
                if count == 0:
                    break
            if count:
                raise ValueError(f"Unbalanced callback declaration: {ty}")
            result = body[close+1:].strip()
            result = result.removeprefix("->").strip() if result else "()"
            params = []
            for arg in arguments(body[:close]):
                params.append("..." if arg == "..." else self.c_type(arg.split(":", 1)[1].strip()))
            return self.c_type(result, f"(*{qualification}{name})({', '.join(params) or 'void'})")
        ptr = re.match(r"^\*(mut|const) (.*)$", ty)
        if ptr:
            const = "const " if ptr[1] == "const" else ""
            return self.c_type(ptr[2], f"*{qualification}{name}", const)
        bitfield = re.fullmatch(r"__BindgenBitfieldUnit<(.+)>", ty)
        if bitfield:
            return self.c_type(bitfield[1], name, qualification)
        array = re.fullmatch(r"\[([^;]+);\s*(\d+)(?:usize)?\]", ty)
        if array:
            return self.c_type(array[1], f"{name}[{array[2]}]", qualification)
        if ty in self.aliases:
            return self.c_type(self.aliases[ty].strip(), name, qualification)
        if ty in STRUCTS:
            base = ty
        elif ty.startswith("crate::c_types::"):
            base = C_TYPES[ty.rsplit("::", 1)[1]]
        else:
            base = PRIMITIVES[ty]
        return f"{qualification}{base} {name}".strip()

    def emit(self):
        print("#pragma once\n#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>")
        for name in CONSTANTS:
            value = re.search(rf"^pub const {name}: u32 = (\d+);", self.source, re.M)[1]
            print(f"#define {name} UINT32_C({value})")
        for name in STRUCTS:
            kind = self.declaration(name)[1]
            print(f"typedef {kind} {{")
            for field, ty in self.fields(name):
                print(f"    {self.c_type(ty, field)};")
            print(f"}} {name};")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="locked esp-wifi-sys checkout")
    args = parser.parse_args()
    verify_package(args.package)
    bindings = args.package / "esp-wifi-sys-esp32c3/src/include.rs"
    Bindings(bindings.read_text()).emit()
