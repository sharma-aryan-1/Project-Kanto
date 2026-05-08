#!/usr/bin/env python3
"""Convert taxonomy_map.csv (from data_fetcher) into app/assets/data/taxonomy.json.

The CSV has one row per training image; species metadata repeats per class_id.
This script deduplicates on class_id (first occurrence wins) and emits one JSON
object per species for Isar seeding.

Expected CSV columns (see data_fetcher.TAXONOMY_CSV_COLUMNS):
  image_path, class_id, kingdom, phylum, class, order, family, genus,
  scientific_name, common_name

Usage (from repo root):
    python ml_pipeline/src/convert_to_json.py
"""

from __future__ import annotations

import csv
import json
from pathlib import Path


TAXONOMY_LEVELS: tuple[str, ...] = (
    "kingdom",
    "phylum",
    "class",
    "order",
    "family",
    "genus",
)


def _repo_root() -> Path:
    # ml_pipeline/src -> ml_pipeline -> repo root
    return Path(__file__).resolve().parent.parent.parent


def _lore_description(row: dict[str, str]) -> str:
    parts = [
        (row.get(level) or "").strip()
        for level in TAXONOMY_LEVELS
        if (row.get(level) or "").strip()
    ]
    return " · ".join(parts) if parts else ""


def _row_to_species_obj(row: dict[str, str]) -> dict:
    return {
        "classId": int(row["class_id"]),
        "commonName": (row.get("common_name") or "").strip(),
        "scientificName": (row.get("scientific_name") or "").strip(),
        "loreDescription": _lore_description(row),
        "isCaught": False,
    }


def convert_csv_to_taxonomy_json(csv_path: Path) -> list[dict]:
    if not csv_path.is_file():
        raise FileNotFoundError(
            f"Missing taxonomy CSV at {csv_path}. "
            "Run data_fetcher to build ml_pipeline/data/processed/taxonomy_map.csv "
            "first."
        )

    by_class: dict[int, dict[str, str]] = {}
    with csv_path.open(encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        missing = {"class_id"} - set(reader.fieldnames or [])
        if missing:
            raise ValueError(
                f"CSV missing required column(s): {missing}. "
                f"Found columns: {reader.fieldnames!r}"
            )
        for raw in reader:
            row = {k: (raw.get(k) if raw.get(k) is not None else "") for k in raw}
            cid = int(row["class_id"])
            if cid not in by_class:
                by_class[cid] = row

    return [_row_to_species_obj(by_class[cid]) for cid in sorted(by_class)]


def main() -> None:
    root = _repo_root()
    csv_path = root / "ml_pipeline/data/processed/taxonomy_map.csv"
    out_path = root / "app/assets/data/taxonomy.json"

    objects = convert_csv_to_taxonomy_json(csv_path)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(objects, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")

    print(
        f"[convert_to_json] wrote {len(objects):,} unique species to "
        f"{out_path.relative_to(root)}"
    )


if __name__ == "__main__":
    main()
