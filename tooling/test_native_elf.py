import struct
import unittest

from native_elf import inspect_android_elf


def executable(interpreter=b'/system/bin/linker64\0', alignment=16384, machine=62):
    data = bytearray(256)
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<HH', data, 16, 3, machine)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 2)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0, 0, 256, 256, alignment)
    struct.pack_into('<IIQQQQQQ', data, 120, 3, 4, 192, 192, 0, len(interpreter), len(interpreter), 1)
    data[192:192 + len(interpreter)] = interpreter
    return bytes(data)


class AndroidExecutableTest(unittest.TestCase):
    def test_android_pie(self):
        for machine in (62, 183):
            proof = inspect_android_elf(executable(machine=machine), machine)
            self.assertEqual(proof['page_alignment'], 16384)

    def test_linux_interpreter_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Bionic'):
            inspect_android_elf(executable(b'/lib64/ld-linux-x86-64.so.2\0'), 62)

    def test_four_kilobyte_pages_rejected(self):
        with self.assertRaisesRegex(ValueError, '16 KB'):
            inspect_android_elf(executable(alignment=4096), 62)

    def test_wrong_architecture_rejected(self):
        with self.assertRaisesRegex(ValueError, 'architecture'):
            inspect_android_elf(executable(machine=183), 62)

    def test_truncated_headers_rejected(self):
        with self.assertRaises(ValueError):
            inspect_android_elf(executable()[:100], 62)


if __name__ == '__main__':
    unittest.main()
