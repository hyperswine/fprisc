"""Fail-closed linked ARM64 entry, stack, return, fuel and handoff checks."""

import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.check_aarch64_fuel import Image, admit

BASE = 0x400000
TEXT = 0x1000
ROOT_FN = "fpr_fn_path"
CHILD = "fpr_fn_child"
# Independent literal instruction words for generated root and child frames.
GUARD = [
    0xAA1C03E9,
    0x910003EA,
    0xF940E52B,
    0xCB0B014A,
    0xF940E92B,
    0xEB0B015F,
    0x540000A3,
    ("bl", "fpr_stack_grow"),
    0xB4000040,
    0x9100001F,
    0xAA1C03E9,
]
TICK = [
    0xF840012A,
    0xD100054A,
    0xF800012A,
    0xF100015F,
    0x5400004C,
    ("bl", "fpr_fuel_save_local"),
]
SAVE = [
    0xA9B37BFD,
    0x910003FD,
    0xA90107E0,
    0xA9020FE2,
    0xA90317E4,
    0xA9041FE6,
    0xA90527E8,
    0xA9062FEA,
    0xA90737EC,
    0xA9083FEE,
    0x6D0907E0,
    0x6D0A0FE2,
    0x6D0B17E4,
    0x6D0C1FE6,
    ("bl", "fpr_fuel_exhausted"),
]


def executable(root=None, child=None, save=None):
    if root is None:
        root = [
            0xD10083FF,
            0xA9017BFD,
            0x910083FD,
            *GUARD,
            *TICK,
            ("bl", CHILD),
            0xA9417BFD,
            0x910083FF,
            0xD65F03C0,
        ]
    if child is None:
        child = [
            0xD10043FF,
            0xA9007BFD,
            0x910043FD,
            *GUARD,
            *TICK,
            0xA9407BFD,
            0x910043FF,
            0xD65F03C0,
        ]
    groups = {
        ROOT_FN: root,
        CHILD: child,
        "fpr_stack_grow": [0xD65F03C0],
        "fpr_fuel_save_local": SAVE if save is None else save,
        "fpr_fuel_exhausted": [0xD65F03C0],
        "foreign": [0xD65F03C0],
    }
    addresses = {}
    words = []
    for name, code in groups.items():
        addresses[name] = BASE + 4 * len(words)
        words += code
    for i, w in enumerate(words):
        if isinstance(w, tuple):
            kind, name = w
            delta = (addresses[name] - (BASE + 4 * i)) // 4
            words[i] = (0x94000000 if kind == "bl" else 0x14000000) | (
                delta & 0x3FFFFFF
            )
    code = struct.pack("<" + "I" * len(words), *words)
    strings = bytearray(b"\0")
    symbols = bytearray(24)
    for name, addr in addresses.items():
        symbols += struct.pack(
            "<IBBHQQ", len(strings), 0x12, 0, 1, addr, 4 * len(groups[name])
        )
        strings += name.encode() + b"\0"
    symoff = TEXT + len(code)
    stroff = symoff + len(symbols)
    shoff = stroff + len(strings)
    image = bytearray(shoff + 4 * 64)
    image[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into(
        "<HHIQQQIHHHHHH", image, 16, 2, 183, 1, BASE, 64, shoff, 0, 64, 56, 1, 64, 4, 0
    )
    struct.pack_into(
        "<IIQQQQQQ", image, 64, 1, 5, TEXT, BASE, BASE, len(code), len(code), 4096
    )
    image[TEXT:symoff] = code
    image[symoff:stroff] = symbols
    image[stroff:shoff] = strings
    for j, sec in enumerate(
        [
            (0, 1, 6, BASE, TEXT, len(code), 0, 0, 4, 0),
            (0, 2, 0, 0, symoff, len(symbols), 3, 1, 8, 24),
            (0, 3, 0, 0, stroff, len(strings), 0, 0, 1, 0),
        ],
        1,
    ):
        struct.pack_into("<IIQQQQIIQQ", image, shoff + j * 64, *sec)
    return bytes(image)


class FuelTests(unittest.TestCase):
    def test_exact_composed_calls(self):
        im = Image(executable())
        for fuel, count, window, stack, outcome in [
            (1, 31, 32, 240, "fuel_runtime"),
            (2, 47, 48, 256, "fuel_runtime"),
            (3, 37, 48, 48, "return"),
        ]:
            proof = admit(im, ROOT_FN, fuel, count, window, stack)
            self.assertEqual(list(proof["outcomes"]), [outcome])
            self.assertEqual(
                (
                    proof["required"],
                    proof["stack_window_bytes"],
                    proof["writable_stack_bytes"],
                ),
                (count, window, stack),
            )
            for ceiling, room, storage, why in [
                (count - 1, window, stack, "instruction budget"),
                (count, window - 1, stack, "stack-window"),
                (count, window, stack - 1, "writable stack"),
            ]:
                with self.assertRaisesRegex(ValueError, why):
                    admit(im, ROOT_FN, fuel, ceiling, room, storage)

    def test_corrupt_protocol_entries(self):
        for offset in range(len(GUARD) + len(TICK)):
            blob = bytearray(executable())
            struct.pack_into("<I", blob, TEXT + (3 + offset) * 4, 0xD503201F)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                admit(Image(blob), ROOT_FN, 1, 150)
        for offset in range(len(SAVE)):
            corrupted = SAVE.copy()
            corrupted[offset] = 0xD503201F
            with self.assertRaises(ValueError):
                admit(Image(executable(save=corrupted)), ROOT_FN, 1, 150)

    def test_opaque_work_and_unrestored_abi(self):
        for code, why in [
            ([("bl", "foreign")], "unproved call"),
            ([("b", "foreign")], "unproved runtime entry"),
            ([0xD63F0000], "unproved instruction"),
            ([0xAA0003FC], "hart register"),
            ([0xB240001F], "SP write"),
            ([0xAA0003F3, 0xD65F03C0], "unrestored return"),
            ([("bl", CHILD), 0xD65F03C0], "unrestored return"),
            ([0xF90003E0, 0xD65F03C0], "out-of-frame"),
            ([0xF9400000, 0xD65F03C0], "memory base"),
            ([("b", ROOT_FN)], "cycle"),
            ([("bl", ROOT_FN)], "recursive call"),
        ]:
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, why):
                admit(Image(executable(root=code)), ROOT_FN, 10, 100)

    def test_all_branch_arms_and_operand_facts(self):
        # cbz x0,+8 ; bl foreign ; ret. Without a word premise the
        # foreign path is reachable. The zero premise proves it is skipped.
        im = Image(executable(root=[0xB4000040, ("bl", "foreign"), 0xD65F03C0]))
        for args in ({}, {0: 1}):
            with self.assertRaisesRegex(ValueError, "unproved call"):
                admit(im, ROOT_FN, 4, 100, arguments=args)
        self.assertEqual(admit(im, ROOT_FN, 4, 100, arguments={0: 0})["required"], 2)
        both = Image(executable(root=[0xB4000040, 0xD503201F, 0xD65F03C0]))
        self.assertEqual(admit(both, ROOT_FN, 4, 100)["required"], 3)
        with self.assertRaisesRegex(ValueError, "verifier work budget"):
            admit(both, ROOT_FN, 4, 100, analysis_limit=1)

    def test_checked_integer_home_and_overflow_edges(self):
        # Extract two signed tagged integers, add, sign-extend 63 bits,
        # and take the ordinary return only when that matches the sum.
        code = [
            0x9341FC09,
            0x9341FC4A,
            0x8B0A012A,
            0x9340F94B,
            0xEB0A017F,
            0x54000040,
            ("bl", "foreign"),
            0xD65F03C0,
        ]
        image = Image(executable(root=code))
        lo, hi = -(1 << 62), (1 << 62) - 1
        for a, b in [(lo, 0), (hi, 0), (lo, hi), (-4, 3), (lo, -1), (hi, 1)]:
            args = {i: ((x << 1) | 1) % (1 << 64) for i, x in [(0, a), (2, b)]}
            if lo <= a + b <= hi:
                self.assertEqual(
                    admit(image, ROOT_FN, 4, 100, arguments=args)["required"], 7
                )
            else:
                with self.assertRaisesRegex(ValueError, "unproved call"):
                    admit(image, ROOT_FN, 4, 100, arguments=args)
        with self.assertRaisesRegex(ValueError, "unproved call"):
            admit(image, ROOT_FN, 4, 100)

    def test_writable_stack_and_continuation_provenance(self):
        for root, reason in [
            (
                [
                    0xD10043FF,
                    0xF90007FE,
                    0xF80093E0,
                    0xF94007FE,
                    0x910043FF,
                    0xD65F03C0,
                ],
                "out-of-frame",
            ),
            (
                [
                    0xD10043FF,
                    0xF90007FE,
                    0xF90007E0,
                    0xF94007FE,
                    0x910043FF,
                    0xD65F03C0,
                ],
                "unrestored return",
            ),
            ([0xD10043FF, ("b", CHILD)], "unrestored tail transfer"),
        ]:
            with self.assertRaisesRegex(ValueError, reason):
                admit(Image(executable(root=root)), ROOT_FN, 1, 100)

    def test_full_quantum_loop(self):
        root = [0xAA1C03E9, *TICK, 0x17FFFFF9]  # back to hart reload
        d = admit(Image(executable(root=root)), ROOT_FN, 2000, 20000)
        self.assertEqual(d["required"], (2000 - 1) * 7 + 6 + 16)
        self.assertEqual(d["outcomes"]["fuel_runtime"]["max_ticks"], 2000)

    def test_elf_identity_and_cli_refusals_preserve_files(self):
        raw = executable()
        for pos, val in [(16, 3), (18, 62), (68, 7)]:
            b = bytearray(raw)
            b[pos] = val
            with self.assertRaises(ValueError):
                Image(b)
        with tempfile.TemporaryDirectory() as td:
            image = Path(td) / "app"
            image.write_bytes(raw)
            record = Path(td) / "report"
            cmd = [
                sys.executable,
                ROOT / "tools/check_aarch64_fuel.py",
                image,
                "--entry",
                ROOT_FN,
                "--fuel",
                "3",
                "--max-instructions",
                "37",
                "--window-bytes",
                "48",
                "--writable-bytes",
                "48",
                "--record",
                record,
            ]
            q = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(q.returncode, 0, q.stderr)
            before = record.read_bytes()
            self.assertEqual(json.loads(before)["required"], 37)
            for extra in [
                ["--max-instructions", "36"],
                ["--word", "x28=1"],
                ["--record", image],
            ]:
                self.assertNotEqual(
                    subprocess.run(cmd + extra, capture_output=True).returncode, 0
                )
                self.assertEqual(record.read_bytes(), before)
                self.assertEqual(image.read_bytes(), raw)


if __name__ == "__main__":
    unittest.main()
