"""Assemble Windows and Linux/Proton mod-only ZIPs and a SHA-256 manifest."""

import argparse
import hashlib
from pathlib import Path
import re
import tempfile
import zipfile

if __package__:
    from .prepare import publish
else:
    from prepare import publish


ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = {"windows": "Install-Windows.cmd", "linux-proton": "Install-Linux.sh"}
COMMON = (
    "README.md", "docs/INSTALL.md", "docs/DEVELOPMENT.md",
    "THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt",
    "tools/install.py", "tools/prepare.py", "tools/develop.py", "tools/photo_directory.py",
    "tools/development/grade.py", "tools/development/linear_dng.py", "requirements-development.txt",
)


def build(version, output):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-.][a-zA-Z0-9.-]+)?", version):
        raise ValueError("Use a release version such as 0.1.0 or 0.1.0-rc.1")
    output = output.resolve()
    if output.exists():
        raise FileExistsError(f"Release directory already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    scripts = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "mod/cicadamata_photo").glob("*.gd"))
    if "mod/cicadamata_photo/session.gd" not in scripts:
        raise ValueError("Missing photo session code")
    with tempfile.TemporaryDirectory(prefix=".cicadamata-release-", dir=output.parent) as temporary:
        staged = Path(temporary) / "release"
        staged.mkdir()
        checksums = []
        for platform, launcher in PLATFORMS.items():
            name = f"cicadamata-photo-mode-{version}-{platform}.zip"
            zip_path = staged / name
            with zipfile.ZipFile(zip_path, "w") as archive:
                optional = ["LICENSE"] if (ROOT / "LICENSE").is_file() else []
                for member in sorted([*COMMON, *optional, *scripts, launcher]):
                    path = ROOT / member
                    if path.is_symlink() or not path.is_file():
                        raise ValueError(f"Missing or invalid release input: {member}")
                    # A fixed timestamp and explicit permissions make checksums reproducible.
                    info = zipfile.ZipInfo(member, date_time=(1980, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    info.external_attr = (0o100755 if member.endswith(".sh") else 0o100644) << 16
                    archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
            with zipfile.ZipFile(zip_path) as checked:
                corrupt = checked.testzip()
                if corrupt is not None:
                    raise ValueError(f"Damaged release ZIP member: {corrupt}")
            checksums.append(f"{hashlib.sha256(zip_path.read_bytes()).hexdigest()}  {name}\n")
        (staged / "SHA256SUMS.txt").write_bytes("".join(checksums).encode("ascii"))
        publish(staged, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True, help="New release directory")
    args = parser.parse_args()
    try:
        print(build(args.version, args.output))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Release build: {error}\n")


if __name__ == "__main__":
    main()
