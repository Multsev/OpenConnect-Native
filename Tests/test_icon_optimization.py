import importlib.util
import struct
import unittest
import zlib
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "optimize_icon", Path(__file__).resolve().parents[1] / "Scripts/optimize_icon.py"
)
optimizer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(optimizer)


def icon_parts(icon):
    offset = 8
    while offset < len(icon):
        length = struct.unpack_from(">I", icon, offset + 4)[0]
        yield icon[offset:offset + 4], icon[offset + 8:offset + length]
        offset += length


def png_parts(png):
    offset = 8
    while offset < len(png):
        length = struct.unpack_from(">I", png, offset)[0]
        kind = png[offset + 4:offset + 8]
        data = png[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", png, offset + 8 + length)[0]
        assert crc == zlib.crc32(kind + data)
        yield kind, data
        offset += length + 12


class IconOptimizationTests(unittest.TestCase):
    def test_all_variants_and_png_pixels_are_preserved(self):
        original = (Path(__file__).resolve().parents[1] / "App/Resources/OpenConnectNative.icns").read_bytes()
        optimized = optimizer.optimize_icns(original)
        self.assertLessEqual(len(optimized), len(original))
        self.assertEqual(optimizer.optimize_icns(optimized), optimized)
        before, after = list(icon_parts(original)), list(icon_parts(optimized))
        self.assertEqual([kind for kind, _ in before], [kind for kind, _ in after])
        for (_, old), (_, new) in zip(before, after):
            if old.startswith(b"\x89PNG"):
                old_parts, new_parts = list(png_parts(old)), list(png_parts(new))
                self.assertEqual(
                    [(k, d) for k, d in old_parts if k != b"IDAT"],
                    [(k, d) for k, d in new_parts if k != b"IDAT"],
                )
                self.assertEqual(
                    zlib.decompress(b"".join(d for k, d in old_parts if k == b"IDAT")),
                    zlib.decompress(b"".join(d for k, d in new_parts if k == b"IDAT")),
                )
            else:
                self.assertEqual(new, old)

    def test_invalid_container_is_rejected(self):
        with self.assertRaises(ValueError):
            optimizer.optimize_icns(b"invalid")
