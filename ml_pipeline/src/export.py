"""
export.py - Export best.pt (YOLOv8n-cls) to TFLite for the Flutter bundle.

Produces both quantized and full-precision artifacts:
    app/assets/model/best_int8.tflite     (INT8, calibrated on a random val sample)
    app/assets/model/best_float.tflite    (float32 fallback)

Run inside the tf-env conda env (WSL):
    python ml_pipeline/src/export.py            # both
    python ml_pipeline/src/export.py --mode int8
    python ml_pipeline/src/export.py --mode float
"""

from __future__ import annotations

import argparse
import random
import shutil
import sys
from pathlib import Path

from ultralytics import YOLO


REPO_ROOT = Path(__file__).resolve().parents[2]
WEIGHTS = REPO_ROOT / "ml_pipeline/runs/yolov8n-cls-inat21-mini-a100/weights/best.pt"
VAL_ROOT = REPO_ROOT / "ml_pipeline/data/processed/yolo_dataset/val"
CALIB_ROOT = REPO_ROOT / "ml_pipeline/data/processed/_calib_tmp"
APP_MODELS = REPO_ROOT / "app/assets/model"
IMGSZ = 224
N_CALIB = 200
SEED = 1337
_IMG_EXTS = {".jpg", ".jpeg", ".png"}


def sample_calibration_set(val_root: Path, out_root: Path, n: int, seed: int) -> Path:
    """Copy `n` random val images into a fresh {train,val}/<class>/ tree.

    Ultralytics' classify export expects both splits present, so the same
    sampled images are mirrored under train/ and val/.
    """
    rng = random.Random(seed)
    all_imgs: list[tuple[str, Path]] = []
    for cls_dir in val_root.iterdir():
        if not cls_dir.is_dir():
            continue
        for img in cls_dir.iterdir():
            if img.is_file() and img.suffix.lower() in _IMG_EXTS:
                all_imgs.append((cls_dir.name, img))

    if len(all_imgs) < n:
        raise RuntimeError(f"only {len(all_imgs):,} val images on disk; need {n}")

    sampled = rng.sample(all_imgs, n)
    distinct = len({c for c, _ in sampled})

    if out_root.exists():
        shutil.rmtree(out_root)
    for split in ("train", "val"):
        for cls, img in sampled:
            dest_dir = out_root / split / cls
            dest_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(img, dest_dir / img.name)

    print(f"[calib] {n} images sampled across {distinct} classes -> {out_root}")
    return out_root


def cleanup_intermediates(weights: Path) -> None:
    """Remove Ultralytics export side-effects so each run starts fresh."""
    saved_model = weights.parent / f"{weights.stem}_saved_model"
    onnx = weights.with_suffix(".onnx")
    if saved_model.exists():
        shutil.rmtree(saved_model)
    if onnx.exists():
        onnx.unlink()


def resolve_tflite_output(reported: str | Path, weights: Path, int8: bool) -> Path:
    """Trust Ultralytics' returned path; fall back to globbing the saved_model dir."""
    p = Path(reported)
    if p.is_file():
        return p
    saved_model = weights.parent / f"{weights.stem}_saved_model"
    candidates = sorted(saved_model.glob("*.tflite"))
    if not candidates:
        raise FileNotFoundError(
            f"export reported {reported} but no .tflite found under {saved_model}"
        )
    keyword = "int8" if int8 else "float"
    for c in candidates:
        if keyword in c.name.lower():
            return c
    return candidates[0]


def export_tflite(weights: Path, *, int8: bool, imgsz: int, calib_root: Path | None) -> Path:
    cleanup_intermediates(weights)
    model = YOLO(str(weights))
    kwargs: dict = dict(format="tflite", int8=int8, imgsz=imgsz)
    if int8:
        if calib_root is None:
            raise ValueError("INT8 export requires calib_root")
        kwargs["data"] = str(calib_root)
        kwargs["fraction"] = 1.0
    reported = model.export(**kwargs)
    return resolve_tflite_output(reported, weights, int8=int8)


def place(src: Path, name: str) -> Path:
    APP_MODELS.mkdir(parents=True, exist_ok=True)
    dest = APP_MODELS / name
    shutil.copy2(src, dest)
    size_mb = dest.stat().st_size / (1024 * 1024)
    print(f"[ok] {name}: {size_mb:.2f} MB -> {dest}")
    return dest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else None)
    ap.add_argument("--mode", choices=("int8", "float", "both"), default="both")
    ap.add_argument("--n-calib", type=int, default=N_CALIB)
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--imgsz", type=int, default=IMGSZ)
    args = ap.parse_args(argv)

    if not WEIGHTS.is_file():
        print(f"[error] weights not found: {WEIGHTS}", file=sys.stderr)
        return 2

    print(f"[weights] {WEIGHTS}  ({WEIGHTS.stat().st_size / (1024 * 1024):.2f} MB)")
    placed: dict[str, Path] = {}

    if args.mode in ("int8", "both"):
        if not VAL_ROOT.is_dir():
            print(f"[error] val dir not found: {VAL_ROOT}", file=sys.stderr)
            return 2
        calib_root = sample_calibration_set(VAL_ROOT, CALIB_ROOT, args.n_calib, args.seed)
        produced = export_tflite(WEIGHTS, int8=True, imgsz=args.imgsz, calib_root=calib_root)
        placed["best_int8.tflite"] = place(produced, "best_int8.tflite")

    if args.mode in ("float", "both"):
        produced = export_tflite(WEIGHTS, int8=False, imgsz=args.imgsz, calib_root=None)
        placed["best_float.tflite"] = place(produced, "best_float.tflite")

    print("-" * 60)
    print(f"[summary] wrote {len(placed)} artifact(s) to {APP_MODELS}")
    for name, path in placed.items():
        size_mb = path.stat().st_size / (1024 * 1024)
        print(f"          {name:24s}  {size_mb:7.2f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
