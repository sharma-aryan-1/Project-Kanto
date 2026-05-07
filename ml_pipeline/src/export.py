"""
export.py - Project Kanto, Phase 3: INT8 TFLite export for edge deployment.

Loads the trained YOLOv8 classification checkpoint, runs Ultralytics export to
INT8 TFLite (with calibration images from the YOLO dataset), then copies the
artifact into the Flutter asset bundle as `best_int8.tflite`.

By default, exactly ``--calib-samples`` images are drawn from ``val/`` using a
stratified round-robin over shuffled class IDs (wide class coverage; not the
full 100k val set). A tiny YOLO-format ``train/`` + ``val/`` tree is written to
``--calib-subset-dir`` and passed to Ultralytics with ``fraction=1.0``.

Run (from repo root):
    python ml_pipeline/src/export.py
    python ml_pipeline/src/export.py --calib-samples 1000 --calib-seed 42
    python ml_pipeline/src/export.py --calib-samples 0 --fraction 0.01

INT8 TFLite export pulls in TensorFlow via Ultralytics; align TF/onnx/protobuf
versions in a dedicated venv if you hit import errors (see prior Colab / Windows notes).

Large val splits without stratified subset: Ultralytics concatenates all calibration
images into one tensor; use ``--calib-samples 0`` with ``--fraction`` / ``--calib-cap``.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import sys
import traceback
from pathlib import Path
from typing import List, Optional, Tuple

from ultralytics import YOLO


DEFAULT_DATA_DIR = Path("ml_pipeline/data/processed/yolo_dataset")
DEFAULT_RUN_DIR = Path("ml_pipeline/runs/yolov8n-cls-inat21-mini-a100")
DEFAULT_WEIGHTS_NAME = "best.pt"
DEFAULT_FLUTTER_MODEL = Path("app/assets/model/best_int8.tflite")
DEFAULT_CALIB_SUBSET_DIR = Path("ml_pipeline/data/processed/int8_calib_subset")
DEFAULT_CALIB_SAMPLES = 500
# When calib-samples is 0: Ultralytics INT8 path torch.cat()s all calibration batches.
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
    print(f"[data]   source yolo_dataset root: {path}")
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


def _list_class_images_val(val_root: Path) -> dict[str, List[Path]]:
    buckets: dict[str, List[Path]] = {}
    for d in val_root.iterdir():
        if not d.is_dir():
            continue
        imgs = [
            p
            for p in d.iterdir()
            if p.is_file() and p.suffix.lower() in _IMAGE_EXT
        ]
        if imgs:
            buckets[d.name] = imgs
    return buckets


def stratified_round_robin_sample(
    buckets: dict[str, List[Path]],
    n: int,
    rng: random.Random,
) -> List[Tuple[str, Path]]:
    """Round-robin over shuffled class IDs; maximizes distinct classes for the first n picks."""
    if n < 1:
        raise ValueError("calib-samples must be at least 1 when building stratified subset")
    classes = list(buckets.keys())
    if not classes:
        raise ValueError("No class folders with images found under val/")
    rng.shuffle(classes)

    unused: dict[str, List[Path]] = {c: buckets[c][:] for c in classes}
    for c in unused:
        rng.shuffle(unused[c])

    used_count: dict[str, int] = {c: 0 for c in classes}
    samples: List[Tuple[str, Path]] = []

    def pick_one() -> Optional[Tuple[str, Path]]:
        for c in classes:
            k = used_count[c]
            pool = unused[c]
            if k < len(pool):
                path = pool[k]
                used_count[c] = k + 1
                return (c, path)
        return None

    for _ in range(n):
        got = pick_one()
        if got is None:
            raise ValueError(
                f"Not enough validation images to sample {n} items "
                f"(stopped at {len(samples)})."
            )
        samples.append(got)

    return samples


def materialize_calib_subset(
    samples: List[Tuple[str, Path]],
    out_root: Path,
    *,
    use_hardlink: bool = False,
) -> None:
    """Write train/ and val/ trees (Ultralytics cls checks need both)."""
    if out_root.exists():
        shutil.rmtree(out_root)
    train_root = out_root / "train"
    val_root = out_root / "val"
    train_root.mkdir(parents=True, exist_ok=True)
    val_root.mkdir(parents=True, exist_ok=True)

    for i, (class_id, src) in enumerate(samples):
        dest_name = f"{i:06d}_{src.name}"
        tdir = train_root / class_id
        vdir = val_root / class_id
        tdir.mkdir(parents=True, exist_ok=True)
        vdir.mkdir(parents=True, exist_ok=True)
        tpath = tdir / dest_name
        vpath = vdir / dest_name
        if use_hardlink:
            try:
                os.link(src, tpath)
                os.link(tpath, vpath)
            except OSError:
                shutil.copy2(src, tpath)
                shutil.copy2(src, vpath)
        else:
            shutil.copy2(src, tpath)
            shutil.copy2(src, vpath)


def build_stratified_calib_dataset(
    yolo_root: Path,
    n_samples: int,
    out_root: Path,
    *,
    seed: Optional[int],
    use_hardlink: bool,
    manifest_path: Optional[Path],
) -> Tuple[Path, int]:
    """Return (subset_root_path, distinct_class_count)."""
    val_root = yolo_root / "val"
    rng = random.Random(seed)
    buckets = _list_class_images_val(val_root)
    samples = stratified_round_robin_sample(buckets, n_samples, rng)
    distinct = len({c for c, _ in samples})
    materialize_calib_subset(samples, out_root, use_hardlink=use_hardlink)

    if manifest_path is not None:
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        payload = [
            {"index": i, "class_id": c, "source": str(p.resolve())}
            for i, (c, p) in enumerate(samples)
        ]
        manifest_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"[calib]  wrote manifest {manifest_path}")

    print(
        f"[calib]  stratified subset: {len(samples)} images, "
        f"{distinct} distinct class IDs -> {out_root}"
    )
    return out_root.resolve(), distinct


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
    approx_ram_gib = (n_calib * 3 * (imgsz**2) * 4) / (1024**3)
    if n_calib > cap or approx_ram_gib >= 4.0:
        print(
            f"[calib]  note: Ultralytics stacks calibration tensors in RAM (~{approx_ram_gib:.1f} GiB "
            f"order-of-magnitude at imgsz={imgsz}). "
            "Raise default --calib-samples or use --calib-cap / lower --fraction."
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
        help="Full yolo_dataset root (train/ + val/); val/ is sampled from here (default: %(default)s).",
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
        "--calib-samples",
        type=int,
        default=DEFAULT_CALIB_SAMPLES,
        help=(
            "If > 0, build a stratified subset of exactly this many val images and use it for INT8 "
            "(export fraction=1.0). If 0, use the full yolo_dataset with --fraction / --calib-cap. "
            "Default: %(default)s."
        ),
    )
    p.add_argument(
        "--calib-seed",
        type=int,
        default=None,
        help="RNG seed for stratified sampling (default: OS entropy).",
    )
    p.add_argument(
        "--calib-subset-dir",
        default=str(DEFAULT_CALIB_SUBSET_DIR),
        help="Where to write the temporary train/val calib subset (default: %(default)s).",
    )
    p.add_argument(
        "--calib-hardlink",
        action="store_true",
        help="Try hardlinks into calib subset (same volume; falls back to copy).",
    )
    p.add_argument(
        "--calib-manifest",
        default=None,
        help="Optional JSON path listing sampled class_id + source image paths.",
    )
    p.add_argument(
        "--fraction",
        type=float,
        default=None,
        help=(
            "Only when --calib-samples 0: fraction of val for calibration (0-1). "
            "If omitted, --calib-cap sets an automatic cap."
        ),
    )
    p.add_argument(
        "--calib-cap",
        type=int,
        default=DEFAULT_CALIB_IMAGE_CAP,
        help="Only when --calib-samples 0: max val images via fraction=min(1,cap/n). Default: %(default)s.",
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
        run_dir = Path(args.run_dir).expanduser().resolve()
        weights_pt = locate_best_weights(run_dir, args.weights_name)
    except FileNotFoundError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 2

    export_data: Path
    export_fraction: float

    if args.calib_samples > 0:
        if args.fraction is not None or args.calib_cap != DEFAULT_CALIB_IMAGE_CAP:
            print(
                "[calib]  note: --fraction / --calib-cap are ignored when --calib-samples > 0.",
                file=sys.stderr,
            )
        subset_root = Path(args.calib_subset_dir).expanduser().resolve()
        man = Path(args.calib_manifest).expanduser().resolve() if args.calib_manifest else None
        try:
            export_data, _distinct = build_stratified_calib_dataset(
                data_path,
                args.calib_samples,
                subset_root,
                seed=args.calib_seed,
                use_hardlink=args.calib_hardlink,
                manifest_path=man,
            )
        except ValueError as exc:
            print(f"[error] {exc}", file=sys.stderr)
            return 2
        export_fraction = 1.0
    else:
        try:
            export_fraction, _n_calib, _n_val = resolve_calibration_fraction(
                args.fraction,
                data_path / "val",
                args.calib_cap,
                args.imgsz,
            )
        except ValueError as exc:
            print(f"[error] {exc}", file=sys.stderr)
            return 2
        export_data = data_path

    flutter_out = Path(args.flutter_out).expanduser().resolve()
    pt_bytes = weights_pt.stat().st_size

    print(
        f"[export] format=tflite  int8=True  imgsz={args.imgsz}  "
        f"fraction={export_fraction}"
    )
    print(f"[export] data={export_data}")

    try:
        model = YOLO(str(weights_pt))
        exported = model.export(
            format="tflite",
            int8=True,
            imgsz=args.imgsz,
            data=str(export_data),
            fraction=export_fraction,
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
