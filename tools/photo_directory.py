"""Show or reset the photo destination saved by CICADAMATA Photo Mode."""

import argparse
import json
import os
from pathlib import Path, PureWindowsPath
import sys
import tempfile

if __package__:
    from . import install
else:
    import install


MOD_DIRECTORY = "CICADAMATA-Photo"
DEFAULT = "user://CICADAMATA-Photo/Photos"
MAX_BYTES = 32768


def locate(profile=None, prefix=None):
    """Return the host directory backing user:// and the optional Proton prefix."""
    if profile:
        return profile.resolve(), None
    if prefix is None and sys.platform == "win32":
        roaming = os.environ.get("APPDATA")
        if not roaming:
            raise ValueError("Set APPDATA or supply --profile")
        return Path(roaming) / "CICADAMATA", None
    if prefix is None:
        compat = os.environ.get("STEAM_COMPAT_DATA_PATH")
        if compat and (Path(compat).name == install.APP_ID or os.environ.get("SteamAppId") == install.APP_ID):
            prefix = Path(compat) / "pfx"
        else:
            try:
                game = install.discover(install.steam_roots())
            except ValueError as error:
                raise ValueError("Select the game's Steam compatdata/3817250/pfx directory with --proton-prefix") from error
            prefix = game.parents[1] / "compatdata" / install.APP_ID / "pfx"
    prefix = prefix.resolve()
    return prefix / "drive_c/users/steamuser/AppData/Roaming/CICADAMATA", prefix


def read_settings(path):
    try:
        with path.open("rb") as stream:
            raw = stream.read(MAX_BYTES + 1)
    except FileNotFoundError:
        return None, None
    if len(raw) > MAX_BYTES:
        return raw, None
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        return raw, None
    return raw, data if isinstance(data, dict) else None


def is_v1(data):
    return (data is not None and type(data.get("version")) in (int, float) and data["version"] == 1
            and isinstance(data.get("settings"), dict))


def destination(settings, profile, prefix):
    value = settings.get("directory")
    if not isinstance(value, str) or len(value) >= 4096 or "://" in value or not value:
        return str(profile / MOD_DIRECTORY / "Photos")
    windows = PureWindowsPath(value)
    if windows.is_absolute():
        # Proton's drive letters map to host directories, including custom mappings.
        if prefix and len(windows.drive) == 2:
            drive = prefix / "dosdevices" / windows.drive.lower()
            if drive.exists():
                return str(drive.resolve().joinpath(*windows.parts[1:]))
            if windows.drive.lower() == "c:":
                return str((prefix / "drive_c").joinpath(*windows.parts[1:]))
        return str(windows)
    if value.startswith("/"):
        return value
    return str(profile / MOD_DIRECTORY / "Photos")


def atomic_write(path, content):
    staged = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".studio-", dir=path.parent, delete=False) as stage:
            staged = Path(stage.name)
            stage.write(content)
            stage.flush()
            os.fsync(stage.fileno())
        os.replace(staged, path)
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)


def operate(action, profile, prefix=None):
    path = profile / MOD_DIRECTORY / "studio.json"
    backup = path.with_suffix(".json.bak")
    raw, primary = read_settings(path)
    saved, data = raw, primary
    if not is_v1(primary):
        saved, data = read_settings(backup)
    if action == "show":
        return destination(data["settings"] if is_v1(data) else {}, profile, prefix)
    if action != "reset":
        raise ValueError(f"Unknown photo directory action: {action}")
    default_path = str(profile / MOD_DIRECTORY / "Photos")
    if primary and type(primary.get("version")) in (int, float) and primary["version"] > 1:
        raise ValueError("A newer Studio settings version is present. Use a matching photo directory helper.")
    if not is_v1(data):
        if raw is not None or saved is not None:
            raise ValueError("No readable V1 settings in studio.json or its backup. The files were kept.")
        return default_path
    settings = data["settings"]
    if is_v1(primary) and settings.get("directory", DEFAULT) == DEFAULT:
        return default_path
    settings["directory"] = DEFAULT
    content = json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(content) > MAX_BYTES:
        raise ValueError("Reset settings exceed Studio's size limit")
    if is_v1(primary):
        atomic_write(backup, raw)
    atomic_write(path, content)
    return default_path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("show", "reset"))
    locations = parser.add_mutually_exclusive_group()
    locations.add_argument("--profile", type=Path, help="Game user-data directory containing CICADAMATA-Photo")
    locations.add_argument("--proton-prefix", type=Path, help="Steam compatdata/3817250/pfx directory")
    args = parser.parse_args()
    try:
        profile, prefix = locate(args.profile, args.proton_prefix)
        print(operate(args.action, profile, prefix))
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"Photo directory: {error}\n")


if __name__ == "__main__":
    main()
