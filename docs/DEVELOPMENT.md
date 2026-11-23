# Developing a scene-linear photo

The offline developer makes two 16-bit log TIFFs and one linear RGB DNG from an EXR master. Press F3 or Y / Triangle in photo mode to save a display PNG and a scene-linear EXR with matching framing. The Forward+ compositor reads the 3D color buffer after transparent geometry and before display finishing. The developer has been checked with synthetic exposure charts. A display PNG can be used as a visual reference for grading.

## Running the developer

From the project directory, install the optional image libraries into a Python environment and pass a file or a directory of masters.

```sh
python3 -m pip install -r requirements-development.txt
python3 tools/develop.py "/path/to/shot.exr"
python3 tools/develop.py "/path/to/photos" --format flog
```

The first command for a shot writes `shot_logc3.tiff`, `shot_flog.tiff` and `shot.dng` next to the master. Each existing companion is kept independently. Directory mode examines that directory’s visible EXRs, skips staging files ending in `.source.exr` and continues after failed shots. A failure produces a nonzero exit code. On Unix, the destination filesystem must support hard links for exclusive publication.

| Output | Grading input |
| --- | --- |
| `_logc3.tiff` | Full-range ARRI Wide Gamut 3 / LogC3 EI 800 |
| `_flog.tiff` | Full-range Fujifilm F-Gamut / original F-Log |
| `.dng` | DNG 1.4 floating-point LinearRaw with a virtual Rec.709 camera profile, D65 calibration and signed shadow detail |

TIFF development reduces exposure in whole stops as needed to fit the brightest converted highlight. The file description records the offset. For example, if a TIFF records −2 EV, add 2 EV after decoding its log curve to match the master. Use `--ev 0` to force a zero offset or `--ev -2` for a two-stop reduction. The CLI reports clipped channel samples.

The DNG scales the image by a power of two and records the inverse in BaselineExposure. An image peaking at 300 times reference white gets nine stops of headroom. Use `--format dng --integer-dng` for a reader that needs unsigned 16-bit samples. If that master contains negative channels, `--clip-negative` authorizes flooring them. To develop an alternate version when the companion already exists, use a separate working copy of the EXR.

## Capture contract

A master contains one flat part with full-resolution, finite R, G and B channels in half or single precision, recorded before the display transform. The expected color encoding is scene-linear Rec.709 with D65 white. The master already contains the exposed RGB values. Development preserves that exposure apart from the documented output encoding offsets. The shutter writes the following header fields when applicable.

| EXR header field | Value |
| --- | --- |
| `colorInteropID` | `lin_rec709_scene` |
| `chromaticities` | Rec.709 red (0.640, 0.330), green (0.300, 0.600), blue (0.150, 0.060), white (0.3127, 0.3290) |
| `expTime`, `aperture`, `isoSpeed`, `focalLength` | Exposure time in seconds, f-number, integer ISO and focal length in millimetres. These travel to EXIF when present. |
| `cicadamataExposureMode` | `Game`, `Manual`, `Aperture Priority` or `Shutter Priority`. Photographic modes supply the corresponding EXIF exposure program. |

For a master independently confirmed to meet the encoding contract, `--assume-rec709` accepts a missing encoding tag. Chromaticities alone describe primaries and white point. A conflicting encoding tag, different primaries or ACES container flag causes an error even with the override.

## Offline verification

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_develop.py' -v
```

The tests decode all three companions from synthetic EXRs and check chart codes, HDR round-trip, signed shadows, output dimensions, capture metadata, highlight protection, integer clipping, retries and color-space validation.

The TIFF and DNG encoders and batch development logic are adapted from Denshattack! Photo Camera at commit `1909fb4`. The accompanying license is included in this project. [Reference source](https://github.com/NewBarkTownKris/denshattack-photo-camera/tree/1909fb4/tools) · [MIT notice](../THIRD_PARTY_LICENSES/Denshattack-Photo-Camera.txt)
