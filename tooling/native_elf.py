"""Validate the Android executable contract before packaging official core bytes."""
import struct


def inspect_android_elf(binary: bytes, machine: int) -> dict:
    if len(binary) < 64 or binary[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Core must be a little-endian ELF64 executable')
    elf_type, elf_machine = struct.unpack_from('<HH', binary, 16)
    if elf_type != 3 or elf_machine != machine:
        raise ValueError('Core must be an Android PIE for the expected architecture')
    table = struct.unpack_from('<Q', binary, 32)[0]
    entry_size, count = struct.unpack_from('<HH', binary, 54)
    if entry_size != 56 or not count or table + entry_size * count > len(binary):
        raise ValueError('Invalid ELF program headers')
    interpreters, alignments = [], []
    for index in range(count):
        kind, _, offset, address, _, size, _, alignment = struct.unpack_from(
            '<IIQQQQQQ', binary, table + index * entry_size)
        if offset + size > len(binary):
            raise ValueError('ELF segment exceeds executable size')
        if kind == 3:  # PT_INTERP
            interpreters.append(binary[offset:offset + size])
        if kind == 1:  # PT_LOAD
            if alignment < 16384 or alignment & (alignment - 1) or offset % 16384 != address % 16384:
                raise ValueError('Core load segments must support Android 16 KB pages')
            alignments.append(alignment)
    if interpreters != [b'/system/bin/linker64\0'] or not alignments:
        raise ValueError('Core must use the Android Bionic linker, not a Linux binary')
    return {'target_os': 'android', 'interpreter': '/system/bin/linker64',
            'page_alignment': min(alignments)}
