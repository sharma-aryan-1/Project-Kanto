"""
data_fetcher.py - Project Kanto, Phase 1.

Responsibilities for the offline mobile object detector:

    1. `download_file` / `extract_tar_gz` provide a resumable, streaming
       downloader and a tar.gz extractor, both with `tqdm` progress bars.

    2. `fetch_inat21_mini` orchestrates the iNaturalist 2021 Mini
       pipeline: download `train_mini.tar.gz` and `train_mini.json.tar.gz`
       from the AWS Open Data registry into `ml_pipeline/data/raw/`,
       extract them, then parse the JSON into a flat taxonomy CSV at
       `ml_pipeline/data/processed/taxonomy_map.csv` with columns:
           image_path, class_id, kingdom, phylum, class, order,
           family, genus, scientific_name, common_name

    3. `coco_to_csv` parses a standard COCO-format JSON annotation file
       (with bounding boxes) into a flat CSV with columns:
           image_path, x_min, y_min, x_max, y_max, class_id

    4. `YoloDetectionDataset` is a custom `torch.utils.data.Dataset`
       that reads the detection CSV, applies Albumentations augmentations
       (Blur, RandomBrightness, BBoxSafeRandomCrop), and emits tensors
       formatted for a YOLOv8 training loop. Bounding boxes are
       returned in YOLO format `[x_center, y_center, width, height]`
       normalized between 0 and 1.

A `__main__` entry point with subcommands is provided so the file can
be invoked from the command line.
"""

from __future__ import annotations

import argparse
import json
import os
import tarfile
from collections import defaultdict
from pathlib import Path
from typing import Optional

import albumentations as A
import cv2
import numpy as np
import pandas as pd
import requests
import torch
from albumentations.pytorch import ToTensorV2
from torch.utils.data import Dataset
from tqdm.auto import tqdm

# ---------------------------------------------------------------------------
# Constants: AWS Open Data URLs for the iNaturalist 2021 Mini split.
# ---------------------------------------------------------------------------

INAT21_MINI_IMAGES_URL = (
    "https://ml-inat-competition-datasets.s3.amazonaws.com/2021/train_mini.tar.gz"
)
INAT21_MINI_ANNOTATIONS_URL = (
    "https://ml-inat-competition-datasets.s3.amazonaws.com/2021/train_mini.json.tar.gz"
)

DEFAULT_RAW_DIR = Path("ml_pipeline/data/raw")
DEFAULT_PROCESSED_DIR = Path("ml_pipeline/data/processed")


# ---------------------------------------------------------------------------
# 0. Download / extract helpers
# ---------------------------------------------------------------------------

def download_file(
    url: str,
    dest: str | os.PathLike,
    *,
    chunk_size: int = 1 << 20,
    resume: bool = True,
    force: bool = False,
    timeout: float = 60.0,
) -> Path:
    """Stream-download `url` to `dest` with a tqdm progress bar.

    * Skips the download if the file already exists with the expected size.
    * Resumes a partial download via HTTP `Range` when the server reports
      `Accept-Ranges: bytes` (important for the ~42 GB iNat21 image tar).
    * Set `force=True` to ignore any existing file and re-download.
    """
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)

    head = requests.head(url, allow_redirects=True, timeout=timeout)
    head.raise_for_status()
    total = int(head.headers.get("Content-Length", 0))
    accepts_ranges = head.headers.get("Accept-Ranges", "").lower() == "bytes"

    if not force and dest.exists() and total > 0 and dest.stat().st_size == total:
        print(f"[skip] already complete: {dest.name} ({total / 1e9:.2f} GB)")
        return dest

    headers: dict[str, str] = {}
    mode = "wb"
    initial = 0
    if (
        not force
        and resume
        and accepts_ranges
        and dest.exists()
        and 0 < dest.stat().st_size < total
    ):
        initial = dest.stat().st_size
        headers["Range"] = f"bytes={initial}-"
        mode = "ab"

    with requests.get(url, stream=True, timeout=timeout, headers=headers) as r:
        r.raise_for_status()
        with open(dest, mode) as f, tqdm(
            total=total or None,
            initial=initial,
            unit="B",
            unit_scale=True,
            unit_divisor=1024,
            desc=dest.name,
            ascii=True,
        ) as pbar:
            for chunk in r.iter_content(chunk_size=chunk_size):
                if not chunk:
                    continue
                f.write(chunk)
                pbar.update(len(chunk))
    return dest


def extract_tar_gz(
    archive_path: str | os.PathLike,
    dest_dir: str | os.PathLike,
) -> Path:
    """Extract a `.tar.gz` archive into `dest_dir` with a per-member progress bar."""
    archive_path = Path(archive_path)
    dest_dir = Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    with tarfile.open(archive_path, "r:gz") as tf:
        members = tf.getmembers()
        for member in tqdm(
            members,
            desc=f"extract {archive_path.name}",
            unit="file",
            ascii=True,
        ):
            try:
                tf.extract(member, path=dest_dir, filter="data")
            except TypeError:
                # Python < 3.12 has no `filter` kwarg.
                tf.extract(member, path=dest_dir)
    return dest_dir


# ---------------------------------------------------------------------------
# 1. COCO -> flat CSV
# ---------------------------------------------------------------------------

def coco_to_csv(
    coco_json_path: str | os.PathLike,
    images_root: str | os.PathLike,
    output_csv_path: str | os.PathLike,
    *,
    skip_crowd: bool = True,
    min_box_size: float = 1.0,
    write_class_map: bool = True,
) -> pd.DataFrame:
    """Parse a COCO JSON file into a flat per-annotation CSV.

    Output columns: ``image_path, x_min, y_min, x_max, y_max, class_id``.

    COCO ``category_id`` values are sparse (e.g. 1..90 with gaps), so they
    are remapped to a contiguous 0-indexed ``class_id`` suitable for
    YOLOv8. The remapping is persisted next to the CSV as
    ``<output_csv>.classes.json`` so downstream code can recover the
    original category names.
    """
    coco_json_path = Path(coco_json_path)
    images_root = Path(images_root)
    output_csv_path = Path(output_csv_path)

    with coco_json_path.open("r", encoding="utf-8") as f:
        coco = json.load(f)

    images = {img["id"]: img for img in coco["images"]}

    sorted_categories = sorted(coco["categories"], key=lambda c: c["id"])
    cat_id_to_class_id = {c["id"]: idx for idx, c in enumerate(sorted_categories)}
    class_id_to_name = {idx: c["name"] for idx, c in enumerate(sorted_categories)}

    rows: list[dict] = []
    for ann in coco["annotations"]:
        if skip_crowd and ann.get("iscrowd", 0) == 1:
            continue
        if ann["category_id"] not in cat_id_to_class_id:
            continue

        img_meta = images.get(ann["image_id"])
        if img_meta is None:
            continue

        # COCO bbox is [x, y, w, h] in absolute pixels.
        x, y, w, h = ann["bbox"]
        if w < min_box_size or h < min_box_size:
            continue

        img_w = float(img_meta["width"])
        img_h = float(img_meta["height"])
        x_min = max(0.0, float(x))
        y_min = max(0.0, float(y))
        x_max = min(img_w, float(x) + float(w))
        y_max = min(img_h, float(y) + float(h))
        if x_max - x_min < min_box_size or y_max - y_min < min_box_size:
            continue

        rows.append(
            {
                "image_path": (images_root / img_meta["file_name"]).as_posix(),
                "x_min": x_min,
                "y_min": y_min,
                "x_max": x_max,
                "y_max": y_max,
                "class_id": cat_id_to_class_id[ann["category_id"]],
            }
        )

    df = pd.DataFrame(
        rows,
        columns=["image_path", "x_min", "y_min", "x_max", "y_max", "class_id"],
    )
    output_csv_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_csv_path, index=False)

    if write_class_map:
        map_path = output_csv_path.with_suffix(output_csv_path.suffix + ".classes.json")
        with map_path.open("w", encoding="utf-8") as f:
            json.dump(class_id_to_name, f, indent=2)

    return df


# ---------------------------------------------------------------------------
# 2. iNaturalist 2021 Mini -> taxonomy CSV
# ---------------------------------------------------------------------------

# Taxonomy levels we surface in the flat CSV (in biological order).
INAT_TAXONOMY_LEVELS: tuple[str, ...] = (
    "kingdom",
    "phylum",
    "class",
    "order",
    "family",
    "genus",
)

TAXONOMY_CSV_COLUMNS: tuple[str, ...] = (
    "image_path",
    "class_id",
    *INAT_TAXONOMY_LEVELS,
    "scientific_name",
    "common_name",
)


def _category_scientific_name(cat: dict) -> str:
    """Resolve a category's scientific name (binomial), with fallbacks."""
    name = (cat.get("name") or "").strip()
    if name:
        return name
    genus = (cat.get("genus") or "").strip()
    species = (
        cat.get("specific_epithet")
        or cat.get("species")
        or ""
    ).strip()
    return f"{genus} {species}".strip()


def _category_common_name(cat: dict, scientific_name: str) -> str:
    """Pick the human-readable name, falling back to scientific name."""
    for key in ("common_name", "vernacular_name", "english_common_name"):
        value = (cat.get(key) or "").strip()
        if value:
            return value
    # Last-resort fallback: the supercategory (e.g. "Birds") prefixed
    # to the binomial keeps the column non-empty without inventing data.
    super_cat = (cat.get("supercategory") or "").strip()
    if super_cat and scientific_name:
        return f"{super_cat}: {scientific_name}"
    return scientific_name


def inat21_to_taxonomy_csv(
    json_path: str | os.PathLike,
    images_root: str | os.PathLike,
    output_csv_path: str | os.PathLike,
) -> pd.DataFrame:
    """Parse iNaturalist-2021 JSON into a flat taxonomy CSV.

    The iNat21 JSON follows COCO's classification schema:
      * ``categories[]`` carries the biological taxonomy
        (``kingdom``, ``phylum``, ``class``, ``order``, ``family``,
        ``genus``, ``specific_epithet``) plus a binomial ``name`` and
        sometimes ``common_name``.
      * ``images[]`` provides ``file_name`` (relative to the extraction
        root) and ``id``.
      * ``annotations[]`` joins ``image_id`` to ``category_id``; iNat21
        is single-label so each image has exactly one annotation.

    Output columns (strict order):
        image_path, class_id, kingdom, phylum, class, order,
        family, genus, scientific_name, common_name
    """
    json_path = Path(json_path)
    images_root = Path(images_root)
    output_csv_path = Path(output_csv_path)

    with json_path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    categories: dict[int, dict] = {c["id"]: c for c in data["categories"]}
    images: dict[int, dict] = {img["id"]: img for img in data["images"]}

    rows: list[dict] = []
    for ann in tqdm(
        data["annotations"],
        desc="link annotations",
        unit="ann",
        ascii=True,
    ):
        cat = categories.get(ann["category_id"])
        img = images.get(ann["image_id"])
        if cat is None or img is None:
            continue

        scientific_name = _category_scientific_name(cat)
        common_name = _category_common_name(cat, scientific_name)

        row = {
            "image_path": (images_root / img["file_name"]).as_posix(),
            "class_id": int(ann["category_id"]),
        }
        for level in INAT_TAXONOMY_LEVELS:
            row[level] = (cat.get(level) or "").strip()
        row["scientific_name"] = scientific_name
        row["common_name"] = common_name
        rows.append(row)

    df = pd.DataFrame(rows, columns=list(TAXONOMY_CSV_COLUMNS))
    output_csv_path.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(output_csv_path, index=False)
    return df


def fetch_inat21_mini(
    raw_dir: str | os.PathLike = DEFAULT_RAW_DIR,
    processed_dir: str | os.PathLike = DEFAULT_PROCESSED_DIR,
    *,
    skip_download: bool = False,
    skip_extract: bool = False,
    output_csv_name: str = "taxonomy_map.csv",
) -> pd.DataFrame:
    """End-to-end iNat21 Mini pipeline: download, extract, parse."""
    raw_dir = Path(raw_dir)
    processed_dir = Path(processed_dir)
    raw_dir.mkdir(parents=True, exist_ok=True)
    processed_dir.mkdir(parents=True, exist_ok=True)

    images_archive = raw_dir / "train_mini.tar.gz"
    annot_archive = raw_dir / "train_mini.json.tar.gz"
    annot_json = raw_dir / "train_mini.json"

    if not skip_download:
        download_file(INAT21_MINI_ANNOTATIONS_URL, annot_archive)
        download_file(INAT21_MINI_IMAGES_URL, images_archive)

    if not skip_extract:
        extract_tar_gz(annot_archive, raw_dir)
        extract_tar_gz(images_archive, raw_dir)

    if not annot_json.exists():
        raise FileNotFoundError(
            f"Expected extracted annotations at {annot_json}. "
            "Re-run without --skip-extract or check the archive contents."
        )

    output_csv = processed_dir / output_csv_name
    df = inat21_to_taxonomy_csv(
        json_path=annot_json,
        images_root=raw_dir,
        output_csv_path=output_csv,
    )
    print(
        f"[done] wrote {len(df):,} taxonomy rows across "
        f"{df['class_id'].nunique():,} classes to {output_csv}"
    )
    return df


# ---------------------------------------------------------------------------
# 3. YOLOv8 PyTorch Dataset with Albumentations augmentations
# ---------------------------------------------------------------------------

def build_default_transforms(image_size: int = 640) -> A.Compose:
    """Default Albumentations pipeline for YOLOv8 training.

    Uses the three augmentations called out in the Phase 1 spec
    (`BBoxSafeRandomCrop`, `Blur`, random brightness) plus the standard
    letterbox / normalize / to-tensor steps required by YOLOv8.

    `RandomBrightness` was deprecated and removed from Albumentations;
    `RandomBrightnessContrast` with `contrast_limit=0.0` is the
    drop-in replacement and only perturbs brightness.
    """
    return A.Compose(
        [
            A.BBoxSafeRandomCrop(erosion_rate=0.0, p=1.0),
            A.LongestMaxSize(max_size=image_size),
            A.PadIfNeeded(
                min_height=image_size,
                min_width=image_size,
                border_mode=cv2.BORDER_CONSTANT,
                value=(114, 114, 114),
            ),
            A.Blur(blur_limit=3, p=0.3),
            A.RandomBrightnessContrast(
                brightness_limit=0.2, contrast_limit=0.0, p=0.5
            ),
            A.Normalize(
                mean=(0.0, 0.0, 0.0),
                std=(1.0, 1.0, 1.0),
                max_pixel_value=255.0,
            ),
            ToTensorV2(),
        ],
        bbox_params=A.BboxParams(
            format="pascal_voc",
            label_fields=["class_ids"],
            min_visibility=0.1,
            min_area=1.0,
        ),
    )


class YoloDetectionDataset(Dataset):
    """A YOLOv8-ready Dataset backed by the flat CSV from `coco_to_csv`.

    Each sample is ``(image, targets)`` where:

    * ``image``   - ``torch.float32`` tensor of shape ``(3, H, W)``,
      values in ``[0, 1]``.
    * ``targets`` - ``torch.float32`` tensor of shape ``(N, 5)`` with
      columns ``[class_id, x_center, y_center, width, height]``.
      Bounding boxes are normalized to ``[0, 1]``.

    Pair this with `yolo_collate_fn` in your `DataLoader` to obtain the
    ``(M, 6)`` ``[batch_idx, class, x, y, w, h]`` target tensor that
    YOLOv8's loss expects.
    """

    def __init__(
        self,
        csv_path: str | os.PathLike,
        *,
        image_size: int = 640,
        transforms: Optional[A.Compose] = None,
    ) -> None:
        self.csv_path = Path(csv_path)
        self.image_size = image_size
        self.transforms = transforms or build_default_transforms(image_size)

        df = pd.read_csv(self.csv_path)
        required = {"image_path", "x_min", "y_min", "x_max", "y_max", "class_id"}
        missing = required - set(df.columns)
        if missing:
            raise ValueError(
                f"CSV at {self.csv_path} is missing required columns: "
                f"{sorted(missing)}"
            )

        grouped: dict[str, list[tuple[float, float, float, float, int]]] = defaultdict(list)
        for row in df.itertuples(index=False):
            grouped[row.image_path].append(
                (
                    float(row.x_min),
                    float(row.y_min),
                    float(row.x_max),
                    float(row.y_max),
                    int(row.class_id),
                )
            )

        self.image_paths: list[str] = list(grouped.keys())
        self.annotations: list[list[tuple[float, float, float, float, int]]] = [
            grouped[p] for p in self.image_paths
        ]

    def __len__(self) -> int:
        return len(self.image_paths)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor]:
        image_path = self.image_paths[idx]
        image_bgr = cv2.imread(image_path, cv2.IMREAD_COLOR)
        if image_bgr is None:
            raise FileNotFoundError(f"Could not read image: {image_path}")
        image = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)

        anns = self.annotations[idx]
        bboxes_in = [a[:4] for a in anns]
        class_ids_in = [a[4] for a in anns]

        transformed = self.transforms(
            image=image, bboxes=bboxes_in, class_ids=class_ids_in
        )
        image_t: torch.Tensor = transformed["image"].float()
        out_bboxes = transformed["bboxes"]
        out_class_ids = transformed["class_ids"]

        _, h, w = image_t.shape
        if len(out_bboxes) == 0:
            targets = torch.zeros((0, 5), dtype=torch.float32)
        else:
            arr = np.asarray(out_bboxes, dtype=np.float32)
            x_min, y_min, x_max, y_max = arr[:, 0], arr[:, 1], arr[:, 2], arr[:, 3]
            x_c = ((x_min + x_max) * 0.5) / w
            y_c = ((y_min + y_max) * 0.5) / h
            bw = (x_max - x_min) / w
            bh = (y_max - y_min) / h
            yolo = np.stack([x_c, y_c, bw, bh], axis=1).clip(0.0, 1.0)
            classes = np.asarray(out_class_ids, dtype=np.float32).reshape(-1, 1)
            targets = torch.from_numpy(np.concatenate([classes, yolo], axis=1))

        return image_t, targets


def yolo_collate_fn(
    batch: list[tuple[torch.Tensor, torch.Tensor]],
) -> tuple[torch.Tensor, torch.Tensor]:
    """Collate function that prepends a batch index to each target row.

    Returns:
        images  : tensor of shape ``(B, 3, H, W)``
        targets : tensor of shape ``(M, 6)`` where each row is
                  ``[batch_idx, class_id, x_center, y_center, width, height]``.
    """
    images, targets = zip(*batch)
    images_t = torch.stack(images, dim=0)

    indexed: list[torch.Tensor] = []
    for i, t in enumerate(targets):
        if t.numel() == 0:
            continue
        idx_col = torch.full((t.shape[0], 1), float(i), dtype=t.dtype)
        indexed.append(torch.cat([idx_col, t], dim=1))

    targets_t = (
        torch.cat(indexed, dim=0)
        if indexed
        else torch.zeros((0, 6), dtype=torch.float32)
    )
    return images_t, targets_t


# ---------------------------------------------------------------------------
# CLI: subcommands for the COCO->CSV converter and the iNat21 pipeline.
# ---------------------------------------------------------------------------

def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Project Kanto data fetcher.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    coco = sub.add_parser(
        "coco-to-csv",
        help="Parse a COCO JSON annotation file into a flat detection CSV.",
    )
    coco.add_argument("--coco-json", required=True, help="Path to COCO annotations JSON.")
    coco.add_argument("--images-root", required=True, help="Root directory of image files.")
    coco.add_argument("--output-csv", required=True, help="Destination CSV path.")
    coco.add_argument(
        "--keep-crowd",
        action="store_true",
        help="Keep annotations with iscrowd=1 (skipped by default).",
    )
    coco.add_argument(
        "--min-box-size",
        type=float,
        default=1.0,
        help="Drop bounding boxes smaller than this many pixels on either side.",
    )

    inat = sub.add_parser(
        "inat21-mini",
        help="Download + extract iNaturalist 2021 Mini and build taxonomy_map.csv.",
    )
    inat.add_argument(
        "--raw-dir",
        default=str(DEFAULT_RAW_DIR),
        help="Directory to download/extract archives into (default: %(default)s).",
    )
    inat.add_argument(
        "--processed-dir",
        default=str(DEFAULT_PROCESSED_DIR),
        help="Directory for the output CSV (default: %(default)s).",
    )
    inat.add_argument(
        "--skip-download",
        action="store_true",
        help="Reuse archives already on disk; do not contact S3.",
    )
    inat.add_argument(
        "--skip-extract",
        action="store_true",
        help="Reuse already-extracted files; do not unpack the archives.",
    )
    inat.add_argument(
        "--output-csv-name",
        default="taxonomy_map.csv",
        help="Filename for the taxonomy CSV (default: %(default)s).",
    )
    return p


def main(argv: Optional[list[str]] = None) -> None:
    args = _build_arg_parser().parse_args(argv)

    if args.command == "coco-to-csv":
        df = coco_to_csv(
            coco_json_path=args.coco_json,
            images_root=args.images_root,
            output_csv_path=args.output_csv,
            skip_crowd=not args.keep_crowd,
            min_box_size=args.min_box_size,
        )
        print(
            f"Wrote {len(df)} annotation rows across "
            f"{df['image_path'].nunique()} images to {args.output_csv}"
        )
    elif args.command == "inat21-mini":
        fetch_inat21_mini(
            raw_dir=args.raw_dir,
            processed_dir=args.processed_dir,
            skip_download=args.skip_download,
            skip_extract=args.skip_extract,
            output_csv_name=args.output_csv_name,
        )


if __name__ == "__main__":
    main()
