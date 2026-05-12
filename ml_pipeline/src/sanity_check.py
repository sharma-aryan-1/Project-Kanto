"""
sanity_check.py — Quick INT8 TFLite classification sanity check.

Loads the Flutter-bundle classifier via Ultralytics, runs one warmup predict,
then a timed predict on a test image and prints top-5 logits as class IDs,
confidences, and species labels when available.

Run from repo root:
    python ml_pipeline/src/sanity_check.py
    python ml_pipeline/src/sanity_check.py --image path/to.jpg
"""

from __future__ import annotations

import argparse
import csv
import sys
import time
from pathlib import Path

from ultralytics import YOLO


REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_MODEL = REPO_ROOT / "app/assets/model/best_float.tflite"
DEFAULT_IMAGE = REPO_ROOT / "app/assets/images/test_animal.jpg"
DEFAULT_TAXONOMY_CSV = REPO_ROOT / "ml_pipeline/data/processed/taxonomy_map.csv"


def _as_float(x: object) -> float:
    if hasattr(x, "item"):
        return float(x.item())
    return float(x)


def _as_int(x: object) -> int:
    if hasattr(x, "item"):
        return int(x.item())
    return int(x)


def load_class_id_to_species(csv_path: Path) -> dict[int, str]:
    """First row per class_id wins; prefers common_name with scientific_name fallback."""
    out: dict[int, str] = {}
    if not csv_path.is_file():
        return out
    with csv_path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames or "class_id" not in reader.fieldnames:
            return out
        for row in reader:
            try:
                cid = int(row["class_id"])
            except (KeyError, ValueError):
                continue
            if cid in out:
                continue
            common = (row.get("common_name") or "").strip()
            sci = (row.get("scientific_name") or "").strip()
            if common and sci:
                out[cid] = f"{common} ({sci})"
            elif common:
                out[cid] = common
            elif sci:
                out[cid] = sci
            else:
                out[cid] = f"class_id {cid}"
    return out


def _normalize_names(names_obj: object) -> dict | None:
    if isinstance(names_obj, dict):
        return names_obj
    if names_obj is None:
        return None
    items = getattr(names_obj, "items", None)
    if callable(items):
        try:
            return dict(items())
        except Exception:
            return None
    return None


def species_for_index(
    idx: int,
    names: dict | None,
    taxonomy: dict[int, str],
) -> str:
    if names:
        label = names.get(idx) or names.get(str(idx))
        if label:
            return str(label)
    return taxonomy.get(idx, "—")


def main() -> int:
    parser = argparse.ArgumentParser(description="Sanity-check quantized YOLOv8-cls TFLite model.")
    parser.add_argument(
        "--model",
        type=Path,
        default=DEFAULT_MODEL,
        help=f"path to best_int8.tflite (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--image",
        type=Path,
        default=DEFAULT_IMAGE,
        help=f"test image (default: {DEFAULT_IMAGE})",
    )
    parser.add_argument(
        "--taxonomy-csv",
        type=Path,
        default=DEFAULT_TAXONOMY_CSV,
        help="taxonomy_map.csv for species names (optional if model embeds names)",
    )
    args = parser.parse_args()

    model_path = args.model.expanduser().resolve()
    image_path = args.image.expanduser().resolve()
    taxonomy_path = args.taxonomy_csv.expanduser().resolve()

    if not model_path.is_file():
        print(f"error: model not found: {model_path}", file=sys.stderr)
        return 1
    if not image_path.is_file():
        print(f"error: image not found: {image_path}", file=sys.stderr)
        return 1

    taxonomy = load_class_id_to_species(taxonomy_path)

    print(f"model:   {model_path}")
    print(f"image:   {image_path}")
    if taxonomy_path.is_file():
        print(f"taxonomy: {taxonomy_path} ({len(taxonomy)} classes mapped)")
    else:
        print(f"taxonomy: {taxonomy_path} (missing — species column may show placeholders)")
    print()

    # TFLite weights do not carry task metadata; classify avoids detect fallback.
    model = YOLO(str(model_path), task="classify")

    model.predict(str(image_path), verbose=False)
    t0 = time.perf_counter()
    results = model.predict(str(image_path), verbose=False)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0

    r = results[0]
    if r.probs is None:
        print("error: no classification probabilities in result", file=sys.stderr)
        return 1

    names = _normalize_names(getattr(r, "names", None))

    probs = r.probs
    top5_idx = probs.top5
    top5_conf = probs.top5conf

    print(
        f"names:   embedded ({len(names)} labels)"
        if names
        else "names:   — (using taxonomy CSV / placeholder)"
    )
    print()
    print("Rank  Class ID    Confidence    Species")
    print("----  ----------  ------------  ------")

    for rank, (idx_raw, conf_raw) in enumerate(zip(top5_idx, top5_conf), start=1):
        idx = _as_int(idx_raw)
        conf_pct = _as_float(conf_raw) * 100.0
        species = species_for_index(idx, names, taxonomy)
        print(f"{rank:4d}  {idx:10d}  {conf_pct:10.2f}%  {species}")

    print()
    print(f"Inference time: {elapsed_ms:.2f} ms (single predict after warmup)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
