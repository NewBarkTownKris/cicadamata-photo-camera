import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tools import photo_directory as photo


class PhotoDirectoryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.prefix = self.root / "prefix"
        self.profile, _ = photo.locate(prefix=self.prefix)
        self.mod = self.profile / photo.MOD_DIRECTORY
        self.main = self.mod / "studio.json"
        self.backup = self.mod / "studio.json.bak"
        self.default = str(self.mod / "Photos")
        self.custom = {"version": 1, "settings": {"directory": "C:/Photo Prints", "capture_scale": 4,
                       "grain": True, "custom": {"name": "neige ☃", "items": [1, 2, None]}}, "extension": 17}

    def save(self, path, document):
        self.mod.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document), encoding="utf-8")

    def action(self, name):
        return photo.operate(name, self.profile, self.prefix)

    def test_show_reset_default_without_creating_a_profile(self):
        self.assertEqual(self.action("show"), self.default)
        self.assertEqual(self.action("reset"), self.default)
        self.assertFalse(self.profile.exists())
        for value in ["user://wrong", "res://other", "", {}, "relative", "C:relative", "/" + "x"*4095]:
            self.save(self.main, {"version": 1, "settings": {"directory": value}})
            self.assertEqual(self.action("show"), self.default)

    def test_proton_custom_disk_and_cli_reset_preserve_all_other_preferences(self):
        drive = self.prefix / "dosdevices/e:"
        drive.parent.mkdir(parents=True)
        target = self.root / "extra drive"
        target.mkdir()
        drive.symlink_to(target, target_is_directory=True)
        self.custom["settings"]["directory"] = "E:/Prints"
        self.save(self.main, self.custom)
        original = self.main.read_bytes()
        def command(action):
            proc = subprocess.run([sys.executable, str(Path(photo.__file__)), action, "--proton-prefix", str(self.prefix)],
                                  check=True, capture_output=True, text=True)
            return proc.stdout.strip()
        self.assertEqual(command("show"), str(target / "Prints"))
        self.assertEqual(command("reset"), self.default)
        self.assertEqual(command("show"), self.default)
        self.assertEqual(self.backup.read_bytes(), original)
        expected = self.custom.copy()
        expected["settings"] = dict(self.custom["settings"], directory=photo.DEFAULT)
        self.assertEqual(json.loads(self.main.read_text(encoding="utf-8")), expected)
        unchanged = [(p.stat().st_mtime_ns, p.read_bytes()) for p in (self.main, self.backup)]
        self.assertEqual(command("reset"), self.default)
        self.assertEqual(unchanged, [(p.stat().st_mtime_ns, p.read_bytes()) for p in (self.main, self.backup)])

    def test_backup_recovery_and_interrupted_publication(self):
        self.save(self.backup, self.custom)
        good = self.backup.read_bytes()
        self.main.write_bytes(b"broken")
        self.assertEqual(self.action("show"), str(self.prefix / "drive_c/Photo Prints"))
        with patch.object(photo.os, "replace", side_effect=OSError("file busy")):
            with self.assertRaises(OSError):
                self.action("reset")
        self.assertEqual(set(self.mod.iterdir()), {self.main, self.backup})
        self.assertEqual(self.main.read_bytes(), b"broken")
        self.action("reset")
        self.assertEqual(self.backup.read_bytes(), good)
        self.assertEqual(self.action("show"), self.default)
        self.assertEqual(json.loads(self.main.read_text(encoding="utf-8"))["settings"]["capture_scale"], 4)
        self.main.unlink()
        self.assertEqual(self.action("reset"), self.default)
        self.assertTrue(self.main.is_file())

    def test_unreadable_or_newer_settings_are_never_overwritten(self):
        self.save(self.main, {"version": 2, "settings": {"new": True}})
        self.save(self.backup, self.custom)
        before = self.main.read_bytes(), self.backup.read_bytes()
        with self.assertRaisesRegex(ValueError, "newer"):
            self.action("reset")
        self.assertEqual(before, (self.main.read_bytes(), self.backup.read_bytes()))
        self.backup.unlink()
        for bad in [b"broken", b" " * (photo.MAX_BYTES + 1), b'{"version":true,"settings":{}}']:
            self.main.write_bytes(bad)
            with self.assertRaisesRegex(ValueError, "No readable V1"):
                self.action("reset")
            self.assertEqual(self.main.read_bytes(), bad)

    def test_windows_roaming_and_proton_library_discovery(self):
        with patch.object(sys, "platform", "win32"), patch.dict(os.environ, {"APPDATA": str(self.root)}):
            profile, prefix = photo.locate()
        self.assertEqual(profile, self.root / "CICADAMATA")
        self.assertIsNone(prefix)
        self.assertEqual(photo.destination(self.custom["settings"], profile, None), r"C:\Photo Prints")
        with patch.object(sys, "platform", "linux"), patch.dict(os.environ, {}, clear=True), \
                patch.object(photo.install, "discover", return_value=self.root / "steamapps/common/CICADAMATA"):
            found, prefix = photo.locate()
        self.assertEqual(prefix, self.root / "steamapps/compatdata/3817250/pfx")
        self.assertEqual(found, prefix / "drive_c/users/steamuser/AppData/Roaming/CICADAMATA")
