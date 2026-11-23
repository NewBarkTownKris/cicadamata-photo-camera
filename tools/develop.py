"""Develop scene-linear Rec.709/D65 EXRs into grading TIFFs and linear DNGs."""

import argparse
from pathlib import Path
import sys


def discover_shots(directory):
    return sorted(path for path in directory.iterdir()
                  if path.suffix.lower() == ".exr" and not path.name.startswith(".")
                  and not path.name.lower().endswith(".source.exr") and path.is_file())


def develop(source, formats, args):
    pending = {}
    for fmt in formats:
        output = (source.with_suffix(".dng") if fmt == "dng"
                  else source.with_name(f"{source.stem}_{fmt}.tiff"))
        if not output.is_file():
            pending[fmt] = output

    kept = len(formats) - len(pending)
    if not pending:
        return 0, kept, False
    try:
        from development.grade import read_photo_exr
        rgb, exif = read_photo_exr(source, assume_rec709=args.assume_rec709)
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        print(f"{source}: {error}", file=sys.stderr)
        return 0, kept, True

    saved = 0
    failed = False
    for fmt, path in pending.items():
        try:
            if fmt == "dng":
                from development.linear_dng import write_dng
                stops, negative = write_dng(rgb, path, clip_negative=args.clip_negative, integer=args.integer_dng,
                                            exif=exif)
                kind = "16-bit integer" if args.integer_dng else "32-bit floating point"
                detail = f"{kind}, baseline exposure +{stops} EV, {negative} negative channel samples floored"
            else:
                from development.grade import highlight_exposure, write_log_tiff
                ev = args.ev if args.ev is not None else highlight_exposure(rgb, fmt)
                low, high = write_log_tiff(path, rgb, fmt, exposure=ev, exif=exif)
                detail = (f"{ev:+g} EV encoded, {-ev:+g} EV restores the scene after log decoding, "
                          f"{low} low and {high} high channel samples clipped")
            print(f"Saved {path} ({detail})", flush=True)
            saved += 1
        except (OSError, ValueError, RuntimeError, ImportError, OverflowError) as error:
            # Another exporter may publish between our directory check and its atomic link.
            if isinstance(error, FileExistsError) and path.is_file():
                kept += 1
            else:
                print(f"{source} ({fmt}): {error}", file=sys.stderr)
                failed = True
    return saved, kept, failed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("photo", type=Path, help="A scene-linear EXR or a directory to scan")
    parser.add_argument("--assume-rec709", action="store_true",
                        help="Confirm scene-linear Rec.709/D65 encoding when the EXR lacks an encoding tag")
    parser.add_argument("--format", choices=("all", "dng", "logc3", "flog"), default="all")
    parser.add_argument("--ev", type=float, help="Set a log TIFF exposure in stops (default: fit highlights)")
    parser.add_argument("--integer-dng", action="store_true", help="Write a 16-bit integer DNG for legacy readers")
    parser.add_argument("--clip-negative", action="store_true", help="Floor negative RGB for the DNG companion")
    args = parser.parse_args(argv)
    formats = ("logc3", "flog", "dng") if args.format == "all" else (args.format,)
    try:
        if args.photo.is_dir():
            sources = discover_shots(args.photo)
            print(f"Scanning {args.photo}", flush=True)
        elif args.photo.is_file() and args.photo.suffix.lower() == ".exr":
            sources = [args.photo]
        else:
            parser.error(f"Choose an existing scene-linear EXR or directory: {args.photo}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")

    saved = kept = failed = 0
    for source in sources:
        written, existing, problem = develop(source, formats, args)
        saved += written
        kept += existing
        failed += int(problem)
    print(f"Checked {len(sources)} EXR(s). Saved {saved} companion(s), kept {kept} existing. "
          f"Failed shots: {failed}.")
    return int(failed > 0)


if __name__ == "__main__":
    sys.exit(main())
