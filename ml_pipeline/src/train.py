"""
train.py - Project Kanto, Phase 2 training driver.

Trains a YOLOv8 Nano Classification model (`yolov8n-cls.pt`) on the iNat21
Mini species dataset that `data_prep.py` materialized at
`ml_pipeline/data/processed/yolo_dataset/`.

Augmentation hyperparameters are loaded from `ml_pipeline/configs/hyp.yaml`
and unpacked into `model.train(...)` so every applied setting is logged
to stdout before training starts. The script auto-selects the best
available device (CUDA -> MPS -> CPU) and wraps each major initialization
step in try/except so failure modes are obvious.

Run:
    python ml_pipeline/src/train.py
    python ml_pipeline/src/train.py --epochs 100 --batch 128
    python ml_pipeline/src/train.py --data /abs/path/to/yolo_dataset
"""

from __future__ import annotations

import argparse
import sys
import traceback
from pathlib import Path
from typing import Optional

import torch
import yaml
from ultralytics import YOLO


DEFAULT_DATA_DIR = Path("ml_pipeline/data/processed/yolo_dataset")
DEFAULT_HYP_PATH = Path("ml_pipeline/configs/hyp.yaml")
DEFAULT_PROJECT_DIR = Path("ml_pipeline/runs")
DEFAULT_EXPERIMENT_NAME = "yolov8n-cls-inat21-mini"
DEFAULT_MODEL = "yolov8n-cls.pt"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def select_device() -> str:
    """Return the highest-priority available accelerator: cuda > mps > cpu."""
    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        cap = torch.cuda.get_device_capability(0)
        mem_gb = torch.cuda.get_device_properties(0).total_memory / (1024**3)
        print(
            f"[device] CUDA available -> {name} "
            f"(capability {cap[0]}.{cap[1]}, {mem_gb:.1f} GB VRAM)"
        )
        return "cuda"

    mps_backend = getattr(torch.backends, "mps", None)
    if mps_backend is not None and mps_backend.is_available():
        print("[device] MPS (Apple Silicon GPU) available")
        return "mps"

    print("[device] no GPU detected, falling back to CPU")
    return "cpu"


def load_hyperparameters(hyp_path: Path) -> dict:
    """Load augmentation hyperparameters from YAML and echo them to stdout."""
    if not hyp_path.exists():
        raise FileNotFoundError(f"hyp file not found: {hyp_path}")
    with hyp_path.open("r", encoding="utf-8") as f:
        hyp = yaml.safe_load(f) or {}
    if not isinstance(hyp, dict):
        raise ValueError(
            f"hyp file at {hyp_path} did not parse to a mapping (got {type(hyp).__name__})"
        )
    print(f"[hyp]    loaded {len(hyp)} augmentation settings from {hyp_path}")
    for key in sorted(hyp):
        print(f"         {key}: {hyp[key]}")
    return hyp


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
    n_train_classes = sum(1 for p in train_dir.iterdir() if p.is_dir())
    n_val_classes = sum(1 for p in val_dir.iterdir() if p.is_dir())
    print(
        f"[data]   {path}\n"
        f"         train classes: {n_train_classes:,}, "
        f"val classes: {n_val_classes:,}"
    )
    return path


# ---------------------------------------------------------------------------
# CLI / main
# ---------------------------------------------------------------------------

def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Train YOLOv8n-cls on the iNat21 Mini species dataset.",
    )
    p.add_argument(
        "--data",
        default=str(DEFAULT_DATA_DIR),
        help="Path to yolo_dataset/ root (default: %(default)s).",
    )
    p.add_argument(
        "--hyp",
        default=str(DEFAULT_HYP_PATH),
        help="Augmentation hyperparameter YAML (default: %(default)s).",
    )
    p.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help="Pretrained YOLOv8 weights to start from (default: %(default)s).",
    )
    p.add_argument("--epochs", type=int, default=50)
    p.add_argument("--imgsz", type=int, default=224)
    p.add_argument("--batch", type=int, default=64)
    p.add_argument("--patience", type=int, default=10, help="early-stopping patience")
    p.add_argument(
        "--workers",
        type=int,
        default=4,
        help=(
            "DataLoader worker processes (default: %(default)s). Drop to 2 "
            "or 0 if the machine is thermally / power constrained; the "
            "Ultralytics default of 8 can saturate a laptop CPU."
        ),
    )
    p.add_argument(
        "--project",
        default=str(DEFAULT_PROJECT_DIR),
        help="Parent directory for run artifacts (default: %(default)s).",
    )
    p.add_argument(
        "--name",
        default=DEFAULT_EXPERIMENT_NAME,
        help="Run subdirectory name (default: %(default)s).",
    )
    p.add_argument(
        "--device",
        default=None,
        help="Override auto-selected device (e.g. 'cpu', 'cuda', '0', 'mps').",
    )
    p.add_argument(
        "--exist-ok",
        action="store_true",
        help="Allow overwriting an existing run directory.",
    )
    p.add_argument(
        "--save-period",
        type=int,
        default=1,
        help=(
            "Save a checkpoint every N epochs. Default 1 means a recoverable "
            "checkpoint after every epoch, so a mid-run crash loses at most "
            "one epoch of progress. Set to -1 to save only at end of training."
        ),
    )
    p.add_argument(
        "--resume",
        action="store_true",
        help=(
            "Resume from the most recent checkpoint at "
            "<project>/<name>/weights/last.pt. Pass alongside the same --name "
            "as the original run."
        ),
    )
    p.add_argument(
        "--fraction",
        type=float,
        default=1.0,
        help=(
            "Fraction of the training set to use (0.0-1.0). Defaults to 1.0. "
            "Useful for short pipeline-validation runs (e.g. --fraction 0.05)."
        ),
    )
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = _build_arg_parser().parse_args(argv)

    print("=" * 72)
    print("  Project Kanto - Phase 2: YOLOv8n-cls fine-grained training")
    print("=" * 72)

    try:
        data_path = resolve_dataset_path(args.data)
    except FileNotFoundError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 2

    try:
        hyp = load_hyperparameters(Path(args.hyp))
    except (FileNotFoundError, ValueError, yaml.YAMLError) as exc:
        print(f"[error] could not load hyperparameters: {exc}", file=sys.stderr)
        return 2

    try:
        device = args.device or select_device()
    except Exception as exc:
        print(f"[error] device selection failed: {exc}", file=sys.stderr)
        return 1

    project_dir = Path(args.project).resolve()
    project_dir.mkdir(parents=True, exist_ok=True)

    weights_to_load = args.model
    if args.resume:
        last_pt = project_dir / args.name / "weights" / "last.pt"
        if not last_pt.exists():
            print(
                f"[error] --resume given but no checkpoint at {last_pt}",
                file=sys.stderr,
            )
            return 2
        weights_to_load = str(last_pt)
        print(f"[resume] continuing from checkpoint: {last_pt}")

    print(f"[model]  loading weights: {weights_to_load}")
    try:
        model = YOLO(weights_to_load)
    except Exception as exc:
        print(f"[error] failed to load model '{weights_to_load}': {exc}", file=sys.stderr)
        traceback.print_exc()
        return 1
    print(f"[model]  YOLOv8 task: {model.task}")

    print("[train]  starting training")
    print(
        f"         epochs={args.epochs}  imgsz={args.imgsz}  "
        f"batch={args.batch}  workers={args.workers}  "
        f"patience={args.patience}  device={device}"
    )
    print(
        f"         save_period={args.save_period}  fraction={args.fraction}  "
        f"resume={args.resume}"
    )
    print(f"         project={project_dir}/{args.name}")
    print("-" * 72)

    try:
        results = model.train(
            data=str(data_path),
            epochs=args.epochs,
            imgsz=args.imgsz,
            batch=args.batch,
            workers=args.workers,
            patience=args.patience,
            device=device,
            project=str(project_dir),
            name=args.name,
            exist_ok=args.exist_ok or args.resume,
            save_period=args.save_period,
            fraction=args.fraction,
            resume=args.resume,
            **hyp,
        )
    except KeyboardInterrupt:
        print("\n[train]  interrupted by user (Ctrl+C)", file=sys.stderr)
        return 130
    except torch.cuda.OutOfMemoryError as exc:
        print(
            f"[error] CUDA out of memory: {exc}\n"
            "        Try a smaller --batch (e.g. 32 or 16) or smaller --imgsz.",
            file=sys.stderr,
        )
        return 1
    except NotImplementedError as exc:
        msg = str(exc)
        if "torchvision::nms" in msg and "CUDA" in msg:
            import torchvision
            print(
                f"[error] torchvision::nms is not available on CUDA.\n"
                f"        torch={torch.__version__}, "
                f"torchvision={torchvision.__version__}\n"
                "        torchvision was installed as the CPU-only build "
                "but torch has CUDA support.\n"
                "        Reinstall torchvision from the matching CUDA index, e.g.\n"
                "          pip install --index-url "
                "https://download.pytorch.org/whl/cu118 torchvision==0.19.1",
                file=sys.stderr,
            )
            return 1
        print(f"[error] training failed: {exc}", file=sys.stderr)
        traceback.print_exc()
        return 1
    except Exception as exc:
        print(f"[error] training failed: {exc}", file=sys.stderr)
        traceback.print_exc()
        return 1

    print("-" * 72)
    save_dir = getattr(results, "save_dir", project_dir / args.name)
    print(f"[done]   training complete; artifacts written to {save_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
