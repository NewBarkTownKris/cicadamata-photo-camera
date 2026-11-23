# CICADAMATA Steam target

## Installed build

| Evidence | Observed value |
| --- | --- |
| Steam manifest | App `3817250`, build `25963814`, depot `3817251`, manifest `3702614501119865479` |
| Windows export | `CICADAMATA.exe`, AMD64 PE, 109,228,032 bytes. SHA-256 `d51e11739337c6b979d23d025b082a773f87f73f1be2ce3d2f6b45f93c0ba6a3` |
| Resource pack | `CICADAMATA.pck`, 655,510,824 bytes. SHA-256 `d532ce48de8fbeccf803c8545a17ae8954cf95984ff207860624303e4b895360` |
| PCK header and directory | Godot **4.7.2**, format 4, 4,062 resources, relative file base 112, directory at `0x270be380`. Project settings are in `project.binary`. |
| Renderer | Project features include Forward Plus. The Windows driver setting is `d3d12`. An archived Proton log reports Godot `4.7.2.stable.official.ed1daf0bf`, Forward+, D3D12 12_0 and a separate rendering thread. |
| Display defaults | 1920 × 1080 reference size, `canvas_items` stretch, `expand` aspect. Test other window sizes and UI scales. |
| Dependencies | GodotSteam, Steam API, Discord binding and Discord SDK DLLs alongside the EXE. |
| User data | Custom Godot user directory named `CICADAMATA`. Under this Proton prefix it resolves to `drive_c/users/steamuser/AppData/Roaming/CICADAMATA`. A staged copy retains the same project settings and shares the game's ordinary user data when launched with the same prefix. |

Build identity comes from Steam’s `appmanifest_3817250.acf` and the hashes of the six stock files. The modded pack selects Forward+ Vulkan and Godot’s safe render-thread mode. Proton’s D3D12 path raised a vkd3d alignment assertion at startup on the test machine.

## Integration points

The observations below come from decoded PackedScene node records, exported project settings and the identifiers, literals and line groups in the shipped Godot token buffers. Godot's serialization code defines the formats used for those observations. [PackedScene](https://github.com/godotengine/godot/blob/master/scene/resources/packed_scene.cpp) · [GDScript tokenizer buffer](https://github.com/godotengine/godot/blob/master/modules/gdscript/gdscript_tokenizer_buffer.cpp)

| Interface | Shipped evidence | Implication for photo mode |
| --- | --- | --- |
| Playable camera | `Scenes/Level Design/Level Setup/player.tscn` has a `CharacterBody3D` root and primary `Head/Camera3D`, with `CameraAttributesPractical` and authored FOV 37.8493°. `Scripts/Player/Player2.gdc` joins group `player` and updates head bob, tilt and FOV. The player has `active` and `death` flags. | Check player identity, playable state, and the viewport's current camera at entry. Sample the evaluated view and projection. ADS and motion can change them from the saved values. |
| Secondary view | The camera also owns `SubViewport/Camera3D` and `SubViewport/TextureRect`. The subviewport's scene defaults are 1280 × 720 and 76.9° FOV. Player code binds its texture to a material and updates its camera transform. | The root gameplay viewport provides the display frame. Validate the nested camera separately on a level with a camera feed. |
| First-person visuals | The primary camera directly owns `RigFPS`, `MeshInstance3D`, `CorePixel`, `WhiteFlashPixel` and `DamagePixel`. The player also owns a separate `PostProcess` CanvasLayer. | Hide camera-attached first-person geometry for a clean detached view. Record prior visibility. Check the player's post-process separately from HUD. |
| Gameplay HUD | `project.binary` autoloads `UI` from `Scenes/UI/UI.tscn`. Its CanvasLayer has sibling `UI`, `Crosshairs`, `CrosshairsDot`, `AimAssist`, `Hitmarkers`, subtitle and `Pause` nodes. The layer also contains VHS, radial blur, speed lines, RGB, vignette, rain and flash effects. | Hiding the whole layer also removes these effects. Restore the layer's original visibility. Cover independent `SaveIcon`, `UnlockNotif`, `DebugMenu` and loading overlays in live tests. |
| Freeze and pause | `Player/PauseController` has `PROCESS_MODE_ALWAYS`. Its `_process` polls `pause` and `ui_cancel` and can start the normal unpause UI. Its focus-loss and controller-disconnect handlers can start a pause when the tree is running. | Give photo mode ownership of its tree pause. Suppress the game's pause polling while active. Exercise Alt-Tab, disconnect, an existing pause, scene changes and return to gameplay. |
| Input | The player handles mouse motion through `_unhandled_input`. Its physics code polls actions including shoot, aim, dash, restart and jump. The always-processing `global` autoload writes the mouse mode from `showmouse` and `_gamepad` each frame and runs Steam callbacks. `DebugMenu` can register F3 for its own overlay. | Maintain pointer ownership during photo mode. Verify held keys and mouse buttons, device changes and F3 consumption by the finder. Preserve Steam callbacks while paused. |
| PNG and HDR | The pack defines a Forward+ project with 3D camera attributes and display-space CanvasLayers. The available logs do not identify a scene-linear capture buffer or its encoding. | For PNG, capture after overlay removal and a completed draw. For EXR and metering, establish a pre-display color source on the target renderer. Verify channel order, primaries, clipping and a twofold ISO bracket before enabling photographic development from game captures. |

## Staging

`tools/prepare.py` creates a new private copy using the hashes above and the four shipped DLL hashes. It appends the photo scripts, registers `CICADAMATAPhoto` through Godot's normal autoload settings and updates the directory pointer in the staged PCK. The stock file payloads keep their original offsets. It updates the renderer settings in the staged pack and preserves other project settings. This approach requires about 736 MiB per local copy. Keep staged copies local and distribute the mod sources and preparer.

### Offline packaging checks

Run `python3 tests/run_pack_test.py --godot /path/to/godot` with a Godot 4.7.2 editor executable. The headless engine writes a synthetic v4 pack using its own PCKPacker, boots the stock fixture, then boots the augmented pack and confirms the actual photo session finished its ready callback. This passed with the 4.7.2 Linux Mono editor. A separate static check of a temporary augmented retail copy verified every indexed file digest, including the amended project settings and added script payloads.

## Retail verification

The first playable level was loaded through the title's normal menu and level-transition code. A test-only script issued keyboard and controller events to the game's viewport. The retail executable ran through Proton Experimental on an RTX 5080. Each test used a private game copy and a dedicated Proton prefix.

| Check | Observed result |
| --- | --- |
| Enter and exit | F8 matched the active player's transform, hid the first-person rig, froze the player, and restored the original camera and rig visibility. Canceling a four-second shutter resumed gameplay and a second session captured a full-viewport controller PNG. |
| Focus and display | Center autofocus found a surface. F9 saved the selected portrait crop; Studio, lens and DOF controls accepted input. The VHS fringe switch aligned the chroma sample with luma while preserving the original blur value and visibility. Resuming restored the original material. The motion switch hid the title’s speed-line and radial-blur overlays. |
| Metered and manual exposures | Manual, Aperture Priority and Shutter Priority produced independently decoded PNG and EXR pairs. At fixed f/2.8, 1/125 s and 16 mm, changing ISO 100 to 200 doubled the median signal. A 1/15 s exposure exceeded eight times reference white. |
| Print | A 3,840 × 2,160 source produced a 15,340 × 5,664 65:24 PNG and half-float EXR in 14.6 seconds. All scanlines decoded with finite samples. The PNG used 27.7 MB and the EXR used 521.4 MB. |
| Print detail and motion | At a fixed camera pose, the 3,640 × 1,344 still resolved finer billboard lettering than the 910 × 336 base image. A 4×, 1/8 s pan recorded eight poses spanning 0.87°. Both outputs passed comparisons at all four measured band joins. |
| Destination | The native F2 dialog selected a path containing spaces. The next PNG landed in that directory, then the game resumed and exited. |
| Development | The CLI developed a real game EXR to two 16-bit log TIFFs and a float32 DNG. Applying the DNG's stored baseline exposure reproduced every original channel value. |

The physical controller, native Windows desktop, Steam Deck and imports into Resolve or Lightroom remain outside this test setup. Renderer-specific screen-space effects can vary in very large banded shots. Print time and maximum dimensions depend on the device, scene and available memory.

The retail test harness and independent file checks are under [tests/live](../tests/live). The package contains mod code, installation tools and documentation. Steam supplies the game files.
