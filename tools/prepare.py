"""Build a private copy of the supported CICADAMATA Steam installation."""

import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
from typing import NamedTuple


BUILD = "25963814"
PCK_NAME = "CICADAMATA.pck"
STOCK_SHA256 = {
    PCK_NAME: "d532ce48de8fbeccf803c8545a17ae8954cf95984ff207860624303e4b895360",
    "CICADAMATA.exe": "d51e11739337c6b979d23d025b082a773f87f73f1be2ce3d2f6b45f93c0ba6a3",
    "discord_game_sdk.dll": "a6b6d7df00a58dc50248d91048578d0fe52182286b487ef89a961fd10467dbd1",
    "discord_game_sdk_binding.dll": "eed53fd3d396c0330b24571daf4d8c5a86ce615cd0b498ce4802c76628bf1cdb",
    "libgodotsteam.windows.template_release.x86_64.dll": "3cd23f78582d35beb2a9b5d520f37c6f3da6dd3357fd5a05a55d1cd9fabf266e",
    "steam_api64.dll": "e082bf5c9f881c822b1540a76b74f9d15e18019a73ebd206a559595badcb7f65",
}
MOD_DIR = Path(__file__).resolve().parents[1] / "mod" / "cicadamata_photo"
AUTOLOAD_KEY = b"autoload/CICADAMATAPhoto"
AUTOLOAD_VALUE = b"*res://cicadamata_photo/session.gd"
ENTRY = struct.Struct("<QQ16sI")


class Entry(NamedTuple):
    offset: int  # Relative to the PCK file base.
    size: int
    digest: bytes
    flags: int


def read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("Truncated Godot pack")
    return data


def read_count(stream):
    return struct.unpack("<I", read_exact(stream, 4))[0]


def read_index(stream):
    stream.seek(0)
    header = struct.unpack("<4sIIIIIQQ", read_exact(stream, 40))
    if header[:6] != (b"GDPC", 4, 4, 7, 2, 2):
        raise ValueError("Expected a Godot 4.7.2 PCK v4 with relative file offsets")
    base, index = header[-2:]
    stream.seek(index)
    entries = {}
    for _ in range(read_count(stream)):
        name = read_exact(stream, read_count(stream)).rstrip(b"\0").decode("utf-8")
        entry = Entry(*ENTRY.unpack(read_exact(stream, ENTRY.size)))
        if not name or name in entries or entry.flags or base + entry.offset + entry.size > index:
            raise ValueError(f"Unexpected PCK entry {name!r}")
        entries[name] = entry
    return base, entries


def add_autoload(config):
    if config[:4] != b"ECFG" or len(config) < 8:
        raise ValueError("Missing Godot project settings")
    count = struct.unpack_from("<I", config, 4)[0]
    records = bytearray()
    pos = 8
    for _ in range(count):
        # Settings use unpadded UTF-8 keys followed by length-prefixed Variants.
        start = pos
        key_size = struct.unpack_from("<I", config, pos)[0]
        key = config[pos + 4:pos + 4 + key_size]
        if key == AUTOLOAD_KEY:
            raise ValueError("Photo autoload already exists")
        pos += 4 + key_size
        value_size = struct.unpack_from("<I", config, pos)[0]
        pos += 4 + value_size
        # This build selects D3D12 even under Proton. Install the Forward+
        # configuration qualified by the retail capture and resume tests.
        if key in (b"rendering/rendering_device/driver", b"rendering/rendering_device/driver.windows"):
            value = struct.pack("<II", 4, 6) + b"vulkan\0\0"
        elif key == b"rendering/driver/threads/thread_model":
            value = struct.pack("<II", 2, 1)  # Godot's safe render-thread model.
        else:
            records.extend(config[start:pos])
            continue
        records.extend(config[start:start + 4 + key_size] + struct.pack("<I", len(value)) + value)
    if pos != len(config):
        raise ValueError("Inconsistent project settings length")
    string_variant = struct.pack("<II", 4, len(AUTOLOAD_VALUE)) + AUTOLOAD_VALUE
    string_variant += b"\0" * (-len(string_variant) % 4)
    record = (struct.pack("<I", len(AUTOLOAD_KEY)) + AUTOLOAD_KEY
              + struct.pack("<I", len(string_variant)) + string_variant)
    return b"ECFG" + struct.pack("<I", count + 1) + records + record


def patch_copy(path, scripts):
    with path.open("r+b") as stream:
        base, entries = read_index(stream)
        project = entries["project.binary"]
        stream.seek(base + project.offset)
        config = read_exact(stream, project.size)
        payloads = {"project.binary": add_autoload(config)}
        for script in scripts:
            name = "cicadamata_photo/" + script.name
            if name in entries:
                raise ValueError(f"Resource path already in use: {name}")
            payloads[name] = script.read_bytes()

        # Keep the retail payloads in place. Only the active directory pointer
        # changes in the original range, so existing resource offsets stay valid.
        stream.seek(0, os.SEEK_END)
        for name, data in payloads.items():
            stream.write(b"\0" * (-stream.tell() % 16))
            offset = stream.tell() - base
            stream.write(data)
            entries[name] = Entry(offset, len(data), hashlib.md5(data).digest(), 0)
        stream.write(b"\0" * (-stream.tell() % 16))
        index = stream.tell()
        stream.write(struct.pack("<I", len(entries)))
        for name, entry in sorted(entries.items()):
            raw = name.encode("utf-8")
            raw += b"\0" * (-len(raw) % 4)
            stream.write(struct.pack("<I", len(raw)) + raw + ENTRY.pack(*entry))
        stream.seek(32)
        stream.write(struct.pack("<Q", index))


def publish(stage, destination):
    # POSIX rename may replace an existing empty directory. Use no-replace
    # publication so parallel builds and unrelated empty directories are safe.
    if sys.platform.startswith("linux"):
        libc = ctypes.CDLL(None, use_errno=True)
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        if rename(-100, os.fsencode(stage), -100, os.fsencode(destination), 1) != 0:
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err), str(destination))
    elif os.name == "nt":
        stage.rename(destination)
    else:
        raise ValueError("Local staging supports Linux and Windows")


def prepare(game_dir, output, mod_dir=MOD_DIR):
    game_dir = game_dir.resolve(strict=True)
    if output.is_symlink() or output.exists():
        raise FileExistsError(f"Choose a new destination: {output}")
    output = output.resolve()
    if game_dir in output.parents:
        raise ValueError("Choose a destination outside the Steam game directory")
    scripts = sorted(mod_dir.glob("*.gd"))
    if not (mod_dir / "session.gd").is_file():
        raise ValueError("Mod sources are missing session.gd")
    if not output.parent.is_dir():
        raise ValueError(f"Destination parent directory does not exist: {output.parent}")

    with tempfile.TemporaryDirectory(prefix=".cicadamata-photo-", dir=output.parent) as temporary:
        stage = Path(temporary) / "game"
        stage.mkdir()
        for name, expected in STOCK_SHA256.items():
            target = stage / name
            shutil.copyfile(game_dir / name, target)
            digest = hashlib.sha256()
            with target.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != expected:
                raise ValueError(f"{name} differs from Steam build {BUILD}")
        patch_copy(stage / PCK_NAME, scripts)
        publish(stage, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-dir", required=True, type=Path, help="Retail CICADAMATA install directory")
    parser.add_argument("--output", required=True, type=Path, help="New private staging directory")
    args = parser.parse_args()
    try:
        output = prepare(args.game_dir, args.output)
    except (OSError, ValueError, KeyError, struct.error) as error:
        parser.exit(1, f"Could not prepare copy: {error}\n")
    print(f"Prepared Steam build {BUILD} in {output}")


if __name__ == "__main__":
    main()
