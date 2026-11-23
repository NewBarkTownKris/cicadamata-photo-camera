"""Independently decode and verify the retail capture report from run.py."""
import argparse
import json
import math
from pathlib import Path, PureWindowsPath
import re
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import OpenEXR
import OpenImageIO as oiio
from PIL import ExifTags, Image
from PIL.TiffImagePlugin import ImageFileDirectory_v2

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from development.grade import REC709, read_photo_exr


def require(condition, message):
    if not condition:
        raise ValueError(message)


def host_path(path, compat):
    name = PureWindowsPath(path)
    drive = name.drive.upper()
    if drive == "C:":
        return compat.joinpath("pfx", "drive_c", *name.parts[1:])
    if drive == "Z:":
        return Path("/").joinpath(*name.parts[1:])
    if path.startswith("user://"):
        return compat / "pfx/drive_c/users/steamuser/AppData/Roaming/CICADAMATA" / path[7:]
    return Path(path)


def png_dimensions(path):
    with Image.open(path) as image:
        require(image.format == "PNG", f"{path.name} is not a PNG")
        image.verify()
    with Image.open(path) as image:
        image.load()
        return image.size


def pair_paths(report, key, compat):
    record = report.get(key, {})
    require(record.get("ok") and not record.get("timeout") and record.get("path") and record.get("exr_path"),
            f"{key} lacks a completed PNG/EXR pair: {record}")
    png = host_path(record["path"], compat)
    path = host_path(record["exr_path"], compat)
    require(path.with_suffix(".png") == png, f"{key} PNG and EXR stems differ")
    return png, path


def check_exr_header(path, key, expected_mode):
    with OpenEXR.File(str(path), header_only=True) as image:
        header = dict(image.header())
        channels = [channel.name for channel in header["channels"]]
        require(set(channels) == set("RGB"), f"{key} must contain exactly RGB")
        require(header.get("colorInteropID") == "lin_rec709_scene", f"{key} has no linear encoding tag")
        require(np.allclose(header.get("chromaticities", []), REC709, rtol=0, atol=1e-5), f"{key} primaries")
        require(header.get("cicadamataExposureMode") == expected_mode, f"{key} exposure program {header}")
    return header


def capture(report, key, compat, expected_size, expected_mode):
    png, path = pair_paths(report, key, compat)
    require(png_dimensions(png) == expected_size, f"{key} PNG does not match expected {expected_size}")
    header = check_exr_header(path, key, expected_mode)
    reader = oiio.ImageInput.open(str(path))
    require(reader is not None, f"{key} EXR independent open")
    try:
        wanted = oiio.HALF if expected_mode == "Game" else oiio.FLOAT
        require(reader.spec().format == wanted, f"{key} wrong precision; expected {wanted}")
    finally:
        reader.close()
    rgb, _ = read_photo_exr(path)
    require((rgb.shape[1], rgb.shape[0]) == expected_size, f"{key} EXR does not match the PNG")
    peak = float(rgb.max())
    require(peak > 0 and float(np.ptp(rgb)) > 0, f"{key} is empty or constant")
    summary = {"size": list(expected_size), "peak": peak, "mode": expected_mode}
    for field in ("expTime", "aperture", "isoSpeed", "focalLength"):
        if field in header:
            summary[field] = float(header[field])
    return path, rgb, summary


def crop_size(size, ratio, scale=1):
    multiple = min(size[0] // ratio[0], size[1] // ratio[1])
    return tuple(multiple * axis * scale for axis in ratio)


def print_pair(report, compat, size):
    png, exr = pair_paths(report, "uhd_print", compat)
    expected = crop_size(size, (65, 24), 4)
    check_exr_header(exr, "uhd_print", "Game")
    metrics = {"size": list(expected), "seconds": report["print_seconds"]}
    thumbnails = []
    for path, dtype in ((png, oiio.UINT8), (exr, oiio.HALF)):
        reader = oiio.ImageInput.open(str(path))
        require(reader is not None, f"Could not open {path.name}")
        low, high = math.inf, -math.inf
        samples = []
        try:
            spec = reader.spec()
            require((spec.width, spec.height) == expected and spec.format == dtype, f"{path.name} size or precision")
            require(tuple(spec.channelnames[:3]) == ("R", "G", "B"), f"{path.name} channel order")
            for start in range(0, spec.height, 32):
                end = min(start + 32, spec.height)
                pixels = reader.read_scanlines(0, 0, start, end, 0, 0, 3, oiio.FLOAT)
                require(pixels is not None and pixels.shape == (end - start, spec.width, 3), f"{path.name} incomplete scanline band")
                require(np.isfinite(pixels).all(), f"{path.name} nonfinite samples")
                low = min(low, float(pixels.min()))
                high = max(high, float(pixels.max()))
                row = pixels[(end - start) // 2, 16::32, :] @ np.array([0.2126, 0.7152, 0.0722])
                samples.append(np.log1p(20 * np.maximum(0, row)))
        finally:
            reader.close()
        require(high > low, f"{path.name} has no image content")
        thumbnails.append(np.stack(samples))
        metrics[path.suffix[1:]] = {"bytes": path.stat().st_size, "min": low, "max": high}
    display, scene = thumbnails
    correlation = float(np.corrcoef(display.ravel(), scene.ravel())[0, 1])
    require(correlation > 0.7, f"UHD PNG and EXR compositions disagree (luminance correlation {correlation:.3f})")
    metrics["paired_luminance_correlation"] = correlation
    return metrics


def verify_development(path, reference):
    with tempfile.TemporaryDirectory(prefix="cicadamata-live-development-") as folder:
        source = Path(folder) / "capture.exr"
        shutil.copyfile(path, source)
        subprocess.run([sys.executable, str(ROOT / "tools/develop.py"), str(source)], check=True)
        with source.with_suffix(".dng").open("rb") as stream:
            header = stream.read(8)
            tags = ImageFileDirectory_v2(header)
            stream.seek(tags.next)
            tags.load(stream)
            require(tags[262] == 34892 and tags[339] == (3, 3, 3), "DNG needs float32 LinearRaw RGB")
            require((tags[257], tags[256], 3) == reference.shape, "DNG dimensions")
            start = 0
            for offset, count in zip(tags[273], tags[279]):
                stream.seek(offset)
                rowdata = np.frombuffer(stream.read(count), dtype="<f4").reshape(-1, reference.shape[1], 3)
                decoded = np.ldexp(rowdata, int(tags[50730]))
                require(np.array_equal(decoded, reference[start:start + len(rowdata)]), "DNG round-trip failed")
                start += len(rowdata)
            require(start == len(reference), "DNG strip coverage")
            stream.seek(tags[ExifTags.IFD.Exif])
            exif = ImageFileDirectory_v2(header, group=ExifTags.IFD.Exif)
            exif.load(stream)
            require(exif[ExifTags.Base.ISOSpeedRatings] == 100, "DNG ISO metadata")
        for look in ("logc3", "flog"):
            reader = oiio.ImageInput.open(str(source.with_name("capture_" + look + ".tiff")))
            require(reader is not None, f"Could not read {look} TIFF")
            try:
                spec = reader.spec()
                require(spec.format == oiio.UINT16 and spec.nchannels == 3, f"{look} precision")
                pixels = reader.read_image(oiio.UINT16)
                require(pixels.shape == reference.shape and np.ptp(pixels) > 0, f"{look} TIFF pixels")
            finally:
                reader.close()
    return ["LogC3 TIFF16", "F-Log TIFF16", "LinearRaw DNG float32 (exact scene-linear round trip)"]


def verify(report_path, compat, captures_only=False):
    report = json.loads(report_path.read_text())
    is_print = "uhd_print" in report
    gates = ["frozen", "player_still"]
    if not is_print:
        gates += ["studio", "print_restored"]
    if not captures_only:
        gates += ["done", "restored_view"]
        if not is_print:
            gates += ["canceled_and_resumed", "second_entry"]
    for key in gates:
        require(report.get(key) is True, f"Incomplete playtest check: {key}")
    require("error" not in report, str(report.get("error")))
    size = tuple(map(int, re.findall(r"\d+", str(report["size"]))))
    require(len(size) == 2 and min(size) > 0, "Invalid source viewport")
    metrics = {"renderer": report["renderer"], "source_size": list(size)}
    if is_print:
        require(size == (3840, 2160), f"UHD print scenario source size was {size}")
        metrics["uhd_print"] = print_pair(report, compat, size)
        return metrics
    portrait = crop_size(size, (2, 3))
    pano = crop_size(size, (65, 24))
    timed_scale = min(1, 3840 / max(pano))
    timed = tuple(math.floor(side * timed_scale + .5) for side in pano)
    samples = {}
    for key, extent, mode in (
            ("iso100", portrait, "Manual"), ("iso200", portrait, "Manual"),
            ("aperture_priority", portrait, "Aperture Priority"), ("shutter_priority", portrait, "Shutter Priority"),
            ("print4", crop_size(size, (65, 24), 4), "Game"), ("timed", timed, "Manual")):
        path, rgb, stats = capture(report, key, compat, extent, mode)
        metrics[key] = stats
        if key in ("iso100", "iso200"):
            samples[key] = rgb
        if key == "iso100":
            metrics["development"] = verify_development(path, rgb)
        if key == "timed":
            require(math.isclose(stats["expTime"], 1 / 15, rel_tol=0.001), "timed shutter metadata")
    require(metrics["iso100"]["isoSpeed"] == 100 and metrics["iso200"]["isoSpeed"] == 200, "ISO metadata")
    for key in ("aperture", "expTime", "focalLength"):
        require(metrics["iso100"][key] == metrics["iso200"][key], "Bracket changed " + key)
    low, high = samples["iso100"], samples["iso200"]
    valid = (low > 0.001) & (high > 0.001)
    require(valid.sum() >= 256, "Insufficient lit scene samples for ISO bracket")
    ratio = high[valid] / low[valid]
    measured = float(np.median(ratio))
    agree = float(np.mean((ratio >= 1.8) & (ratio <= 2.2)))
    metrics["iso_median_ratio"] = measured
    metrics["iso_samples_within_ten_percent"] = agree
    require(1.9 <= measured <= 2.1 and agree >= 0.75, f"ISO bracket ratio {measured:g}, agreement {agree:.1%}")
    require(max(metrics[key]["peak"] for key in ("iso100", "iso200", "timed", "print4")) > 1,
            "No sample above display white in any master")
    if captures_only:
        return metrics
    controller = report.get("controller_png", {})
    require(controller.get("path") and not controller.get("timeout"), "No controller PNG")
    require(png_dimensions(host_path(controller["path"], compat)) == size, "Controller viewport dimensions")
    return metrics


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--compat", type=Path, default=ROOT / "playtest-data/compat")
    parser.add_argument("--captures-only", action="store_true", help="Check six completed file pairs from an interrupted playtest")
    args = parser.parse_args()
    try:
        metrics = verify(args.report, args.compat, args.captures_only)
    except (ValueError, RuntimeError, KeyError, OSError) as error:
        parser.exit(1, f"Live capture validation failed: {error}\n")
    print(json.dumps(metrics, indent=2))
