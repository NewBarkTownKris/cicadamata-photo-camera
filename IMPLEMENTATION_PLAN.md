# CICADAMATA camera implementation and verification

This port follows the Denshattack! camera and 0.2.0-print.1 handoff. It uses CICADAMATA’s Godot 4.7.2 camera, scene tree, compositor and viewport interfaces on Steam build 25963814. [Reference project](https://github.com/NewBarkTownKris/denshattack-photo-camera) · [Retail evidence](docs/TARGET.md)

| Feature | Implementation | Verification |
| --- | --- | --- |
| Integration and restoration | A build-pinned pack registers the camera autoload, checks the active player, freezes the tree and remembers the original camera, input and HUD state. The detached camera starts from the evaluated gameplay view. | Headless lifecycle and scene-replacement fixtures; retail level entry, autofocus, cancellation, second entry and resume. |
| Composition and optics | A shared integer crop drives the finder and output. Full-frame-equivalent lenses, manual focus, single and continuous AF, practical DOF, roll and film controls apply in photo mode. | Optical calculations, synthetic focus targets and rendered pixel comparisons. Keyboard and simulated controller inputs in the game. |
| Exposure and mastering | A Forward+ post-transparent compute pass meters the composition and reads scene-linear RGB. Paired captures write display PNG and pre-display EXR with exposure and color metadata. | Independent ISO bracket, HDR and priority-mode checks; synthetic primary colors and real EXR-to-DNG/TIFF development. |
| Timed and print shutters | Poses are recorded against real time and replayed with locked settings. Capture scale multiplies the initial integer crop. Off-center overlapping bands bound large captures. A completed PNG survives an EXR cancellation. | Synthetic timed and banded print probes, retail shutter cancellation, and the 4K-source 65:24 print pair. |
| Studio and distribution | The folder picker, exposure and composition settings are available in-game. Separate Windows and Linux/Proton installers validate the Steam files and keep a restorable stock backup. | Native Wine folder selection, settings persistence and Windows/Python-on-Wine and native Linux installer round trips. |

## Reproducing the tests

Use a Godot 4.7.2 binary and the Python libraries in `requirements-development.txt`. The rendered fixtures use Xvfb on Linux. Each fixture has its own temporary project and settings directory.

```sh
python3 -m unittest discover -s tests -v
python3 tests/run_pack_test.py --godot /path/to/godot
python3 tests/run_godot.py --godot /path/to/godot --render
python3 tests/run_linear_probe.py --godot /path/to/godot
```

For the retail Linux tests, install the supported game, Proton Experimental and Steam Linux Runtime 4, and run the stock game once to initialize its Proton profile. Start Steam, then run the tests on an available desktop. The runner stages its own game and prefix under `playtest-data`, closes the staged process at the end of each run and refuses to reuse an existing run name.

```sh
python3 tests/live/run.py --name exposure --scenario matrix
python3 tests/live/verify.py playtest-data/exposure/result.json
python3 tests/live/run.py --name panorama --scenario print --timeout 360
python3 tests/live/verify.py playtest-data/panorama/result.json
python3 tests/live/run.py --name detail --scenario detail
python3 tests/live/check_print.py playtest-data/detail/result.json
```

The fine-detail chart resolved 171 stripe transitions at 4× and 11 at 1× in the root viewport fixture. The UHD retail pair prints at about 51.1 × 18.9 inches at 300 pixels per inch. The display PNG includes the title's display treatment. The pre-display EXR has its own 3D render path. [Root detail fixture](tests/print_root_test.gd) · [Platform and capture details](docs/TARGET.md)
