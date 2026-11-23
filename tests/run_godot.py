"""Run synthetic Godot probes in a temporary project and private user-data directory."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(godot, render=False):
    with tempfile.TemporaryDirectory(prefix="cicadamata-tests-") as work:
        work = Path(work)
        project = work / "fixture"
        project.mkdir()
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Camera Fixture"\n'
            '[display]\nwindow/size/viewport_width=320\nwindow/size/viewport_height=240\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n',
            encoding="utf-8",
        )
        shutil.copytree(ROOT / "mod/cicadamata_photo", project / "cicadamata_photo")
        env = os.environ.copy()
        for name in ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
            folder = work / name.lower()
            folder.mkdir(mode=0o700)
            env[name] = str(folder)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(name, None)
        for script in sorted((ROOT / "tests").glob("*_test.gd")):
            rendered = script.name in {"render_test.gd", "shutter_render_test.gd", "print_root_test.gd", "print_detail_test.gd", "film_render_test.gd", "capture_render_test.gd"}
            if rendered and not render:
                continue
            profile = work / ("data-" + script.stem)
            profile.mkdir(mode=0o700)
            env.update(XDG_DATA_HOME=str(profile), APPDATA=str(profile), LOCALAPPDATA=str(profile))
            shutil.copyfile(script, project / script.name)
            command = [godot, "--headless"]
            if rendered:
                command = ["xvfb-run", "-a", "-s", "-screen 0 640x480x24 -nolisten tcp",
                           godot, "--display-driver", "x11", "--rendering-method", "gl_compatibility"]
                env.update(LIBGL_ALWAYS_SOFTWARE="1", __GLX_VENDOR_LIBRARY_NAME="mesa",
                           GALLIUM_DRIVER="llvmpipe", LP_NUM_THREADS="1")
            command += ["--audio-driver", "Dummy", "--path", str(project), "--script", "res://" + script.name]
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
            log = result.stdout + result.stderr
            print(log, end="", flush=True)
            if result.returncode or "SCRIPT ERROR:" in log or "ERROR:" in log:
                raise SystemExit(f"{script.name} failed (exit {result.returncode})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--render", action="store_true", help="Run the Xvfb/Mesa capture and print probes")
    args = parser.parse_args()
    run(args.godot, args.render)
