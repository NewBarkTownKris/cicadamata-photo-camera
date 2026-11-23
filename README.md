# CICADAMATA Photo Mode

**Choose Vulkan when launching CICADAMATA from Steam.** Live gameplay has been tested only on Linux via Proton.

A free camera for the Windows Steam edition of CICADAMATA, app `3817250`, build `25963814`. Freeze a first-person scene, frame it with a photographic lens, and save a display PNG or a PNG and scene-linear EXR pair. The Windows and Linux/Proton packages install into an existing copy of the game. [Installation and removal](docs/INSTALL.md)

## Take a photo

1. Enter a playable level and press **F8**. The camera starts at your current view. Move with WASD, aim with the mouse, and press **N** to focus on the surface under the reticle.
2. Press **F4** for Studio. Choose a lens, exposure, film look, crop and capture scale. The finder shows the output dimensions in pixels. Press F4 to return to the finder.
3. Press **F9** for a PNG or **F3** for a matching PNG and EXR. Both shortcuts work in the finder and Studio. On a controller, **Y / Triangle** requests the pair. **F2** opens the photo folder picker.
4. Press and release **F8** to resume. Release any held movement and action controls so they do not carry into gameplay.

## Capture and print

**Display PNG.** The PNG includes the game's display treatment and your chosen film and grain settings. The shot excludes the finder and gameplay HUD. Studio offers Neutral, Daylight negative, Pastel negative, Chrome slide, Color print, Instant print, Tungsten negative, Cross process, Fine monochrome, Silver print and Hard monochrome. Grain follows the effective ISO, with a separate grain ISO dial in Game exposure.

**Scene-linear EXR.** F3 writes the PNG first, then captures the Forward+ 3D color after transparent geometry and before the display transform and film treatment. The EXR carries linear Rec.709/D65 color data and camera metadata. Game exposure uses half-float RGB. Photographic exposures are stored as 32-bit float RGB. Use the supplied offline developer for LogC3 or F-Log TIFFs and a linear DNG. [EXR development guide](docs/DEVELOPMENT.md)

At print sizes the finder shows progress for each file. Wait for **Saved PNG + EXR** before resuming if you want both files. Pressing F3 while a PNG is still being written adds the EXR to that same shot.

**Depth of field.** Press **B** to switch DOF on, then **N** to focus on the subject at the reticle. Use **J / K** to move the focus plane or **Y** on the keyboard to cycle the blur multiplier. Changing the multiplier also enables DOF. On Forward+, the optical blur uses scene depth in the finder, PNG and scene-linear EXR. For a more pronounced effect, select a longer lens in Studio and use a wider aperture.

**Print scale.** Choose 1×, 2×, 3× or 4× in Studio. The scene is rendered at the increased resolution with the same framing. At 4×, both dimensions quadruple and the pixel count increases sixteenfold. A 65:24 crop at 3840 × 2160 yields 3835 × 1416 pixels at 1× and **15,340 × 5,664** at 4×, enough for **51.1 × 18.9 inches at 300 ppi**. The finder reports a renderer limit or insufficient disk space when detected. Large captures take longer, especially with timed shutters. Large shots can render in overlapping bands. Screen-space effects and animated display shaders can vary across bands and between the PNG and EXR passes.

**Exposure and focus.** Game mode uses the source camera's exposure. Manual, Aperture Priority and Shutter Priority provide f/1–f/16, 8 s–1/32,000 s, ISO 100–6400, and ±5 EV compensation in thirds. Priority modes and Auto ISO meter the selected crop in scene-linear light. Studio includes Auto ISO limits and a preferred minimum shutter speed for Aperture Priority. The finder shows the meter, focus distance and center-target feedback. Autofocus uses collision surfaces and holds its distance on a miss. The depth-of-field toggle controls Godot's practical blur.

**Timed shutter.** At 1/15 s or longer in a photographic mode, press the shutter and move or pan the camera during the exposure. The subject stays paused. The shutter records up to 64 camera poses, locks focus and exposure, and replays the poses for each band and output. Timed capture caps the base long edge at 3840 pixels before applying scale. F8 cancels a timed exposure or EXR in progress. A completed PNG is kept.

## Controls

| In the finder | Keyboard and mouse | Controller |
| --- | --- | --- |
| Enter / resume | F8 | View / Back alone |
| Move, rise / descend | WASD, E / Q | Left stick, RB / LB |
| Fast / precise movement | Shift / Ctrl | |
| Aim, roll, level roll | Mouse or arrow keys, Z / X, F10 | Right stick aims |
| Cycle lens, adjust field of view | F7, left / right bracket | Studio |
| Choose crop, rotate crop | F5, F6 | Studio |
| Single center autofocus, toggle continuous autofocus | N or middle click, T | R3 focuses |
| Focus closer / farther, change coarse / fine steps | J / K or wheel, L | Studio |
| Toggle depth of field, change blur multiplier | B, Y | Studio |
| Change aperture | U / I or wheel with Shift or Ctrl | Studio |
| Cycle exposure mode | O | Studio |
| Slower / faster shutter | Semicolon / apostrophe, or Alt + wheel | Studio |
| Lower / higher manual ISO | Comma / period, or Ctrl + Alt + wheel | Studio |
| Toggle finder, thirds, cycle reticle, controls guide | H, G, R, F1 | Studio provides thirds and reticle |
| Open Studio, choose output folder | F4, F2 | L3, then Screenshot folder |
| Take PNG, take PNG + EXR | F9 or left click, F3 | A / Cross, Y / Triangle |

In Studio, use Up / Down to select a row, Left / Right to adjust it, and Enter to advance or open the folder picker. A controller uses the D-pad and A / Cross. F4, Escape, L3 or B / Circle closes Studio. Manual exposure shortcuts follow the selected mode and Auto ISO settings.

The lens presets are 16, 24, 35, 50, 85, 135, 200 and 600 mm full-frame equivalents. The default lens follows the game's field of view until you choose a preset. Available frames are Viewport, 3:2, 4:3, 1:1, 16:9, 5:4, 21:9 and 65:24. Studio saves preferences in `user://CICADAMATA-Photo/studio.json`. Focus distance and focus mode start fresh on entry. [Photo directories and desktop show/reset commands](docs/INSTALL.md#where-photos-are-saved)

## Tested configurations

The Windows game passed live tests under Proton using Forward+ Vulkan on an RTX 5080. These covered first-person photo mode, restoring the gameplay view, entering the camera a second time, simulated controller input, and a 4× 65:24 PNG and EXR pair at 15,340 × 5,664. That pair took about 15 seconds on the test system. Physical controller hardware, Steam Deck hardware and native Windows gameplay have not been tested.

Both installer launchers were exercised on disposable copies of the supported game, using Linux and Windows Python under Wine. The source checkout includes automated Godot camera, Studio, renderer and shutter tests, plus Python pack, installer and development tests.

The film presets, exposure behavior and offline development tools adapt Denshattack! Photo Camera. [Third-party license](THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt)
