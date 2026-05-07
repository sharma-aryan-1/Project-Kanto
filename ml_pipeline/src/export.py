"""
export.py - Project Kanto, Phase 3: INT8 TFLite export for edge deployment.

Loads the trained YOLOv8 classification checkpoint, runs Ultralytics export to
INT8 TFLite (with calibration images from the YOLO dataset), then copies the
artifact into the Flutter asset bundle as `best_int8.tflite`.

Run (from repo root):
    python ml_pipeline/src/export.py
    python ml_pipeline/src/export.py --data /path/to/yolo_dataset

INT8 TFLite export pulls in TensorFlow via Ultralytics; if the exporter errors on
a missing dependency, install TensorFlow for your platform (see Ultralytics
TFLite integration docs).

Large val splits: Ultralytics concatenates all calibration images into one tensor
for TF INT8; the default script caps calibration image count (--calib-cap) so
runs stay within typical RAM limits.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import traceback
from pathlib import Path
from typing import Optional, Tuple

from ultralytics import YOLO


DEFAULT_DATA_DIR = Path("ml_pipeline/data/processed/yolo_dataset")
DEFAULT_RUN_DIR = Path("ml_pipeline/runs/yolov8n-cls-inat21-mini-a100")
DEFAULT_WEIGHTS_NAME = "best.pt"
DEFAULT_FLUTTER_MODEL = Path("app/assets/model/best_int8.tflite")
# Ultralytics INT8 SavedModel export does torch.cat() over *all* calibration batches at
# once (~N * 3 * imgsz^2 * 4 bytes FP32 after interpolate). Cap N unless --fraction is set.
DEFAULT_CALIB_IMAGE_CAP = 1000
_IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}


def resolve_dataset_path(data_arg: str) -> Path:
    """Resolve and validate the YOLO classification dataset directory."""
    path = Path(data_arg).expanduser().resolve()
    if not path.exists():
        raise FileNotFoundError(
            f"dataset root not found: {path}. "
            "Run `python ml_pipeline/src/data_prep.py` first."
        )
    train_dir = path / "train"
    val_dir = path / "val"
    if not train_dir.is_dir() or not val_dir.is_dir():
        raise FileNotFoundError(
            f"expected `train/` and `val/` under {path}; "
            f"found train={train_dir.is_dir()}, val={val_dir.is_dir()}"
        )
    print(f"[data]   calibration / dataset root: {path}")
    return path


def count_val_images(val_dir: Path) -> int:
    """Count image files under YOLO cls val/ (class folders with flat images)."""
    n = 0
    for class_dir in val_dir.iterdir():
        if not class_dir.is_dir():
            continue
        for f in class_dir.iterdir():
            if f.is_file() and f.suffix.lower() in _IMAGE_EXT:
                n += 1
    if n > 0:
        return n
    for f in val_dir.rglob("*"):
        if f.is_file() and f.suffix.lower() in _IMAGE_EXT:
            n += 1
    return n


def resolve_calibration_fraction(
    fraction_arg: Optional[float],
    val_dir: Path,
    cap: int,
    imgsz: int,
) -> Tuple[float, int, int]:
    """Return (fraction, approx_calibration_count, total_val_images)."""
    n_val = count_val_images(val_dir)
    if n_val < 1:
        raise ValueError(f"No images found under {val_dir} for INT8 calibration.")

    if fraction_arg is None:
        frac = min(1.0, cap / n_val)
        mode = "auto"
    else:
        frac = max(0.0, min(1.0, float(fraction_arg)))
        mode = "manual"

    n_calib = max(1, int(round(n_val * frac)))
    print(
        f"[calib]  val images: {n_val:,}  fraction: {frac:.6g} ({mode})  "
        f"~{n_calib:,} images for TensorFlow calibration"
    )
    approx_ram_gib = (n_calib * 3 * (imgsz**2) * 4) / (1024**3)  # FP32 BCHW ballpark
    if n_calib > cap or approx_ram_gib >= 4.0:
        print(
            f"[calib]  note: Ultralytics stacks calibration tensors in RAM (~{approx_ram_gib:.1f} GiB "
            f"order-of-magnitude at imgsz={imgsz}). Omit --fraction to auto-cap, or lower --fraction further."
        )
    return frac, n_calib, n_val


def locate_best_weights(run_dir: Path, weights_name: str) -> Path:
    """Return path to `<run_dir>/weights/<weights_name>`, verifying it exists."""
    weights = (run_dir / "weights" / weights_name).resolve()
    if not weights.is_file():
        raise FileNotFoundError(
            f"weights not found: {weights}\n"
            f"Expected a trained run at {run_dir.resolve()} with "
            f"`weights/{weights_name}`."
        )
    print(f"[weights] {weights}")
    return weights


def _mb(num_bytes: int) -> float:
    return num_bytes / (1024 * 1024)


def _export_output_path_hint(weights_pt: Path) -> Path:
    """Where Ultralytics typically writes INT8 TFLite for a given .pt path."""
    # See ultralytics.engine.exporter.Exporter.export_tflite (int8 branch).
    saved_model = Path(str(weights_pt).replace(weights_pt.suffix, "_saved_model"))
    return saved_model / f"{weights_pt.stem}_int8.tflite"


def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Export YOLOv8-cls to INT8 TFLite and copy into Flutter assets.",
    )
    p.add_argument(
        "--run-dir",
        default=str(DEFAULT_RUN_DIR),
        help="Training run directory containing weights/ (default: %(default)s).",
    )
    p.add_argument(
        "--weights-name",
        default=DEFAULT_WEIGHTS_NAME,
        help="Checkpoint filename inside weights/ (default: %(default)s).",
    )
    p.add_argument(
        "--data",
        default=str(DEFAULT_DATA_DIR),
        help="yolo_dataset root for INT8 calibration (default: %(default)s).",
    )
    p.add_argument(
        "--flutter-out",
        default=str(DEFAULT_FLUTTER_MODEL),
        help="Destination .tflite path in the Flutter tree (default: %(default)s).",
    )
    p.add_argument(
        "--imgsz",
        type=int,
        default=224,
        help="Square export image size (default: %(default)s).",
    )
    p.add_argument(
        "--fraction",
        type=float,
        default=None,
        help=(
            "Fraction of val images for INT8 calibration (0.0-1.0). "
            "If omitted, fraction is chosen from --calib-cap so Ultralytics does not torch.cat "
            "the full val split (which needs tens of GiB RAM for large iNat-style sets)."
        ),
    )
    p.add_argument(
        "--calib-cap",
        type=int,
        default=DEFAULT_CALIB_IMAGE_CAP,
        help=(
            "When --fraction is omitted, use at most this many val images "
            "(fraction = min(1, cap / n_val)). Default: %(default)s."
        ),
    )
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = _build_arg_parser().parse_args(argv)

    print("=" * 72)
    print("  Project Kanto - Phase 3: INT8 TFLite export")
    print("=" * 72)

    try:
        data_path = resolve_dataset_path(args.data)
    except FileNotFoundError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 2

    try:
        fraction, _n_calib, _n_val = resolve_calibration_fraction(
            args.fraction,
            data_path / "val",
            args.calib_cap,
            args.imgsz,
        )
    except ValueError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 2

    try:
        run_dir = Path(args.run_dir).expanduser().resolve()
        weights_pt = locate_best_weights(run_dir, args.weights_name)
    except FileNotFoundError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 2

    flutter_out = Path(args.flutter_out).expanduser().resolve()
    pt_bytes = weights_pt.stat().st_size

    print(
        f"[export] format=tflite  int8=True  imgsz={args.imgsz}  "
        f"fraction={fraction}"
    )
    print(f"[export] data={data_path}")

    try:
        model = YOLO(str(weights_pt))
        exported = model.export(
            format="tflite",
            int8=True,
            imgsz=args.imgsz,
            data=str(data_path),
            fraction=fraction,
        )
    except Exception as exc:
        print(f"[error] export failed: {exc}", file=sys.stderr)
        traceback.print_exc()
        return 1

    tflite_src = Path(exported).resolve()
    if not tflite_src.is_file():
        hint = _export_output_path_hint(weights_pt)
        if hint.is_file():
            tflite_src = hint
        else:
            print(
                f"[error] export did not produce a file at {exported} "
                f"(also not at {hint})",
                file=sys.stderr,
            )
            return 1

    print(f"[export] produced: {tflite_src}")

    flutter_out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(tflite_src, flutter_out)
    print(f"[copy]   {tflite_src} -> {flutter_out}")

    tflite_bytes = flutter_out.stat().st_size
    ratio = pt_bytes / tflite_bytes if tflite_bytes else float("inf")

    print("-" * 72)
    print("[size]   file size comparison (MB, binary):")
    print(f"         {weights_pt.name}: {_mb(pt_bytes):.3f} MB")
    print(f"         {flutter_out.name}: {_mb(tflite_bytes):.3f} MB")
    if tflite_bytes <= pt_bytes:
        print(
            f"         TFLite is {100.0 * (1.0 - tflite_bytes / pt_bytes):.1f}% smaller "
            f"than the PyTorch checkpoint (~{ratio:.2f}x compression vs .pt size)."
        )
    else:
        print(
            "         TFLite is larger than the .pt on disk "
            "(possible if the checkpoint is heavily compressed or the graph bundles extra ops)."
        )
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
