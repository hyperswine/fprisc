#!/usr/bin/env python3
"""Image admission boundaries and preservation of the last admitted build."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.check_target_image import admit

ORIGIN = 0x80000000


def manifest(width=64, **changes):
    contract = dict(schema=1, target='fixture', elf_class_bits=width,
                    ram_origin=ORIGIN, ram_bytes=8192, max_image_bytes=4096, min_free_bytes=1024)
    return json.dumps(contract | changes).encode()


def elf(width=64, text=256, gap=0, bss=0, entry=None, extra_memory=()):
    header = struct.Struct('<HHIIIIIHHHHHH' if width == 32 else '<HHIQQQIHHHHHH')
    program = struct.Struct('<IIIIIIII' if width == 32 else '<IIQQQQQQ')
    section = struct.Struct('<IIIIIIIIII' if width == 32 else '<IIQQQQIIQQ')
    phcount = 1 + len(extra_memory)
    text_offset = max(128, (16 + header.size + phcount * program.size + 15) & ~15)
    data = bytearray(text_offset + text + 3 * section.size)
    data[:7] = b'\x7fELF' + bytes([1 if width == 32 else 2, 1, 1])
    header.pack_into(data, 16, 2, 243, 1, ORIGIN + gap if entry is None else entry,
                     16 + header.size, text_offset + text, 0, 16 + header.size, program.size, phcount, section.size, 3, 0)
    segment = ((1, text_offset, ORIGIN + gap, ORIGIN + gap, text, text + bss, 5, 1) if width == 32
               else (1, 5, text_offset, ORIGIN + gap, ORIGIN + gap, text, text + bss, 1))
    program.pack_into(data, 16 + header.size, *segment)
    for i, (address, memory) in enumerate(extra_memory, 1):
        segment = ((1, 0, address, address, 0, memory, 6, 1) if width == 32
                   else (1, 6, 0, address, address, 0, memory, 1))
        program.pack_into(data, 16 + header.size + i * program.size, *segment)
    section.pack_into(data, text_offset + text + section.size, 0, 1, 6, ORIGIN + gap, text_offset, text, 0, 0, 1, 0)
    section.pack_into(data, text_offset + text + 2 * section.size, 0, 8, 3, ORIGIN + gap + text, 0, bss, 0, 0, 1, 0)
    return bytes(data)


def patch_load(data, **changes):
    """Change the loader's contract without changing any section description."""
    data = bytearray(data)
    width = 32 if data[4] == 1 else 64
    program = struct.Struct('<IIIIIIII' if width == 32 else '<IIQQQQQQ')
    names = ('type', 'offset', 'virtual', 'physical', 'files', 'memory', 'flags', 'align') if width == 32 else (
             'type', 'flags', 'offset', 'virtual', 'physical', 'files', 'memory', 'align')
    offset = 52 if width == 32 else 64
    values = dict(zip(names, program.unpack_from(data, offset))) | changes
    program.pack_into(data, offset, *(values[k] for k in names))
    return bytes(data)


class AdmissionTests(unittest.TestCase):
    def test_both_widths_and_address_gaps(self):
        for width in (32, 64):
            result = admit(elf(width, gap=128), manifest(width))
            self.assertEqual(result['schema'], 2)
            self.assertEqual(result['image_bytes'], 384)

    def test_exact_limit_and_one_byte_over(self):
        self.assertEqual(admit(elf(text=4096), manifest())['image_bytes'], 4096)
        with self.assertRaisesRegex(ValueError, 'target limit'):
            admit(elf(text=4097), manifest())

    def test_bss_and_reserve(self):
        result = admit(elf(text=256, bss=6912), manifest())
        self.assertEqual(result['image_bytes'], 256)
        self.assertEqual(result['remaining_ram_bytes'], 1024)
        with self.assertRaisesRegex(ValueError, 'reserved'):
            admit(elf(text=256, bss=6913), manifest())

    def test_nonloaded_bytes_do_not_consume_image_budget(self):
        self.assertEqual(admit(elf() + bytes(20000), manifest())['image_bytes'], 256)

    def test_unsectioned_zero_fill_consumes_ram(self):
        for width in (32, 64):
            data = elf(width)
            result = admit(patch_load(data, memory=7168), manifest(width))
            self.assertEqual(result['image_bytes'], 256)
            self.assertEqual(result['static_memory_bytes'], 7168)
            self.assertEqual(result['remaining_ram_bytes'], 1024)
            with self.assertRaisesRegex(ValueError, 'reserved'):
                admit(patch_load(data, memory=7169), manifest(width))
            with self.assertRaisesRegex(ValueError, 'outside target RAM'):
                admit(patch_load(data, memory=8193), manifest(width))

    def test_unsectioned_file_tail_consumes_image_budget(self):
        for width in (32, 64):
            data = elf(width) + bytes(5000)
            result = admit(patch_load(data, files=4096, memory=4096), manifest(width))
            self.assertEqual(result['image_bytes'], 4096)
            with self.assertRaisesRegex(ValueError, 'target limit'):
                admit(patch_load(data, files=4097, memory=4097), manifest(width))

    def test_unsectioned_loads_and_overlap(self):
        for width in (32, 64):
            result = admit(elf(width, extra_memory=[(ORIGIN + 6144, 1024)]), manifest(width))
            self.assertEqual(result['static_memory_bytes'], 7168)
            self.assertEqual(result['image_bytes'], 256)
            with self.assertRaisesRegex(ValueError, 'reserved'):
                admit(elf(width, extra_memory=[(ORIGIN + 6144, 1025)]), manifest(width))
            with self.assertRaisesRegex(ValueError, 'outside target RAM'):
                admit(elf(width, extra_memory=[(ORIGIN + 8192, 1)]), manifest(width))
            with self.assertRaisesRegex(ValueError, 'overlapping'):
                admit(elf(width, extra_memory=[(ORIGIN, 1)]), manifest(width))
            # Empty segments occupy no RAM or boot-image bytes.
            result = admit(elf(width, extra_memory=[(ORIGIN + 8192, 0)]), manifest(width))
            self.assertEqual(result['static_memory_bytes'], 256)

    def test_load_alignment_and_address_overflow(self):
        for width in (32, 64):
            data = elf(width)
            self.assertEqual(admit(patch_load(data, align=16), manifest(width))['image_bytes'], 256)
            for align in (3, 4096):
                with self.assertRaisesRegex(ValueError, 'alignment'):
                    admit(patch_load(data, align=align), manifest(width))
            for address in (ORIGIN - 1, 2**width - 16):
                with self.assertRaisesRegex(ValueError, 'outside target RAM'):
                    admit(patch_load(data, virtual=address, physical=address), manifest(width))

    def test_wrong_width_and_entry(self):
        with self.assertRaisesRegex(ValueError, 'selected build target'):
            admit(elf(), manifest(), 'different-target')
        with self.assertRaisesRegex(ValueError, 'width'):
            admit(elf(32), manifest(64))
        with self.assertRaisesRegex(ValueError, 'entry point'):
            admit(elf(entry=ORIGIN + 1000), manifest())

    def test_outside_ram(self):
        with self.assertRaisesRegex(ValueError, 'outside target RAM'):
            admit(elf(gap=8192), manifest())

    def test_load_address_and_section_disagreement(self):
        data = bytearray(elf())
        struct.pack_into('<Q', data, 64 + 24, ORIGIN + 1)  # p_paddr
        with self.assertRaisesRegex(ValueError, 'load/run'):
            admit(data, manifest())
        data = bytearray(elf())
        struct.pack_into('<Q', data, 128 + 256 + 64 + 16, ORIGIN + 1)  # sh_addr
        with self.assertRaisesRegex(ValueError, 'load segment'):
            admit(data, manifest())

    def test_bad_and_truncated_inputs(self):
        for data in (b'', b'not ELF', elf()[:100], elf()[:-1]):
            with self.assertRaises(ValueError):
                admit(data, manifest())
        for data in (b'[]', manifest(schema=2), manifest(max_image_bytes=True), manifest(extra=1)):
            with self.assertRaises(ValueError):
                admit(elf(), data)


def build(args, expected=0):
    result = subprocess.run(['make', '-s', 'bare-metal-builtin', *args], cwd=ROOT,
                            capture_output=True, text=True, timeout=180)
    if (result.returncode == 0) != (expected == 0):
        raise AssertionError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def integration():
    records = []
    with tempfile.TemporaryDirectory(prefix='fpr-image-admission-') as directory:
        tmp = Path(directory)
        source = tmp / 'main.fpr'
        source.write_text('main = print 42.\n')
        for board, ram, width, arc in [('virt', 'bram', 64, 0), ('virt', 'bram', 64, 1),
                                       ('tangnano20k', 'bram', 32, 0), ('tangnano20k', 'sdram', 32, 0)]:
            image = tmp / f'{board}-{ram}-arc{arc}.elf'
            args = [f'PROG={source}', f'BUILD={tmp / (board + ram)}', f'IMAGE={image}',
                    f'BUILTIN_BOARD={board}', f'BUILTIN_RAM={ram}', f'ARC={arc}']
            build(args)
            receipt = Path(str(image) + '.admission.json')
            report = json.loads(receipt.read_text())
            assert report['elf_class_bits'] == width
            assert report['image_sha256'] == hashlib.sha256(image.read_bytes()).hexdigest()
            if board == 'virt':
                boot = subprocess.run(['qemu-system-riscv64', '-machine', 'virt', '-m', '128M',
                                       '-nographic', '-bios', 'none', '-kernel', str(image)],
                                      capture_output=True, text=True, timeout=20)
                assert boot.returncode == 0 and '42' in boot.stdout, boot.stdout + boot.stderr
            artifacts = [image, receipt] + ([image.with_suffix('.bin')] if board == 'tangnano20k' else [])
            before = {p: p.read_bytes() for p in artifacts}
            default = ROOT / 'machine/builtin/targets' / ('virt.json' if board == 'virt' else f'tangnano20k-{ram}.json')
            tight = tmp / 'tight.json'
            tight.write_text(json.dumps(json.loads(default.read_text()) | {'max_image_bytes': 1}))
            output = build(args + [f'BUILTIN_IMAGE_MANIFEST={tight}'], expected=1)
            assert 'target image refused:' in output and 'target limit' in output, output
            assert all(p.read_bytes() == contents for p, contents in before.items())
            mismatch = tmp / 'mismatch.json'
            mismatch.write_text(json.dumps(json.loads(default.read_text()) | {'target': 'wrong-target'}))
            output = build(args + [f'BUILTIN_IMAGE_MANIFEST={mismatch}'], expected=1)
            assert 'manifest target differs from selected build target' in output, output
            assert all(p.read_bytes() == contents for p, contents in before.items())
            stack_gate = None
            if board == 'virt':
                # A linked public entry whose frame changes independently of
                # FPR's compilation. The gate must see the selected machine
                # code, and must run before either artifact is published.
                probe = tmp / 'resource-probe.s'
                probe.write_text('.option rvc\n.text\n.balign 2\n.globl resource_probe\nresource_probe:\n c.nop\n'
                                 ' addi sp,sp,-48\n sd ra,0(sp)\n ld ra,0(sp)\n addi sp,sp,48\n ret\n')
                gated = args + [f'BUILTIN_EXTRA={probe}', 'BUILTIN_LDFLAGS=-Wl,--undefined=resource_probe']
                build(gated + ['BUILTIN_STACK_ENTRIES=resource_probe:48'])
                stack_gate = json.loads(receipt.read_text())
                assert stack_gate['schema'] == 3
                assert stack_gate['image_sha256'] == hashlib.sha256(image.read_bytes()).hexdigest()
                assert stack_gate['linked_stack']['entries'][0]['peak_bytes'] == 48
                assert stack_gate['linked_stack']['schema'] == 'linked-rv64-stack-v2'
                assert stack_gate['linked_stack']['functions'][0]['compressed_instructions'] >= 5
                admitted = {p: p.read_bytes() for p in artifacts}
                output = build(gated + ['BUILTIN_STACK_ENTRIES=resource_probe:47'], expected=1)
                assert 'needs 48 stack bytes' in output, output
                assert all(p.read_bytes() == contents for p, contents in admitted.items())
                output = build(gated + ['BUILTIN_STACK_ENTRIES=absent:48'], expected=1)
                assert 'missing stack entry' in output, output
                assert all(p.read_bytes() == contents for p, contents in admitted.items())
                # Switching off the optional gate replaces the receipt too;
                # a previous stack claim cannot survive beside a new image.
                build(args)
                plain = json.loads(receipt.read_text())
                assert plain['schema'] == 2 and 'linked_stack' not in plain
                assert plain['image_sha256'] == hashlib.sha256(image.read_bytes()).hexdigest()
            assert not list(tmp.glob('.fpr-image.*')), 'staging directory leaked'
            records.append(dict(board=board, ram=ram, arc=arc, admission=report,
                                optional_linked_stack_admission=stack_gate,
                                execution='qemu-pass' if board == 'virt' else 'not-executed',
                                refused_replacements_preserved_artifacts=True))
            print(f'{board}/{ram} ARC={arc}: linked image admitted; rejected replacements preserved all prior artifacts')
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', type=Path)
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(AdmissionTests)
    count = suite.countTestCases()
    if not unittest.TextTestRunner().run(suite).wasSuccessful():
        raise SystemExit(1)
    records = integration()
    if args.record:
        args.record.write_text(json.dumps(dict(
            schema='target-load-segments-validation-v1', unit_tests_passed=count,
            compiler_sha256=hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),
            tool_sha256=hashlib.sha256((ROOT/'tools/target-image.sol').read_bytes()).hexdigest(),
            test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            images=records), indent=2) + '\n')
