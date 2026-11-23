import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from tools import install, package_release, prepare
from test_prepare import pack_fixture, read_resources


class InstallTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.game = self.root / "CICADAMATA"
        self.game.mkdir()
        self.mod = self.root / "mod"
        self.mod.mkdir()
        (self.mod / "session.gd").write_text("extends Node\n")
        self.stock = pack_fixture({"project.binary": b"ECFG\0\0\0\0", "level.scn": b"static asset"})
        files = {k: k.encode() for k in prepare.STOCK_SHA256}
        files[prepare.PCK_NAME] = self.stock
        for name, contents in files.items():
            (self.game / name).write_bytes(contents)
        self.live = self.game / prepare.PCK_NAME
        self.backup = self.game / install.BACKUP_DIR
        self.hashes = {k: hashlib.sha256(v).hexdigest() for k, v in files.items()}
        patched = patch.object(prepare, "STOCK_SHA256", self.hashes)
        patched.start()
        self.addCleanup(patched.stop)
        env = patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.root), "LOCALAPPDATA": str(self.root)})
        env.start()
        self.addCleanup(env.stop)

    def operate(self, action):
        return install.operate(action, self.game, self.mod)

    def test_install_idempotence_upgrade_and_uninstall(self):
        self.assertEqual(self.operate("status"), "Stock game pack")
        self.assertEqual(self.operate("install"), "Photo Mode installed")
        self.assertEqual(self.operate("install"), "Photo Mode is up to date")
        self.assertEqual((self.backup / prepare.PCK_NAME).read_bytes(), self.stock)
        self.assertEqual(self.operate("status"), "Photo Mode installed")
        (self.mod / "session.gd").write_text("extends Node\n# v2\n")
        self.assertEqual(self.operate("install"), "Photo Mode upgraded")
        self.assertEqual(read_resources(self.live.read_bytes())["cicadamata_photo/session.gd"],
                         (self.mod / "session.gd").read_bytes())
        self.assertEqual(self.operate("uninstall"), "Stock game restored")
        self.assertEqual(self.live.read_bytes(), self.stock)
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.operate("uninstall"), "Already uninstalled")

    def test_refuses_another_mod_changed_steam_build_and_unrelated_files(self):
        self.live.write_bytes(b"other mod")
        with self.assertRaises(ValueError):
            self.operate("install")
        self.assertEqual(self.live.read_bytes(), b"other mod")
        self.live.write_bytes(self.stock)
        self.operate("install")
        self.live.write_bytes(b"new Steam build")
        with self.assertRaises(ValueError):
            self.operate("uninstall")
        self.assertEqual(self.live.read_bytes(), b"new Steam build")
        self.live.write_bytes(self.stock)
        other = self.backup / "other.txt"
        other.write_bytes(b"keep")
        with self.assertRaises(ValueError):
            self.operate("uninstall")
        self.assertEqual(other.read_bytes(), b"keep")
        other.unlink()
        self.operate("uninstall")
        self.assertFalse(self.backup.exists())

    def test_retry_after_interrupted_first_install_and_upgrade(self):
        with patch.object(install, "replace_checked", side_effect=OSError("busy")):
            with self.assertRaises(OSError):
                self.operate("install")
        self.assertEqual(self.live.read_bytes(), self.stock)
        self.operate("install")
        previous = self.live.read_bytes()
        (self.mod / "session.gd").write_text("extends Node\n# v3\n")
        with patch.object(install, "replace_checked", side_effect=OSError("busy")):
            with self.assertRaises(OSError):
                self.operate("install")
        self.assertEqual(previous, self.live.read_bytes())
        self.operate("uninstall")
        self.assertEqual(self.live.read_bytes(), self.stock)

    def test_corrupt_backup_preserves_current_install(self):
        self.operate("install")
        previous = self.live.read_bytes()
        (self.backup / prepare.PCK_NAME).write_bytes(b"bad")
        with self.assertRaisesRegex(ValueError, "backup differs"):
            self.operate("uninstall")
        self.assertEqual(previous, self.live.read_bytes())

    def test_library_discovery_external_and_ambiguous(self):
        steam = self.root / "Steam"
        library = self.root / "custom library"
        game = library / "steamapps/common/CICADAMATA"
        game.mkdir(parents=True)
        shutil.copyfile(self.live, game / prepare.PCK_NAME)
        (steam / "steamapps").mkdir(parents=True)
        manifest = f'"AppState"\n{{\n"appid" "{install.APP_ID}"\n"installdir" "CICADAMATA"\n}}'
        (library / "steamapps/appmanifest_3817250.acf").write_text(manifest)
        (steam / "steamapps/libraryfolders.vdf").write_text('"libraryfolders" { "1" { "path" ' + json.dumps(str(library)) + ' } }')
        self.assertEqual(install.discover([steam]), game)
        second = steam / "steamapps/common/CICADAMATA"
        second.mkdir(parents=True)
        shutil.copyfile(self.live, second / prepare.PCK_NAME)
        (steam / "steamapps/appmanifest_3817250.acf").write_text(manifest)
        with self.assertRaises(ValueError):
            install.discover([steam])


class ReleaseTests(unittest.TestCase):
    def test_both_zip_manifests_reproducible_and_only_source(self):
        with tempfile.TemporaryDirectory() as folder:
            output = package_release.build("0.1.0-rc.1", Path(folder) / "build A")
            twin = package_release.build("0.1.0-rc.1", Path(folder) / "build B")
            self.assertEqual((output / "SHA256SUMS.txt").read_bytes(), (twin / "SHA256SUMS.txt").read_bytes())
            for platform, launcher in package_release.PLATFORMS.items():
                filename = f"cicadamata-photo-mode-0.1.0-rc.1-{platform}.zip"
                self.assertIn(f"{hashlib.sha256((output / filename).read_bytes()).hexdigest()}  {filename}",
                              (output / "SHA256SUMS.txt").read_text())
                with zipfile.ZipFile(output / filename) as archive:
                    names = set(archive.namelist())
                    self.assertIn(launcher, names)
                    self.assertIn("tools/install.py", names)
                    self.assertIn("tools/photo_directory.py", names)
                    self.assertIn("THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt", names)
                    self.assertIn("mod/cicadamata_photo/session.gd", names)
                    self.assertEqual(archive.testzip(), None)
                    self.assertFalse(any(name.lower().endswith((".exe", ".dll", ".pck", ".exr", ".png")) for name in names))
            with self.assertRaises(FileExistsError):
                package_release.build("0.1.0-rc.1", output)
