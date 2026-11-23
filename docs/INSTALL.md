# Install CICADAMATA Photo Mode

Use the archive for Windows or Linux/Proton. The mod targets Steam app `3817250`, build `25963814`. It requires the installed Windows game and Python 3.8 or newer. The installer and camera use no additional Python packages. The optional EXR developer uses the libraries in `requirements-development.txt`.

Extract the whole ZIP into a folder outside the Steam game directory. Close CICADAMATA and let Steam finish any updates. Allow about 1.3 GiB of free space on the game drive for the installer to prepare the mod and a verified stock backup.

## Windows

Run `Install-Windows.cmd` from the extracted folder. From Command Prompt, use the launcher with an explicit game directory if automatic detection reports multiple installs or cannot find Steam.

```bat
Install-Windows.cmd install --game-dir "D:\SteamLibrary\steamapps\common\CICADAMATA"
```

## Linux / Proton

Open a terminal in the extracted folder and run the installer.

```sh
sh Install-Linux.sh
```

The patched pack selects the tested Vulkan driver and safe rendering thread. If existing renderer overrides prevent the game from starting, open CICADAMATA’s Steam **Properties → General → Launch Options**. To explicitly select the tested configuration, use the following options after the game command. Preserve unrelated options you already use. D3D12 crashed at startup on the Proton test system.

```text
%command% --rendering-driver vulkan --render-thread safe
```

With a custom Steam library, pass its installed game directory.

```sh
sh Install-Linux.sh install --game-dir "/path/to/steamapps/common/CICADAMATA"
```

## Upgrade or remove

Run the installer from the new release to upgrade. It verifies the original executable, Steam/Discord dependencies, and either the stock pack or the exact pack recorded by a previous installation. It patches a local copy, keeps the original resource pack in `CICADAMATA-Photo-Backup` beside the game, and publishes the replacement with a single rename.

| Operation | Windows Command Prompt | Linux / Proton |
| --- | --- | --- |
| Check pack | `Install-Windows.cmd status` | `sh Install-Linux.sh status` |
| Upgrade | `Install-Windows.cmd install` | `sh Install-Linux.sh install` |
| Uninstall | `Install-Windows.cmd uninstall` | `sh Install-Linux.sh uninstall` |

Uninstall restores the checksum-verified stock resource pack and removes the installer backup. Photos and Studio preferences are kept in the game user's application-data directory. Remove any optional renderer arguments you added in Steam if you want the game's original renderer selection.

If Steam or another mod changed the pack, the installer reports the mismatch and stops. After a Steam verification has already restored this exact supported stock pack, `uninstall` can clean up the old backup. A different game build requires a release matched to its files.

## Where photos are saved

Press F8 during first-person gameplay to enter photo mode. F1 shows the controls. F4 opens Studio and F2 lets you choose a photo directory. The Windows default is `%APPDATA%\CICADAMATA\CICADAMATA-Photo\Photos`. Under Proton the default path inside the Steam library is `steamapps/compatdata/3817250/pfx/drive_c/users/steamuser/AppData/Roaming/CICADAMATA/CICADAMATA-Photo/Photos`.

From the extracted release directory, use the desktop helper to print the current destination or reset it to the default. Close the game before resetting so Studio reloads the change on its next launch. Reset preserves other preferences and existing photos.

| Operation | Windows Command Prompt | Linux / Proton |
| --- | --- | --- |
| Show destination | `py -3 tools/photo_directory.py show` | `python3 tools/photo_directory.py show` |
| Reset destination | `py -3 tools/photo_directory.py reset` | `python3 tools/photo_directory.py reset` |

The helper uses the current Windows user's roaming directory or the installed game's Steam prefix. Supply `--proton-prefix "/path/to/steamapps/compatdata/3817250/pfx"` for a custom prefix. If Python on Windows uses the `python` command, substitute it for `py -3`.

## Platform coverage

Retail gameplay and 4× capture were tested with the Windows game under Proton and Vulkan. Windows installer testing used Windows Python under Wine. Native Windows gameplay, physical controllers and Steam Deck hardware remain unverified. [Camera controls and capture results](../README.md)

The film presets, exposure behavior and offline development tools adapt Denshattack! Photo Camera. Its MIT notice ships in both packages. [License notice](../THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt) · [Developer guide](DEVELOPMENT.md)
