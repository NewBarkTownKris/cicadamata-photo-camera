"""Validate retail Studio manual print exports and rendered optical focus brackets."""
import argparse
import json
from pathlib import Path

import numpy as np
import OpenImageIO as oiio

from verify import ROOT, check_exr_header, pair_paths, require


SOURCE = (3835, 1416)  # Locked 65:24 crop of 3840x2160.
LUMA = np.array([.2126, .7152, .0722], dtype=np.float32)


def read_frame(path, expected, scale, print_shot):
    """Decode all RGB samples in bounded stripes, preserving a 1:2 base luminance image."""
    reader = oiio.ImageInput.open(str(path))
    require(reader is not None, f"Cannot open {path.name}")
    width, height = expected
    # Use the same image-space pixel pitch for 1x and 4x comparisons.
    step = 2 * scale
    compact = np.empty((height // step, width // step), dtype=np.float32)
    low, high = np.inf, -np.inf
    swatches = []
    try:
        spec = reader.spec()
        dtype = oiio.FLOAT if path.suffix == ".exr" else oiio.UINT8
        require((spec.width, spec.height) == expected and spec.format == dtype,
                f"{path.name} expected {expected[0]}x{expected[1]} {dtype}")
        require(tuple(spec.channelnames[:3]) == ("R", "G", "B"), f"{path.name} channel names")
        for start in range(0, height, 32):
            end = min(start + 32, height)
            pixels = reader.read_scanlines(0, 0, start, end, 0, 0, 3, oiio.FLOAT)
            require(pixels is not None and pixels.shape == (end - start, width, 3), "Incomplete scanlines")
            require(np.isfinite(pixels).all(), f"{path.name} has nonfinite samples")
            low = min(low, float(pixels.min()))
            high = max(high, float(pixels.max()))
            if print_shot and start <= height // 2 < end:
                for x in (.493, .507):
                    index = int(width * x)
                    mean = pixels[height // 2 - start, index - 3:index + 4].mean(axis=0)
                    swatches.append(mean.tolist())
            rows = (end - start) // step
            y = pixels[:rows * step, :compact.shape[1] * step] @ LUMA
            compact[start // step:start // step + rows] = y.reshape(rows, step, compact.shape[1], step).mean(axis=(1, 3))
    finally:
        reader.close()
    require(high > low, f"{path.name} empty or constant")
    if print_shot and path.suffix == ".png":
        a, b = swatches
        marker = a[0] > .94 and a[1] < .055 and a[2] > .94 and b[0] < .055 and b[1] > .94 and b[2] > .94
        require(not marker, "Saved display image contains the Studio/finder marker")
    return compact, {"minimum": low, "maximum": high, "bytes": path.stat().st_size}


def read_pair(report, label, compat, scale, focal_mm, iso):
    png, exr = pair_paths(report, label, compat)
    before = report.get(label + "_settings")
    if before:
        enabled = label.endswith(("_near", "_subject"))
        require(before["dof"] == enabled and before["scale"] == scale and before["strength"] == 1,
                f"{label} wrong optical mode at shutter")
        if enabled:
            focal_plane = .28 if label.endswith("_near") else report["subject_m"]
            require(np.isclose(before["focus_m"], focal_plane, atol=.001), f"{label} wrong focal plane")
    header = check_exr_header(exr, label, "Manual")
    for key, expected in {"focalLength": focal_mm, "aperture": 3.5, "expTime": .004, "isoSpeed": iso}.items():
        require(np.isclose(header[key], expected, rtol=.001), f"{label} {key}: {header[key]} != {expected}")
    size = tuple(axis * scale for axis in SOURCE)
    frames, stats = {}, {"size": size, "seconds": report[label + "_seconds"]}
    for path in (png, exr):
        y, measured = read_frame(path, size, scale, label == "studio_manual_print")
        frames[path.suffix[1:]] = y
        stats[path.suffix[1:]] = measured
    return frames, stats


def centers(frame):
    h, w = frame.shape
    return frame[h // 4:3 * h // 4, w // 4:3 * w // 4]


def texture(frame):
    # Horizontal detail retains the sharpness measurement under the game's
    # horizontal CRT scanlines. The region surrounds the traced center subject.
    y = np.log1p(12 * np.maximum(0, centers(frame)))
    residual = y[:, :-2] - 2 * y[:, 1:-1] + y[:, 2:]
    return float(np.sqrt(np.mean(residual ** 2)))


def correlation(a, b):
    # Coarse landmarks remain comparable between render scales and display transforms.
    def coarse(y):
        h, w = y.shape
        y = np.log1p(12 * np.maximum(y[:h // 8 * 8, :w // 8 * 8], 0))
        return y.reshape(h // 8, 8, w // 8, 8).mean(axis=(1, 3)).ravel()
    return float(np.corrcoef(coarse(a), coarse(b))[0, 1])


def focus_change(off, near):
    # Average to a common eight-base-pixel pitch. Subtract each scale's
    # own sharp control to isolate defocus from differences in sampling.
    def filtered(frame):
        image = centers(frame)
        h, w = image.shape
        blocks = image[:h // 4 * 4, :w // 4 * 4].reshape(h // 4, 4, w // 4, 4)
        return np.log1p(12 * np.maximum(0, blocks.mean(axis=(1, 3))))
    return filtered(near) - filtered(off)


def analyze(report, compat):
    require(report.get("level", "").endswith("/lvl_4_2.tscn"), "Wrong retail level")
    issues = []
    if report.get("size") != "(3840, 2160)":
        issues.append("Expected 3840x2160 source viewport")
    for k in ("optics_studio_open", "marker_in_finder", "pixelzoom", "done", "restored_view",
              "frozen", "player_still", "optics_pose_fixed", "optics_player_fixed"):
        if report.get(k) is not True:
            issues.append(f"Missing retail evidence: {k}")
    require(report["subject_m"] >= 1.0, "No distant center surface for the focus bracket")
    metrics = {"subject_m": report["subject_m"], "captures": {}, "focus": {}}
    prints = {}
    for key in ("studio_manual_print", "focus_print_near"):
        prints[key], stats = read_pair(report, key, compat, 4, 16, 100)
        stats["paired_correlation"] = correlation(prints[key]["exr"], prints[key]["png"])
        if stats["paired_correlation"] < .6:
            issues.append(f"{key} PNG/EXR composition mismatch")
        metrics["captures"][key] = stats
    exposed, metrics["captures"]["exposed_reference"] = read_pair(report, "exposed_reference", compat, 1, 16, 1600)
    if max(metrics["captures"][k]["exr"]["maximum"] for k in metrics["captures"]) <= 1:
        issues.append("No above-white radiance in either manual print or the brighter ISO reference")

    for focal in (16, 85):
        frames = {}
        for key in ("off", "near", "subject", "control"):
            label = f"focus_{focal}_{key}"
            frames[key], metrics["captures"][label] = read_pair(report, label, compat, 1, focal, 100)
        for kind in ("png", "exr"):
            curve = {k: texture(frame[kind]) for k, frame in frames.items()}
            if min(curve["off"], curve["control"]) < 1e-5:
                issues.append(f"{focal}mm {kind} has insufficient scene texture to measure sharpness")
                continue
            reference = (curve["off"] + curve["control"]) / 2
            # Compare to both off shots to establish the scene's animation and
            # temporal jitter floor independently for each output.
            noise = abs(curve["off"] - curve["control"]) / reference
            reduction = (reference - curve["near"]) / reference
            recovery = (curve["subject"] - curve["near"]) / reference
            result = dict(sharpness=curve, repeated_off_drift=noise, near_reduction=reduction,
                          refocus_recovery=recovery)
            metrics["focus"][f"{focal}mm_{kind}"] = result
            if reduction < max(.06, 2 * noise) or recovery < max(.025, noise):
                issues.append(f"{focal}mm {kind}: near and subject focus did not separate from repeated-off drift")
            if focal == 16:
                for print_label, key in (("studio_manual_print", "off"), ("focus_print_near", "near")):
                    score = correlation(prints[print_label][kind], frames[key][kind])
                    metrics["captures"][print_label][f"{kind}_base_correlation"] = score
                    if score < .9:
                        issues.append(f"{print_label} {kind} 4x composition differs from matching 1x reference")
                big_off = texture(prints["studio_manual_print"][kind])
                big_near = texture(prints["focus_print_near"][kind])
                result["print_near_reduction"] = (big_off - big_near) / max(big_off, 1e-12)
                if result["print_near_reduction"] < max(.06, 2 * noise):
                    issues.append(f"{focal}mm {kind} 4x private print lost optical blur")
                change = focus_change(frames["off"][kind], frames["near"][kind])
                print_change = focus_change(prints["studio_manual_print"][kind], prints["focus_print_near"][kind])
                rms_ratio = float(np.linalg.norm(print_change) / max(np.linalg.norm(change), 1e-12))
                similarity = float(np.corrcoef(change.ravel(), print_change.ravel())[0, 1])
                result.update(print_to_base_focus_signal=rms_ratio, print_focus_correlation=similarity)
                if not .55 < rms_ratio < 1.8 or not similarity > .40:
                    issues.append(f"{kind} print defocus differs from the 1x reference on the same optical gate")
        if focal == 16:
            base = frames["off"]["exr"]
            valid = base > max(.001, float(np.quantile(base, .25)))
            require(valid.any(), "Missing lit comparison samples")
            ratio = float(np.median(exposed["exr"][valid] / base[valid]))
            metrics["iso_1600_over_100"] = ratio
            if not 14.4 < ratio < 17.6:
                issues.append("Manual exposure gain differs between matched 1x reference captures")
    return metrics, issues


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("report", type=Path)
    p.add_argument("--compat", type=Path, default=ROOT / "playtest-data/compat")
    args = p.parse_args()
    try:
        metrics, failures = analyze(json.loads(args.report.read_text()), args.compat)
    except (ValueError, RuntimeError, KeyError, OSError) as error:
        p.exit(1, f"Retail optical validation failed: {error}\n")
    print(json.dumps(metrics, indent=2), flush=True)
    if failures:
        p.exit(1, "\n".join(failures) + "\n")
