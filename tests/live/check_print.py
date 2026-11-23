"""Verify a matched retail 1×/4× reference and moving 4× timed exposure."""
import argparse
import json
from pathlib import Path
import re

import numpy as np
from PIL import Image

from verify import ROOT, capture, crop_size, pair_paths, require


def luminance(rgb):
    y = rgb[:, :, 0] * .2126 + rgb[:, :, 1] * .7152 + rgb[:, :, 2] * .0722
    return np.log1p(20 * np.maximum(y, 0))


def read_capture(report, key, compat, size):
    _, rgb, stats = capture(report, key, compat, size, "Manual")
    scene = luminance(rgb)
    del rgb
    png_path, _ = pair_paths(report, key, compat)
    with Image.open(png_path) as image:
        display = luminance(np.asarray(image.convert("RGB"), dtype=np.float32) / 255)
    return {"exr": scene, "png": display}, stats


def resize(pixels, size, filter):
    return np.asarray(Image.fromarray(pixels).resize(size, filter))


def correlate(a, b):
    return float(np.corrcoef(a.ravel(), b.ravel())[0, 1])


def high_frequency_fraction(image):
    # The base pixel pitch is four print pixels. Energy well above its
    # 0.125-cycle Nyquist cutoff distinguishes additional sampled detail
    # from the interpolation kernel's residual ringing.
    n = 128
    window = np.outer(np.hanning(n), np.hanning(n))
    radius = np.hypot(np.fft.fftfreq(n)[:, None], np.fft.rfftfreq(n)[None, :])
    high = (radius >= .22) & (radius < .48)
    detail = (radius >= .04) & (radius < .48)
    high_power = 0.0
    detail_power = 0.0
    for y in np.linspace(0, image.shape[0] - n, 8, dtype=int):
        for x in np.linspace(0, image.shape[1] - n, 16, dtype=int):
            patch = image[y:y + n, x:x + n]
            spectrum = np.abs(np.fft.rfft2((patch - patch.mean()) * window)) ** 2
            high_power += spectrum[high].sum()
            detail_power += spectrum[detail].sum()
    require(detail_power > 0, "Reference scene has no measurable texture")
    return float(high_power / detail_power)


def compare_images(base, enlarged, boundaries, require_detail):
    h, w = base.shape
    require(enlarged.shape == (h * 4, w * 4), "Print must scale both dimensions by four")
    reference = resize(base, (w * 4, h * 4), Image.Resampling.LANCZOS)
    # Compare large landmarks independently of high-frequency sampling and
    # per-resolution screen-space effects.
    size = (max(1, w // 8), max(1, h // 8))
    composition = correlate(resize(base, size, Image.Resampling.BOX),
                            resize(enlarged, size, Image.Resampling.BOX))
    require(composition > .86, f"Print composition correlation {composition:.3f}")
    result = {"composition_correlation": composition}
    if require_detail:
        real = high_frequency_fraction(enlarged)
        control = high_frequency_fraction(reference)
        require(real > .001 and real > control * 2,
                f"Print has insufficient extra fine detail (measured {real:.5f}, Lanczos control {control:.5f})")
        result.update(print_high_frequency_fraction=real, lanczos_high_frequency_fraction=control)
    # For each real compositor join subtract the matched unbroken frame.
    # The remaining row-to-row difference should resemble nearby non-join
    # rows, even when the scene contains a natural horizontal edge.
    residual = enlarged - reference
    steps = np.mean(np.abs(np.diff(residual, axis=0)), axis=1)
    dynamic_range = float(np.quantile(base, .99) - np.quantile(base, .01))
    seams = {}
    for row in boundaries:
        if row == 0:
            continue
        require(0 < row < len(enlarged), f"Invalid render band start at {row}")
        index = row - 1
        nearby = np.concatenate((steps[max(0, index - 24):index], steps[index + 1:index + 25]))
        limit = max(dynamic_range * .02, float(np.quantile(nearby, .9)) * 3)
        require(steps[index] <= limit, f"Row {row} discontinuity {steps[index]:.5f} above {limit:.5f}")
        seams[row] = {"discontinuity": float(steps[index]), "limit": limit}
    result["seams"] = seams
    return result


def verify(report_path, compat):
    report = json.loads(report_path.read_text())
    for gate in ("done", "frozen", "player_still", "restored_view"):
        require(report.get(gate), f"Incomplete session check {gate}")
    viewport = tuple(map(int, re.findall(r"\d+", str(report["size"]))))
    base_size = crop_size(viewport, (65, 24))
    output = {"viewport": viewport}
    baseline = None
    for key in ("detail_base", "detail_print", "detail_timed"):
        timed = key == "detail_timed"
        scale = 1 if key == "detail_base" else 4
        images, stats = read_capture(report, key, compat, tuple(v * scale for v in base_size))
        observed = report[key + "_render"]
        require(observed["subject_still"] and observed["fov_restored"], f"{key} moved subject or changed lens")
        require(observed["pose_still"] == (not timed), f"{key} camera movement")
        require(observed["samples"] == (8 if timed else 1), f"{key} number of temporal samples")
        if timed:
            require(observed["pose_span_degrees"] > .25, "Timed pose samples did not contain the requested pan")
        require(np.isclose(stats["aperture"], 11 if timed else 2.8) and stats["isoSpeed"] == 100 and
                np.isclose(stats["expTime"], 1 / 8 if timed else 1 / 125), f"{key} incorrect exposure metadata")
        # EXR strips use their own world viewport. Timed display strips use
        # the root camera. Explicitly exercise both sets of compositor joins.
        if scale == 4:
            require(len(observed["exr"]) > 1, f"{key} did not exercise HDR bands")
        if timed:
            require(len(observed["png"]) > 1, "Timed exposure did not exercise display bands")
        paired = correlate(resize(images["png"], (128, 48), Image.Resampling.BOX),
                           resize(images["exr"], (128, 48), Image.Resampling.BOX))
        require(paired > .72, f"{key} PNG and EXR composition correlation {paired:.3f}")
        output[key] = dict(stats, paired_correlation=paired, render=observed)
        if scale == 1:
            baseline = images
        else:
            for kind in ("exr", "png"):
                output[key][kind] = compare_images(baseline[kind], images[kind], observed[kind], not timed)
            if timed:
                timed_fraction = high_frequency_fraction(images["exr"])
                still_fraction = output["detail_print"]["exr"]["print_high_frequency_fraction"]
                ratio = timed_fraction / still_fraction
                require(ratio < .90, f"Recorded pan did not reduce fine-scale scene contrast (ratio {ratio:.3f})")
                output[key]["motion_high_frequency_ratio"] = ratio
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--compat", type=Path, default=ROOT / "playtest-data/compat")
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.report, args.compat), indent=2))
    except (ValueError, RuntimeError, KeyError, OSError) as exc:
        parser.exit(1, f"Retail print verification failed: {exc}\n")
