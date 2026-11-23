"""Check the Forward+ compositor on a private X11 display and decode its master independently."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from development.grade import read_photo_exr

def run(godot):
    with tempfile.TemporaryDirectory(prefix="cicadamata-linear-") as temp:
        work = Path(temp)
        project = work / "project"
        project.mkdir()
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Linear fixture"\n'
            '[display]\nwindow/size/viewport_width=96\nwindow/size/viewport_height=64\n'
            '[rendering]\nrenderer/rendering_method="forward_plus"\n', encoding="utf-8")
        shutil.copytree(ROOT / "mod/cicadamata_photo", project / "cicadamata_photo")
        shutil.copy(ROOT / "tests/linear_render_probe.gd", project)
        shutil.copy(ROOT / "tests/paired_render_probe.gd", project)
        target = work / "linear.exr"
        env = os.environ.copy()
        for name in ("HOME", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
            folder = work / name
            folder.mkdir(mode=0o700)
            env[name] = str(folder)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(name, None)
        env["LP_NUM_THREADS"] = "1"
        command = ["xvfb-run", "-a", "-s", "-screen 0 320x240x24 -nolisten tcp", godot,
                   "--display-driver", "x11", "--rendering-method", "forward_plus", "--rendering-driver",
                   "vulkan", "--audio-driver", "Dummy", "--path", str(project), "--script",
                   "res://linear_render_probe.gd", "--", str(target)]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
        log = result.stdout + result.stderr
        print(log, end="", flush=True)
        if result.returncode or "SCRIPT ERROR:" in log or "ERROR:" in log:
            raise SystemExit("Forward+ renderer fixture failed")
        pixels, exif = read_photo_exr(target)
        if pixels.shape != (16, 40, 3) or abs(float(pixels[10, 20, 2]) - 12.0) > 0.1 or not exif:
            raise SystemExit("Incorrect decoded scene-linear EXR")
        print("OpenEXR independently verified the RGB32 master, colorimetry and photo metadata.")
        pair = work / "pair"
        command[-3:] = ["res://paired_render_probe.gd", "--", str(pair)]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
        log = result.stdout + result.stderr
        print(log, end="", flush=True)
        if result.returncode or "SCRIPT ERROR:" in log or "ERROR:" in log:
            raise SystemExit("Integrated Forward+ timed print probe failed")
        pngs, exrs = list(pair.glob("*.png")), list(pair.glob("*.exr"))
        if len(pngs) != 1 or len(exrs) != 1 or pngs[0].stem != exrs[0].stem:
            raise SystemExit("Missing paired print files")
        pixels, exif = read_photo_exr(exrs[0])
        if pixels.shape != (252, 168, 3) or abs(float(pixels[:, :, 2].mean()) - 12.0) > 0.1 or not exif:
            raise SystemExit("Invalid integrated print master")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    run(parser.parse_args().godot)
