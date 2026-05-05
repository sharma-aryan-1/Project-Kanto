"""
data_prep.py - Project Kanto, Phase 2.

Reshape the flat `taxonomy_map.csv` produced by `data_fetcher.py` into the
strict directory layout that Ultralytics' YOLOv8-cls trainer expects:

    yolo_dataset/
        train/
            00000/
                <basename>.jpg
                ...
            00001/
            ...
        val/
            00000/
            ...

Each leaf entry is a symbolic link back to the original JPG in
`ml_pipeline/data/raw/`, so the YOLO tree adds essentially zero disk usage.

Class folder names are zero-padded (`00000`..`09999` for iNaturalist 2021)
so that Ultralytics' lexicographic class enumeration matches the numeric
`class_id` from the CSV.

A small `species_config.yaml` is written to the configs directory with the
absolute dataset path and the number of classes, ready to be passed into a
YOLOv8 classification training run.
"""

from __future__ import annotations

import argparse
import os
import shutil
from pathlib import Path
from typing import Literal, Optional

import pandas as pd
import yaml
from sklearn.model_selection import train_test_split
from tqdm.auto import tqdm

DEFAULT_CSV = Path("ml_pipeline/data/processed/taxonomy_map.csv")
DEFAULT_OUT_DIR = Path("ml_pipeline/data/processed/yolo_dataset")
DEFAULT_CONFIG_PATH = Path("ml_pipeline/configs/species_config.yaml")

LinkMode = Literal["symlink", "hardlink", "copy"]


# ---------------------------------------------------------------------------
# Linking primitives
# ---------------------------------------------------------------------------

def _make_link(src: Path, dst: Path, mode: LinkMode) -> None:
    """Materialize `dst` from `src` using the chosen strategy.

    Idempotent: if `dst` already exists or is an existing symlink, no-op.
    """
    if dst.exists() or dst.is_symlink():
        return

    if mode == "symlink":
        os.symlink(src, dst)
    elif mode == "hardlink":
        os.link(src, dst)
    elif mode == "copy":
        shutil.copy2(src, dst)
    else:
        raise ValueError(f"Unknown link mode: {mode!r}")


# ---------------------------------------------------------------------------
# Stratified split
# ---------------------------------------------------------------------------

def stratified_train_val_split(
    df: pd.DataFrame,
    *,
    val_fraction: float = 0.2,
    random_state: int = 42,
    stratify_col: str = "class_id",
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """80/20 (or whatever `val_fraction`) stratified split on `stratify_col`.

    Classes that have only a single sample cannot be stratified into both
    splits; those rows are forced into the train set so they are not silently
    dropped.
    """
    counts = df[stratify_col].value_counts()
    singletons = counts[counts < 2].index
    forced_train = df[df[stratify_col].isin(singletons)]
    splittable = df[~df[stratify_col].isin(singletons)]

    if singletons.size:
        print(
            f"[warn] {singletons.size} class(es) have <2 samples; "
            "those rows are placed entirely in the train split."
        )

    train_df, val_df = train_test_split(
        splittable,
        test_size=val_fraction,
        random_state=random_state,
        stratify=splittable[stratify_col],
    )

    if not forced_train.empty:
        train_df = pd.concat([train_df, forced_train], ignore_index=True)

    return (
        train_df.reset_index(drop=True),
        val_df.reset_index(drop=True),
    )


# ---------------------------------------------------------------------------
# Tree builder
# ---------------------------------------------------------------------------

def build_yolo_classification_tree(
    csv_path: Path,
    out_dir: Path,
    *,
    val_fraction: float = 0.2,
    random_state: int = 42,
    link_mode: LinkMode = "symlink",
    clean: bool = False,
) -> tuple[int, int, int]:
    """Build the train/<class>/ + val/<class>/ tree of links.

    Returns ``(n_train, n_val, n_classes)``.
    """
    csv_path = Path(csv_path)
    out_dir = Path(out_dir)

    df = pd.read_csv(csv_path)
    required = {"image_path", "class_id"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"CSV at {csv_path} is missing columns: {sorted(missing)}")

    # Filter out rows whose JPG isn't actually on disk - prevents broken
    # symlinks and silent data loss for partial datasets.
    tqdm.pandas(desc="check files", ascii=True)
    exists_mask = df["image_path"].progress_apply(lambda p: Path(p).exists())
    n_missing = int((~exists_mask).sum())
    if n_missing:
        print(
            f"[warn] {n_missing:,} of {len(df):,} CSV rows reference files "
            "that aren't on disk; they will be skipped."
        )
    df = df.loc[exists_mask].reset_index(drop=True)
    if df.empty:
        raise RuntimeError("No image files found on disk for any CSV row.")

    # Reset / clean output directory if requested.
    if clean and out_dir.exists():
        print(f"[clean] removing {out_dir}")
        shutil.rmtree(out_dir)

    train_dir = out_dir / "train"
    val_dir = out_dir / "val"
    train_dir.mkdir(parents=True, exist_ok=True)
    val_dir.mkdir(parents=True, exist_ok=True)

    classes = sorted(df["class_id"].unique().tolist())
    pad_width = max(len(str(max(classes))), 1)

    train_df, val_df = stratified_train_val_split(
        df,
        val_fraction=val_fraction,
        random_state=random_state,
    )

    # Pre-create every class subdirectory in both splits so the tree shape
    # is consistent even for classes that ended up with a single sample.
    for cid in classes:
        name = str(cid).zfill(pad_width)
        (train_dir / name).mkdir(parents=True, exist_ok=True)
        (val_dir / name).mkdir(parents=True, exist_ok=True)

    for split_name, split_df, split_dir in (
        ("train", train_df, train_dir),
        ("val", val_df, val_dir),
    ):
        for class_id, group in tqdm(
            split_df.groupby("class_id"),
            desc=f"link {split_name} ({link_mode})",
            unit="cls",
            ascii=True,
        ):
            class_dir = split_dir / str(class_id).zfill(pad_width)
            for src_str in group["image_path"]:
                src = Path(src_str).resolve()
                dst = class_dir / src.name
                try:
                    _make_link(src, dst, link_mode)
                except OSError as exc:
                    raise RuntimeError(
                        f"Failed to create {link_mode} {dst} -> {src}: {exc}.\n"
                        "On Windows, os.symlink() requires either Administrator "
                        "rights or Developer Mode (Settings > For developers > "
                        "Developer Mode). Re-run with --link-mode hardlink as a "
                        "drop-in alternative on the same NTFS volume, or "
                        "--link-mode copy to fall back to file copies."
                    ) from exc

    return len(train_df), len(val_df), len(classes)


# ---------------------------------------------------------------------------
# species_config.yaml
# ---------------------------------------------------------------------------

def write_species_config(
    config_path: Path,
    yolo_dataset_dir: Path,
    nc: int,
) -> Path:
    """Write a minimal Ultralytics-compatible classification config."""
    config_path = Path(config_path)
    yolo_dataset_dir = Path(yolo_dataset_dir)
    config_path.parent.mkdir(parents=True, exist_ok=True)

    payload = {
        "path": str(yolo_dataset_dir.resolve()).replace("\\", "/"),
        "nc": int(nc),
    }
    with config_path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(payload, f, sort_keys=False)
    return config_path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=(
            "Build a YOLOv8-cls dataset tree (train/<class>/ + val/<class>/) "
            "of symlinks from taxonomy_map.csv, plus a species_config.yaml."
        ),
    )
    p.add_argument(
        "--csv",
        default=str(DEFAULT_CSV),
        help="Input flat CSV from data_fetcher.py (default: %(default)s).",
    )
    p.add_argument(
        "--out-dir",
        default=str(DEFAULT_OUT_DIR),
        help="Destination yolo_dataset/ root (default: %(default)s).",
    )
    p.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG_PATH),
        help="Output species_config.yaml path (default: %(default)s).",
    )
    p.add_argument(
        "--val-fraction",
        type=float,
        default=0.2,
        help="Validation fraction for the stratified split (default: %(default)s).",
    )
    p.add_argument(
        "--random-state",
        type=int,
        default=42,
        help="Random seed for the stratified split (default: %(default)s).",
    )
    p.add_argument(
        "--link-mode",
        choices=["symlink", "hardlink", "copy"],
        default="symlink",
        help=(
            "How to materialize each image into the YOLO tree (default: %(default)s). "
            "On Windows, 'symlink' needs admin or Developer Mode; 'hardlink' is a "
            "robust same-volume fallback."
        ),
    )
    p.add_argument(
        "--clean",
        action="store_true",
        help="Delete the output directory before rebuilding it.",
    )
    return p.parse_args()


def main(argv: Optional[list[str]] = None) -> None:
    args = _parse_args() if argv is None else _parse_args()

    n_train, n_val, n_classes = build_yolo_classification_tree(
        csv_path=Path(args.csv),
        out_dir=Path(args.out_dir),
        val_fraction=args.val_fraction,
        random_state=args.random_state,
        link_mode=args.link_mode,
        clean=args.clean,
    )

    config_path = write_species_config(
        config_path=Path(args.config),
        yolo_dataset_dir=Path(args.out_dir),
        nc=n_classes,
    )

    print(
        f"[done] {n_train:,} train + {n_val:,} val images across "
        f"{n_classes:,} classes -> {args.out_dir}"
    )
    print(f"[done] wrote config -> {config_path}")


if __name__ == "__main__":
    main()
