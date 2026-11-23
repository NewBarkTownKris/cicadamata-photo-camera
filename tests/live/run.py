"""Run a bounded retail photo-mode test in the first level using a private Proton prefix."""
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools import install, prepare

STEAM = Path.home() / ".local/share/Steam"
PROTON = STEAM / "steamapps/common/Proton - Experimental/proton"
RUNTIME = STEAM / "steamapps/common/SteamLinuxRuntime_4/_v2-entry-point"
WORK = ROOT / "playtest-data"
COMPAT = WORK / "compat"
PROFILE = COMPAT / "pfx/drive_c/users/steamuser/AppData/Roaming/CICADAMATA"


def stage(game, destination):
    with tempfile.TemporaryDirectory(prefix="cicada-test-source-") as temp:
        sources = Path(temp)
        for source in prepare.MOD_DIR.glob("*.gd"):
            shutil.copyfile(source, sources / source.name)
        # Keep the shipping script intact. Only the test pack's autoload
        # subclass adds a second node to drive the game through public input.
        shutil.move(sources / "session.gd", sources / "production_session.gd")
        (sources / "session.gd").write_text(
            'extends "res://cicadamata_photo/production_session.gd"\n'
            'func _ready() -> void:\n\tsuper()\n'
            '\tvar probe = load("res://cicadamata_photo/probe.gd").new()\n'
            '\tget_tree().root.add_child.call_deferred(probe)\n')
        for fixture in Path(__file__).parent.glob("*.gd"):
            shutil.copyfile(fixture, sources / fixture.name)
        prepare.prepare(game, destination, sources)


def members():
    # Wine services can outlive their launching Unix process group. This
    # second pass is scoped to processes carrying our private prefix path.
    result = []
    marker = os.fsencode(COMPAT)
    for envfile in Path("/proc").glob("[0-9]*/environ"):
        try:
            env = envfile.read_bytes().split(b'\0')
            if b'WINEPREFIX=' + marker + b'/pfx' in env or b'STEAM_COMPAT_DATA_PATH=' + marker in env:
                result.append(int(envfile.parent.name))
        except (PermissionError, ProcessLookupError, FileNotFoundError):
            pass
    return result


def stop_test_processes():
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in members():
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        if members():
            time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--game-dir", type=Path, help="Stock CICADAMATA Steam directory")
    parser.add_argument("--timeout", type=int, default=150)
    parser.add_argument("--driver", choices=["vulkan", "d3d12"], help="Override the installed pack driver")
    parser.add_argument("--scenario", choices=["matrix", "print", "detail", "smoke", "picker"], default="matrix")
    parser.add_argument("--render-thread", choices=["safe", "separate"], help="Override the installed pack render thread mode")
    args = parser.parse_args()
    if not args.name.isalnum():
        parser.error("Use an alphanumeric run name")
    WORK.mkdir(exist_ok=True)
    if members():
        sys.exit("A previous playtest with the private prefix is still running")
    run = WORK / args.name
    run.mkdir()
    game = args.game_dir or install.discover(install.steam_roots())
    stage(game, run / "game")
    if not COMPAT.exists():
        shutil.copytree(game.parents[1] / "compatdata/3817250", COMPAT, symlinks=True)
    if COMPAT.resolve() not in PROFILE.resolve().parents:
        sys.exit("The private profile resolves outside the copied prefix")
    config = PROFILE / "CicadaDisplay.ini"
    old = config.read_text()
    for key, value in {"Windowed": "true", "ResWidth": "960", "ResHeight": "540", "MaxFramerate": "60.0"}.items():
        old = re.sub(rf"(?m)^{key}=.*$", key + "=" + value, old)
    config.write_text(old)
    for name in ("studio.json", "studio.json.bak", "studio.json.tmp"):
        (PROFILE / "CICADAMATA-Photo" / name).unlink(missing_ok=True)
    (PROFILE / "Photo Test Output").mkdir(exist_ok=True)
    report = PROFILE / "photo-live-results.json"
    report.unlink(missing_ok=True)
    env = dict(os.environ, STEAM_COMPAT_DATA_PATH=str(COMPAT), STEAM_COMPAT_CLIENT_INSTALL_PATH=str(STEAM),
               SteamAppId="3817250", SteamGameId="3817250", STEAM_COMPAT_INSTALL_PATH=str(run / "game"))
    env.update(PROTON_LOG="1", PROTON_LOG_DIR=str(run))
    overrides = (["--rendering-driver", args.driver] if args.driver else []) + (["--render-thread", args.render_thread] if args.render_thread else [])
    command = [str(RUNTIME), "--verb=run", "--", str(PROTON), "run", str(run / "game/CICADAMATA.exe"),
               *overrides, "--windowed", "--resolution", "960x540", "--max-fps", "60", "--audio-driver", "Dummy", "--", args.scenario]
    try:
        with (run / "launcher.log").open("w") as log:
            proc = subprocess.Popen(command, cwd=run / "game", env=env, stdout=log, stderr=log, start_new_session=True)
            try:
                proc.wait(timeout=args.timeout)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait()
    finally:
        stop_test_processes()
        if report.exists():
            shutil.copyfile(report, run / "result.json")
        log = PROFILE / "logs/godot.log"
        if log.exists():
            shutil.copyfile(log, run / "godot.log")
    if not (run / "result.json").exists():
        sys.exit(f"Playtest did not report results; see {run}")
    print((run / "result.json").read_text())
    result = json.loads((run / "result.json").read_text())
    if proc.returncode:
        sys.exit(f"Retail process exited with status {proc.returncode}")
    gates = ["done", "restored_view", "frozen", "player_still", "matched_entry", "hidden_rig", "restored_rig"]
    if args.scenario == "matrix":
        gates += ["fringe_disabled", "fringe_restored", "fringe_restored_on_resume", "motion_effects_disabled",
                  "studio", "print_restored", "canceled_and_resumed", "second_entry"]
    if "error" in result:
        sys.exit(result["error"])
    for key in gates:
        if result.get(key) is not True:
            sys.exit(f"Retail gate failed: {key}")
    if args.scenario == "picker":
        if not result.get("picker_open") or not result.get("directory", "").endswith("/Photo Test Output"):
            sys.exit("Native folder selection did not select the test directory")
        shot = result.get("picker_png", {})
        if not shot.get("ok") or "/Photo Test Output/" not in shot.get("path", ""):
            sys.exit("Shot did not reach the selected folder")
    if members():
        sys.exit("A private playtest process survived cleanup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
