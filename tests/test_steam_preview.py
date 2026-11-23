import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from tools.steam_preview import EXE, preview_command


class SteamPreviewTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.game = self.root / "Steam Library" / "steamapps" / "common" / "CICADAMATA"
        self.game.mkdir(parents=True)
        self.stock = self.game / EXE
        self.stock.write_bytes(b"fixture stock")
        self.preview = self.root / "local-build" / EXE
        self.preview.parent.mkdir()
        self.preview.write_bytes(b"fixture preview")
        self.preview.with_suffix(".pck").write_bytes(b"fixture pack")
        self.steam = {"STEAM_COMPAT_INSTALL_PATH": str(self.game), "SteamAppId": "3817250"}

    def test_absolute_and_bare_steam_operands(self):
        for operand, cwd, env in [(str(self.stock), self.root, {}), ("./" + EXE, self.game, {}),
                                  (EXE, self.root, self.steam)]:
            with self.subTest(operand=operand):
                args = ["runtime wrapper", "--", "proton", "waitforexitandrun", operand, "--", "two words"]
                expected = args.copy()
                expected[4] = str(self.preview)
                self.assertEqual(preview_command(args, self.preview, cwd, env), expected)
                self.assertEqual(args[4], operand)

    def test_missing_ambiguous_or_foreign_target(self):
        foreign = self.root / EXE
        foreign.write_bytes(b"other")
        for args, cwd, env in [(["proton", "other.exe"], self.game, self.steam),
                                (["proton", EXE, str(self.stock)], self.game, self.steam),
                                (["proton", str(foreign)], self.game, self.steam),
                                (["proton", str(foreign)], self.root, {}),
                                (["proton", EXE], self.root, {}),
                                (["proton", str(self.stock)], self.game, {"SteamAppId": "123"}),
                                ([str(self.stock)], self.game, self.steam)]:
            with self.subTest(args=args, env=env), self.assertRaises(ValueError):
                preview_command(args, self.preview, cwd, env)

    def test_missing_preview(self):
        self.preview.with_suffix(".pck").unlink()
        with self.assertRaisesRegex(ValueError, "Prepare the private build"):
            preview_command(["proton", str(self.stock)], self.preview, self.game, self.steam)

    def test_only_dummy_wrapper_runs_with_intact_argv_and_environment(self):
        # Exercise the CLI's real execvp in a child process. Neither fixture
        # .exe is executable. The replacement operand is data for this wrapper.
        helper = Path(__file__).resolve().parents[1] / "tools" / "steam_preview.py"
        wrapper = self.root / "dummy wrapper.py"
        wrapper.write_text("import json, os, sys\nprint(json.dumps([sys.argv[1:], os.environ['STEAM_COMPAT_INSTALL_PATH']]))\n")
        local_tool = self.root / "tools" / helper.name
        local_tool.parent.mkdir()
        shutil.copyfile(helper, local_tool)
        args = [sys.executable, str(local_tool), "--", sys.executable, str(wrapper),
                "waitforexitandrun", str(self.stock), "$literal ;", "two words"]
        result = subprocess.run(args, env={**os.environ, **self.steam}, cwd=self.root,
                                capture_output=True, text=True, check=True, timeout=10)
        self.assertEqual(json.loads(result.stdout), [
            ["waitforexitandrun", str(self.preview), "$literal ;", "two words"], str(self.game)])
