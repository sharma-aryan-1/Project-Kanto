"""Build app/assets/data/taxonomy.json from taxonomy_map.csv.

The CSV has one row per training image (same class repeats thousands of times).
For the on-device species lookup we only need one record per class_id, with
the fields the Flutter Species model consumes:
    classId, commonName, scientificName, kingdom, family
"""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CSV_PATH = REPO_ROOT / "ml_pipeline/data/processed/taxonomy_map.csv"
JSON_PATH = REPO_ROOT / "app/assets/data/taxonomy.json"


def main() -> int:
    if not CSV_PATH.is_file():
        print(f"missing CSV: {CSV_PATH}", file=sys.stderr)
        return 1

    seen: dict[int, dict[str, object]] = {}
    with CSV_PATH.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                cid = int(row["class_id"])
            except (KeyError, ValueError):
                continue
            if cid in seen:
                continue
            seen[cid] = {
                "classId": cid,
                "commonName": (row.get("common_name") or "").strip(),
                "scientificName": (row.get("scientific_name") or "").strip(),
                "kingdom": (row.get("kingdom") or "").strip(),
                "family": (row.get("family") or "").strip(),
            }

    records = [seen[cid] for cid in sorted(seen)]
    JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    with JSON_PATH.open("w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False, separators=(",", ":"))

    print(f"wrote {len(records):,} species -> {JSON_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
