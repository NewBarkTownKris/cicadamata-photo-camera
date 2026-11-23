"""Offline developer verification with synthetic EXR masters."""

import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

try:
    import numpy as np
    import OpenEXR
    import OpenImageIO as oiio
    from PIL import ExifTags
    from PIL.TiffImagePlugin import ImageFileDirectory_v2
except ModuleNotFoundError as error:
    raise unittest.SkipTest(f"Photo development dependencies are optional: {error}") from error

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
from develop import main
from development.grade import REC709


def write_master(path, scene, **header):
    OpenEXR.File({"colorInteropID": "lin_rec709_scene", **header}, {"RGB": scene}).write(str(path))


def run_cli(*args):
    output, errors = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
        status = main([str(arg) for arg in args])
    return status, output.getvalue(), errors.getvalue()


def tags_and_exif(path):
    with path.open("rb") as stream:
        header = stream.read(8)
        parent = ImageFileDirectory_v2(header)
        stream.seek(parent.next)
        parent.load(stream)
        exif = {}
        if ExifTags.IFD.Exif in parent:
            stream.seek(parent[ExifTags.IFD.Exif])
            exif = ImageFileDirectory_v2(header, group=ExifTags.IFD.Exif)
            exif.load(stream)
        return parent, exif


def decoded_dng(path):
    tags, _ = tags_and_exif(path)
    floating = tags[339] == (3, 3, 3)
    with path.open("rb") as stream:
        strips = []
        for offset, count in zip(tags[273], tags[279]):
            stream.seek(offset)
            strips.append(np.frombuffer(stream.read(count), "<f4" if floating else "<u2"))
    values = np.concatenate(strips).reshape(tags[257], tags[256], 3).astype(np.float64)
    return np.ldexp(values / tags[50717][0], int(tags[50730]))


class DevelopTests(unittest.TestCase):
    def test_single_cli_from_another_directory_writes_signed_hdr_and_log_charts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "露出 test.EXR"
            levels = np.array([0, .18, .9, 1, 2, 4, 300], dtype=np.float32)
            chart = np.tile(levels[None, :, None], (65, 1, 3))
            chart[-1, 0] = [-.002, .00001, .3]
            write_master(source, chart, expTime=1/32000, aperture=5.6, isoSpeed=640., focalLength=85.,
                         cicadamataExposureMode="Aperture Priority")
            result = subprocess.run([sys.executable, TOOLS / "develop.py", source, "--ev", "0"],
                                    cwd=tmp, capture_output=True, text=True, check=True)
            self.assertIn("Saved 3 companion(s)", result.stdout)
            dng = source.with_suffix(".dng")
            np.testing.assert_array_equal(decoded_dng(dng), chart)
            tags, exif = tags_and_exif(dng)
            self.assertEqual(tags[50708], "CICADAMATA Virtual Camera")
            self.assertEqual(tags[50730], 9)
            self.assertEqual(tags[262], 34892)
            self.assertEqual(tags[50717], (1, 1, 1))
            for fmt, expected in (("logc3", [95, 400]), ("flog", [95, 470, 705])):
                path = root / f"{source.stem}_{fmt}.tiff"
                reader = oiio.ImageInput.open(str(path))
                try:
                    self.assertEqual(reader.spec().format, oiio.UINT16)
                    self.assertIn("Exposure offset 0 stops", reader.spec().get_string_attribute("ImageDescription"))
                    pixels = reader.read_image(oiio.UINT16)
                    self.assertEqual(pixels.shape, chart.shape)
                    codes = np.rint(pixels[0, :len(expected), 0].astype(float) * 1023 / 65535)
                    np.testing.assert_array_equal(codes, expected)
                finally:
                    reader.close()
                _, tiff_exif = tags_and_exif(path)
                for metadata in (exif, tiff_exif):
                    self.assertEqual(metadata[34850], 3)
                    self.assertEqual(metadata[34855], 640)
                    self.assertEqual((metadata[33434].numerator, metadata[33434].denominator), (1, 32000))
                    self.assertAlmostEqual(float(metadata[33437]), 5.6, places=5)
                    self.assertEqual(float(metadata[37386]), 85.)

    def test_highlight_protection_batch_retries_and_keeps_existing_photos(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a.exr").write_bytes(b"truncated")
            for name in ("unfinished.source.exr", ".staged.exr"):
                (root / name).touch()
            existing = root / "b_logc3.tiff"
            existing.write_bytes(b"existing edits")
            write_master(root / "b.exr", np.full((2, 3, 3), 12, dtype=np.float16))
            status, output, errors = run_cli(root)
            self.assertEqual(status, 1)
            self.assertIn("a.exr", errors)
            self.assertIn("Checked 2 EXR(s). Saved 2 companion(s), kept 1 existing", output)
            self.assertIn("-1 EV encoded", output)
            self.assertIn("0 high channel samples clipped", output)
            self.assertEqual(existing.read_bytes(), b"existing edits")
            self.assertFalse((root / "a.dng").exists())
            status, output, _ = run_cli(root / "b.exr")
            self.assertEqual(status, 0)
            self.assertIn("Saved 0 companion(s), kept 3 existing", output)

    def test_primaries_alone_do_not_imply_linear_light(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rgb = np.zeros((2, 4, 3), np.float16)
            for name, header, allowed in (("primaries", {"chromaticities": REC709}, True),
                                          ("untagged", {}, True),
                                          ("display", {"colorInteropID": "srgb_rec709_scene"}, False),
                                          ("aces", {"acesImageContainerFlag": 1}, False),
                                          ("other-gamut", {"chromaticities": (*REC709[:4], .13, .04, *REC709[6:])}, False)):
                path = root / f"{name}.exr"
                OpenEXR.File(header, {"RGB": rgb}).write(str(path))
                with self.subTest(name=name):
                    self.assertEqual(run_cli(path, "--format", "dng")[0], 1)
                    self.assertFalse(path.with_suffix(".dng").exists())
                    self.assertEqual(run_cli(path, "--format", "dng", "--assume-rec709")[0], 0 if allowed else 1)
                    self.assertEqual(path.with_suffix(".dng").exists(), allowed)

    def test_integer_requires_explicit_clipping_and_reports_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "shadow.exr"
            rgb = np.array([[[-1, .01, 2]]], dtype=np.float32)
            write_master(source, rgb)
            self.assertEqual(run_cli(source, "--format", "dng", "--integer-dng")[0], 1)
            self.assertEqual(list(Path(tmp).iterdir()), [source])
            status, output, errors = run_cli(source, "--format", "dng", "--integer-dng", "--clip-negative")
            self.assertEqual(status, 0, errors)
            self.assertIn("1 negative channel samples floored", output)
            np.testing.assert_allclose(decoded_dng(source.with_suffix(".dng")),
                                       rgb.clip(min=0), rtol=0, atol=1/65535)


if __name__ == "__main__":
    unittest.main()
