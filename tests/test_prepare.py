import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from tools import prepare


def setting(key, value):
    return struct.pack("<I", len(key)) + key + struct.pack("<I", len(value)) + value


def pack_fixture(resources):
    data = bytearray(112)
    struct.pack_into("<4sIIIIIQ", data, 0, b"GDPC", 4, 4, 7, 2, 2, 112)
    directory = bytearray(struct.pack("<I", len(resources)))
    for name, contents in resources.items():
        encoded = name.encode()
        encoded += b"\0" * (-len(encoded) % 4)
        directory.extend(struct.pack("<I", len(encoded)) + encoded)
        directory.extend(struct.pack("<QQ16sI", len(data) - 112, len(contents),
                                     hashlib.md5(contents).digest(), 0))
        data.extend(contents)
        data.extend(b"\0" * (-len(data) % 16))
    struct.pack_into("<Q", data, 32, len(data))
    return bytes(data + directory)


def read_resources(packed):
    base, index = struct.unpack_from("<QQ", packed, 24)
    cursor = index
    count = struct.unpack_from("<I", packed, cursor)[0]
    cursor += 4
    result = {}
    for _ in range(count):
        size = struct.unpack_from("<I", packed, cursor)[0]
        cursor += 4
        path = packed[cursor:cursor + size].rstrip(b"\0").decode()
        cursor += size
        pos, length, digest, flags = struct.unpack_from("<QQ16sI", packed, cursor)
        cursor += 36
        contents = packed[base + pos:base + pos + length]
        if digest != hashlib.md5(contents).digest() or flags or path in result:
            raise ValueError("Invalid directory")
        result[path] = contents
    if cursor != len(packed):
        raise ValueError("Directory does not reach EOF")
    return result


class PrepareTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.game = self.root / "CICADAMATA"
        self.game.mkdir()
        self.mod = self.root / "mod"
        self.mod.mkdir()
        self.output = self.root / "photo build"
        config = b"ECFG" + struct.pack("<I", 1) + setting(b"test/int", struct.pack("<II", 2, 42))
        self.resources = {"untouched.gdc": b"GDSC fixture", "project.binary": config}
        files = {name: name.encode() for name in prepare.STOCK_SHA256}
        files[prepare.PCK_NAME] = pack_fixture(self.resources)
        for name, contents in files.items():
            (self.game / name).write_bytes(contents)
        self.stock = files
        hashes = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
        hashes_patch = patch.object(prepare, "STOCK_SHA256", hashes)
        hashes_patch.start()
        self.addCleanup(hashes_patch.stop)
        (self.mod / "session.gd").write_text("extends Node\n")
        (self.mod / "camera.gd").write_text("extends Node3D\n")

    def build(self):
        return prepare.prepare(self.game, self.output, self.mod)

    def test_private_copy_and_exact_resource_content(self):
        self.assertEqual(self.build(), self.output)
        self.assertEqual(sorted(p.name for p in self.output.iterdir()), sorted(self.stock))
        original = self.stock[prepare.PCK_NAME]
        staged = (self.output / prepare.PCK_NAME).read_bytes()
        self.assertEqual(staged[:32], original[:32])
        self.assertEqual(staged[40:len(original)], original[40:])
        contents = read_resources(staged)
        self.assertEqual(set(contents), {*self.resources, "cicadamata_photo/session.gd",
                                        "cicadamata_photo/camera.gd"})
        config = self.resources["project.binary"]
        autoload = b"*res://cicadamata_photo/session.gd"
        variant = struct.pack("<II", 4, len(autoload)) + autoload + b"\0" * (-len(autoload) % 4)
        self.assertEqual(contents["project.binary"], b"ECFG\x02\x00\x00\x00" + config[8:] +
                         setting(b"autoload/CICADAMATAPhoto", variant))
        self.assertEqual(contents["untouched.gdc"], self.resources["untouched.gdc"])
        for name in ("camera", "session"):
            self.assertEqual(contents[f"cicadamata_photo/{name}.gd"], (self.mod / f"{name}.gd").read_bytes())
        for name, data in self.stock.items():
            self.assertEqual((self.game / name).read_bytes(), data)
            if name != prepare.PCK_NAME:
                self.assertEqual((self.output / name).read_bytes(), data)

    def test_incompatible_stock_leaves_no_partial_build(self):
        (self.game / "steam_api64.dll").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "differs from Steam build"):
            self.build()
        self.assertEqual(set(self.root.iterdir()), {self.mod, self.game})

    def test_refuses_empty_existing_destination_and_install_descendant(self):
        self.output.mkdir()
        with self.assertRaises(FileExistsError):
            self.build()
        self.assertEqual(list(self.output.iterdir()), [])
        with self.assertRaisesRegex(ValueError, "outside"):
            prepare.prepare(self.game, self.game / "photo", self.mod)
        self.assertFalse((self.game / "photo").exists())

    def test_publication_race_preserves_empty_destination(self):
        self.output.mkdir()
        stage = self.root / "stage"
        stage.mkdir()
        (stage / "sentinel").touch()
        with self.assertRaises(OSError):
            prepare.publish(stage, self.output)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertTrue((stage / "sentinel").is_file())

    def test_duplicate_autoload_rejected(self):
        already_staged = prepare.add_autoload(self.resources["project.binary"])
        with self.assertRaisesRegex(ValueError, "already exists"):
            prepare.add_autoload(already_staged)

    def test_retail_forward_plus_driver_and_thread_defaults(self):
        def string(value):
            return struct.pack("<II", 4, len(value)) + value + b"\0" * (-len(value) % 4)
        keys = (b"rendering/rendering_device/driver", b"rendering/rendering_device/driver.windows")
        thread = b"rendering/driver/threads/thread_model"
        untouched = setting(b"display/value", struct.pack("<II", 2, 42))
        config = (b"ECFG" + struct.pack("<I", 4) + untouched +
                  b"".join(setting(k, string(b"d3d12")) for k in keys) + setting(thread, struct.pack("<II", 2, 2)))
        expected = (b"ECFG" + struct.pack("<I", 5) + untouched +
                    b"".join(setting(k, string(b"vulkan")) for k in keys) + setting(thread, struct.pack("<II", 2, 1)) +
                    setting(prepare.AUTOLOAD_KEY, string(prepare.AUTOLOAD_VALUE)))
        self.assertEqual(prepare.add_autoload(config), expected)
