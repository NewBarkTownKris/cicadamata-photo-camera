"""Install, upgrade, inspect or remove CICADAMATA Photo Mode in a Steam library."""

import argparse
from contextlib import contextmanager
import functools
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

if __package__:
    from . import prepare
else:
    import prepare


APP_ID = "3817250"
BACKUP_DIR = "CICADAMATA-Photo-Backup"
RECEIPT = "installation.json"


def steam_roots():
    home = Path.home()
    if os.name == "nt":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                yield Path(winreg.QueryValueEx(key, "SteamPath")[0])
        except OSError:
            pass
        for variable in ("ProgramFiles(x86)", "ProgramFiles"):
            if os.environ.get(variable):
                yield Path(os.environ[variable]) / "Steam"
    else:
        yield home / ".steam/steam"
        yield home / ".local/share/Steam"
        yield home / ".var/app/com.valvesoftware.Steam/.local/share/Steam"
        yield home / "snap/steam/common/.local/share/Steam"


def discover(roots):
    found = set()
    for root in roots:
        listing = root / "steamapps/libraryfolders.vdf"
        libraries = [root]
        if listing.is_file():
            for path in re.findall(r'"path"\s*"((?:\\.|[^"\\])*)"', listing.read_text(encoding="utf-8-sig")):
                libraries.append(Path(path.replace("\\\\", "\\").replace('\\"', '"')))
        for library in libraries:
            manifest = library / "steamapps" / f"appmanifest_{APP_ID}.acf"
            if manifest.is_file():
                fields = dict(re.findall(r'"(appid|installdir)"\s*"([^"]+)"', manifest.read_text(encoding="utf-8-sig")))
                if fields.get("appid") == APP_ID and fields.get("installdir") == "CICADAMATA":
                    game = manifest.parent / "common" / fields["installdir"]
                    if (game / prepare.PCK_NAME).is_file():
                        found.add(game.resolve())
    if len(found) != 1:
        raise ValueError("Select an installed CICADAMATA game directory using --game-dir")
    return found.pop()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as file:
        for data in iter(functools.partial(file.read, 1024 * 1024), b""):
            value.update(data)
    return value.hexdigest()


@contextmanager
def installation_lock(game):
    # All invocations of the installer by this account use the same lock.
    # Keeping it outside the game allows uninstall to remove its backup folder.
    parent = Path(os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache"))
    locks = parent / "cicadamata-photo" / "locks"
    locks.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(os.fsencode(os.path.normcase(str(game)))).hexdigest()
    with (locks / key).open("a+b") as handle:
        if os.name == "nt":
            import msvcrt
            if handle.seek(0, os.SEEK_END) == 0:
                handle.write(b"0")
                handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def backup_state(folder):
    if not folder.exists() and not folder.is_symlink():
        return None
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError(f"Unexpected backup path: {folder}")
    if set(p.name for p in folder.iterdir()) != {prepare.PCK_NAME, RECEIPT}:
        raise ValueError(f"Backup folder has unexpected contents: {folder}")
    if any(p.is_symlink() or not p.is_file() for p in folder.iterdir()):
        raise ValueError("Backup folder contains a link or non-file")
    state = json.loads((folder / RECEIPT).read_text(encoding="utf-8"))
    if not isinstance(state, dict) or state.get("product") != "CICADAMATA Photo Mode" or state.get("build") != prepare.BUILD:
        raise ValueError("Unrecognized backup receipt")
    installed = state.get("owned")
    if not isinstance(installed, list) or not (1 <= len(installed) <= 2) or any(
            not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{64}", value) for value in installed):
        raise ValueError("Invalid installation hashes in backup receipt")
    if digest(folder / prepare.PCK_NAME) != prepare.STOCK_SHA256[prepare.PCK_NAME]:
        raise ValueError("The backup differs from the supported Steam pack")
    return installed


def receipt(path, hashes):
    path.write_text(json.dumps({"product": "CICADAMATA Photo Mode", "build": prepare.BUILD,
                                "owned": sorted(set(hashes))}, indent=2) + "\n", encoding="utf-8")


def operate(action, game_dir, mod_dir=prepare.MOD_DIR):
    game = game_dir.resolve(strict=True)
    if not game.is_dir():
        raise ValueError(f"Invalid game directory: {game}")
    live = game / prepare.PCK_NAME
    state_dir = game / BACKUP_DIR
    if not live.is_file() or live.is_symlink():
        raise ValueError(f"Expected a regular Steam resource pack: {live}")
    with installation_lock(game):
        stock = prepare.STOCK_SHA256[prepare.PCK_NAME]
        owned = backup_state(state_dir)
        current = digest(live)
        if current != stock and current not in (owned or []):
            raise ValueError("Installed pack differs from the supported stock and recorded photo packs. The Steam build or another mod may have changed.")
        if action == "status":
            return "Photo Mode installed" if current != stock else "Stock game pack"
        if action == "uninstall" and owned is None:
            return "Already uninstalled"
        if action == "install":
            for name, expected in prepare.STOCK_SHA256.items():
                if name != prepare.PCK_NAME and digest(game / name) != expected:
                    raise ValueError(f"{name} differs from Steam build {prepare.BUILD}")
        with tempfile.TemporaryDirectory(prefix=".cicadamata-photo-", dir=game) as temporary:
            stage = Path(temporary)
            candidate = stage / prepare.PCK_NAME
            if action == "uninstall":
                if current != stock:
                    shutil.copy2(state_dir / prepare.PCK_NAME, candidate)
                    replace_checked(candidate, live, stock, current)
                # Move the entire validated pair out together. If the process
                # previously stopped after restoring stock, this simply finishes.
                state_dir.rename(stage / BACKUP_DIR)
                return "Stock game restored"
            if action != "install":
                raise ValueError(f"Unknown installer action: {action}")
            scripts = sorted(mod_dir.glob("*.gd"))
            if not (mod_dir / "session.gd").is_file() or any(p.is_symlink() for p in scripts):
                raise ValueError(f"Incomplete mod sources: {mod_dir}")
            original = state_dir / prepare.PCK_NAME if owned else live
            shutil.copy2(original, candidate)
            if digest(candidate) != stock:
                raise ValueError("Steam resource pack changed during preparation")
            prepare.patch_copy(candidate, scripts)
            incoming = digest(candidate)
            if current == incoming:
                return "Photo Mode is up to date"
            if owned is None:
                provisional = stage / BACKUP_DIR
                provisional.mkdir()
                shutil.copy2(live, provisional / prepare.PCK_NAME)
                receipt(provisional / RECEIPT, [incoming])
                backup_state(provisional)
                prepare.publish(provisional, state_dir)
            else:
                # Publish the transition receipt first. Both sides are valid if
                # the process stops before or after replacement of the live pack.
                updated = stage / RECEIPT
                receipt(updated, [value for value in (current, incoming) if value != stock])
                os.replace(updated, state_dir / RECEIPT)
            replace_checked(candidate, live, incoming, current)
            return "Photo Mode installed" if current == stock else "Photo Mode upgraded"


def replace_checked(candidate, live, expected, previous):
    if digest(candidate) != expected or digest(live) != previous:
        raise ValueError("Pack changed during installation. Close the game and let Steam finish its update.")
    os.replace(candidate, live)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", default="install", choices=["install", "uninstall", "status"])
    parser.add_argument("--game-dir", type=Path, help="Installed directory containing CICADAMATA.exe and CICADAMATA.pck")
    args = parser.parse_args()
    try:
        game = args.game_dir or discover(steam_roots())
        print(f"{operate(args.action, game)}: {game}")
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        parser.exit(1, f"Installer: {error}\n")


if __name__ == "__main__":
    main()
