"""Point an expanded Steam/Proton command at this checkout's private photo build."""

import os
from pathlib import Path
import sys


APP_ID = "3817250"
EXE = "CICADAMATA.exe"
PREVIEW = Path(__file__).resolve().parents[1] / "local-build" / EXE


def preview_command(command, preview, cwd, env):
    indices = [index for index, arg in enumerate(command) if Path(arg).name.casefold() == EXE.casefold()]
    if len(indices) != 1:
        raise ValueError(f"Expected exactly one {EXE} operand in the expanded Steam command, found {len(indices)}")
    index = indices[0]
    if index == 0:
        raise ValueError("The executable must follow Steam's Proton wrapper")
    if env.get("SteamAppId") and env["SteamAppId"] != APP_ID:
        raise ValueError(f"Expected Steam app {APP_ID}, got {env['SteamAppId']}")

    operand = Path(command[index])
    install = env.get("STEAM_COMPAT_INSTALL_PATH")
    if install:
        game_dir = Path(install).resolve()
        # Proton may receive only the executable basename when its wrapper
        # establishes the game's working directory later in the command chain.
        stock = game_dir / operand if operand.parent == Path(".") else (cwd / operand).resolve()
        if stock.parent != game_dir:
            raise ValueError(f"Executable is outside Steam's install directory: {stock}")
    else:
        stock = (cwd / operand).resolve()
        layout = tuple(part.casefold() for part in stock.parent.parts[-3:])
        if layout != ("steamapps", "common", "cicadamata"):
            raise ValueError(f"Cannot identify this as the CICADAMATA Steam installation: {stock}")
    if not stock.is_file():
        raise ValueError(f"Stock executable is missing: {stock}")
    if not preview.is_file() or not preview.with_suffix(".pck").is_file():
        raise ValueError(f"Prepare the private build first. Expected the executable and pack in {preview.parent}")
    if stock.samefile(preview):
        raise ValueError("Preview and stock executables must be separate files")

    result = list(command)
    result[index] = str(preview)
    return result


def main():
    args = sys.argv[1:]
    if args[:1] == ["--"]:
        args = args[1:]
    try:
        command = preview_command(args, PREVIEW, Path.cwd(), os.environ)
        os.execvp(command[0], command)
    except (OSError, ValueError) as error:
        sys.exit(f"CICADAMATA photo preview: {error}")


if __name__ == "__main__":
    main()
