"""Verify packed plain-GDScript autoloads with the Godot 4.7.2 headless engine."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.prepare import MOD_DIR, patch_copy


BUILD_SCRIPT = """extends SceneTree

func _initialize() -> void:
    var error := ProjectSettings.save_custom("res://project.binary")
    var pack := PCKPacker.new()
    if error == OK:
        error = pack.pck_start(OS.get_cmdline_user_args()[0])
    for file in ["project.binary", "probe.tscn", "probe.gd"]:
        if error == OK:
            error = pack.add_file("res://" + file, ProjectSettings.globalize_path("res://" + file))
    if error == OK:
        error = pack.flush()
    if error == OK:
        print("FIXTURE_PACK_WRITTEN")
    quit(error)
"""

SCENE = """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://probe.gd" id="1"]

[node name="PackCheck" type="Node"]
script = ExtResource("1")
"""

PROBE_SCRIPT = """extends Node

func _ready() -> void:
    var session := get_node_or_null("/root/CICADAMATAPhoto")
    if OS.get_cmdline_user_args().has("expect-stock"):
        if session == null and not ProjectSettings.has_setting("autoload/CICADAMATAPhoto"):
            print("STOCK_FIXTURE_OK")
            get_tree().quit()
            return
    elif is_instance_valid(session) and session.is_node_ready():
        var script: Script = session.get_script()
        if (script != null and script.resource_path == "res://cicadamata_photo/session.gd"
                and session.has_method("enter") and session.process_mode == Node.PROCESS_MODE_ALWAYS
                and not session.is_processing() and not session.is_physics_processing()):
            print("PHOTO_AUTOLOAD_READY")
            get_tree().quit()
            return
    push_error("Unexpected photo autoload state")
    get_tree().quit(1)
"""


def run(godot):
    with tempfile.TemporaryDirectory(prefix="cicadamata-pack-test-") as temporary:
        work = Path(temporary)
        source, packed = work / "source", work / "packed"
        source.mkdir()
        packed.mkdir()
        sources = {
            "project.godot": ('config_version=5\n[application]\nconfig/name="Pack Fixture"\n'
                              'run/main_scene="res://probe.tscn"\n'
                              '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'),
            "build.gd": BUILD_SCRIPT,
            "probe.tscn": SCENE,
            "probe.gd": PROBE_SCRIPT,
        }
        for name, content in sources.items():
            (source / name).write_text(content, encoding="utf-8")

        env = os.environ.copy()
        for name in ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR",
                     "APPDATA", "LOCALAPPDATA"):
            folder = work / name.lower()
            folder.mkdir(mode=0o700)
            env[name] = str(folder)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(name, None)

        def check(args, expected):
            result = subprocess.run([godot, "--headless", "--audio-driver", "Dummy", *args],
                                    cwd=packed, env=env, capture_output=True, text=True, timeout=30)
            log = result.stdout + result.stderr
            if result.returncode or expected not in log or "ERROR:" in log:
                raise SystemExit(f"Expected {expected} (exit {result.returncode})\n{log}")
            print(expected)

        pack = packed / "fixture.pck"
        check(["--version"], "4.7.2.stable")
        check(["--path", str(source), "--script", "res://build.gd", "--", str(pack)], "FIXTURE_PACK_WRITTEN")
        # The editor binary opens only this pack. No loose project files are in its working directory.
        boot = ["--main-pack", str(pack), "--quit-after", "60"]
        check([*boot, "--", "expect-stock"], "STOCK_FIXTURE_OK")
        patch_copy(pack, sorted(MOD_DIR.glob("*.gd")))
        check(boot, "PHOTO_AUTOLOAD_READY")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    run(parser.parse_args().godot)
