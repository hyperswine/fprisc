#!/usr/bin/env python3
"""Admit a linked builtin ELF against its selected physical target contract.

Measure load segments, including padding, address gaps and unsectioned tails,
rather than ELF file size or Core nodes. Unloaded debug tables/headers cost no
RAM; segment zero-fill counts toward RAM but not the boot image. Section
agreement and the target linker remain independent hard gates.
This is image admission, not a proof of dynamic heap/stack use or WCET.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def require(condition, message):
    if not condition:
        raise ValueError(message)


def admit(image_bytes, manifest_bytes, expected_target=None):
    contract = json.loads(manifest_bytes)
    keys = {"schema", "target", "elf_class_bits", "ram_origin", "ram_bytes",
            "max_image_bytes", "min_free_bytes"}
    require(isinstance(contract, dict) and set(contract) == keys, "invalid target manifest fields")
    for key in keys - {"target"}:
        require(type(contract[key]) is int, f"{key} must be an integer")
    require(contract["schema"] == 1, "unsupported target manifest schema")
    require(isinstance(contract["target"], str) and bool(contract["target"]), "missing target identity")
    require(expected_target is None or contract["target"] == expected_target,
            "manifest target differs from selected build target")
    width = contract["elf_class_bits"]
    require(width in (32, 64), "unsupported target ELF width")
    origin, ram = contract["ram_origin"], contract["ram_bytes"]
    limit, free = contract["max_image_bytes"], contract["min_free_bytes"]
    require(0 <= origin < 2**width and 0 < ram <= 2**width - origin, "invalid target RAM range")
    require(0 < limit <= ram and 0 <= free < ram, "invalid target image/reserve limits")

    require(len(image_bytes) >= 16 and image_bytes[:4] == b"\x7fELF", "not an ELF image")
    require(image_bytes[4] == (1 if width == 32 else 2), "ELF width differs from selected target")
    require(image_bytes[5:7] == bytes([1, 1]), "expected little-endian ELF version 1")
    header = struct.Struct("<HHIIIIIHHHHHH" if width == 32 else "<HHIQQQIHHHHHH")
    require(len(image_bytes) >= 16 + header.size, "truncated ELF header")
    (kind, machine, version, entry, phoff, shoff, _, ehsize, phsize, phcount, shsize, count, _) = header.unpack_from(image_bytes, 16)
    require(kind == 2 and machine == 243 and version == 1, "expected a linked RISC-V executable")
    require(ehsize == 16 + header.size, "invalid ELF header size")
    program = struct.Struct("<IIIIIIII" if width == 32 else "<IIQQQQQQ")
    require(phsize == program.size and phcount > 0, "missing/unsupported ELF load table")
    require(phoff >= ehsize and phoff + phcount * phsize <= len(image_bytes), "truncated ELF load table")
    loads = []
    for i in range(phcount):
        values = program.unpack_from(image_bytes, phoff + i * phsize)
        if width == 32:
            ptype, offset, virtual, physical, files, memory, flags, align = values
        else:
            ptype, flags, offset, virtual, physical, files, memory, align = values
        if ptype == 1:  # PT_LOAD
            require(virtual == physical, "target contract requires identical load/run addresses")
            require(files <= memory and offset + files <= len(image_bytes), "invalid ELF load segment")
            require(align in (0, 1) or (align & (align - 1) == 0 and virtual % align == offset % align),
                    "invalid ELF load segment alignment")
            require(origin <= virtual <= virtual + memory <= origin + ram,
                    f"load segment {i} lies outside target RAM")
            loads.append((offset, virtual, files, memory, flags))
    # The loader reserves/copies PT_LOAD extents, including bytes that have no
    # SHF_ALLOC section. Checking only section ends can silently omit a segment
    # tail or an entirely unsectioned load. Reject overlapping loads: later
    # copies/zero-fill must not replace the bytes used to validate the entry.
    occupied = sorted((start, start + memory) for _, start, _, memory, _ in loads if memory)
    require(all(a[1] <= b[0] for a, b in zip(occupied, occupied[1:])),
            "overlapping ELF load segments")
    section = struct.Struct("<IIIIIIIIII" if width == 32 else "<IIQQQQIIQQ")
    require(shsize == section.size and count > 0, "missing/unsupported ELF section table")
    require(shoff >= ehsize and shoff + count * shsize <= len(image_bytes), "truncated ELF section table")
    image_end = max([origin] + [start + files for _, start, files, _, _ in loads if files])
    memory_end = max([origin] + [start + memory for _, start, _, memory, _ in loads if memory])
    executable_entry = False
    for i in range(count):
        (_, section_type, flags, address, offset, size, _, _, _, _) = section.unpack_from(image_bytes, shoff + i * shsize)
        if not (flags & 2) or size == 0:  # SHF_ALLOC
            continue
        end = address + size
        require(origin <= address < end <= origin + ram, f"allocated section {i} lies outside target RAM")
        covering = [(off, start, files, bits) for off, start, files, memory, bits in loads
                    if start <= address and end <= start + memory]
        require(bool(covering), f"allocated section {i} has no load segment")
        if section_type != 8:  # SHT_NOBITS
            require(offset + size <= len(image_bytes), f"truncated loadable section {i}")
            backed = [(off, start, files, bits) for off, start, files, bits in covering
                      if offset == off + address - start and end <= start + files]
            require(bool(backed), f"allocated section {i} disagrees with its load segment")
            if flags & 4 and address <= entry < end and any(bits & 1 for _, _, _, bits in backed):
                executable_entry = True
    require(executable_entry, "entry point is outside file-backed executable sections")
    used_image, used_memory = image_end - origin, memory_end - origin
    require(used_image <= limit, f"image uses {used_image} bytes, target limit is {limit}")
    require(used_memory + free <= ram,
            f"static image uses {used_memory} RAM bytes plus {free} reserved, target has {ram}")
    return {
        "schema": 2, "target": contract["target"], "elf_class_bits": width,
        "image_sha256": hashlib.sha256(image_bytes).hexdigest(),
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "image_bytes": used_image, "image_limit_bytes": limit,
        "static_memory_bytes": used_memory, "remaining_ram_bytes": ram - used_memory,
        "min_free_bytes": free,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--target", required=True, help="identity selected by the build, independently of the manifest")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--stack-entries", default="", help="optional space-separated public-symbol:byte-limit pairs, proved from linked RV64 IMC integer code")
    args = parser.parse_args()
    try:
        image_bytes, manifest_bytes = args.image.read_bytes(), args.manifest.read_bytes()
        result = admit(image_bytes, manifest_bytes, args.target)
        if args.stack_entries:
            # The optional resource check runs on the same bytes before the
            # build publishes either image or receipt. No old sidecar supplies
            # bounds. Keep the ordinary image-only receipt at schema 2.
            try:
                from .check_linked_stack import prove, parse_entries
            except ImportError:
                from check_linked_stack import prove, parse_entries
            proof = prove(image_bytes, manifest_bytes, args.target,
                          parse_entries(args.stack_entries.split()))
            result = result | {"schema": 3, "linked_stack": proof}
    except (OSError, ValueError, struct.error) as exc:
        parser.exit(1, f"target image refused: {exc}\n")
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(f"target image admitted: {result['target']}: {result['image_bytes']}/{result['image_limit_bytes']} load bytes; "
          f"{result['remaining_ram_bytes']} RAM bytes after load segments")


if __name__ == "__main__":
    main()
