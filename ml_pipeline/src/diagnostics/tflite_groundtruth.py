"""Ground-truth what best_float.tflite predicts for test_animal.jpg.

Pure TFLite Python interpreter (no Ultralytics): mirrors the Flutter
preprocessing exactly so we can decide whether the Flutter output is
correct or whether there is still a preprocessing mismatch.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import tensorflow as tf
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[3]
MODEL = REPO_ROOT / "app/assets/model/best_float.tflite"
IMAGE = REPO_ROOT / "app/assets/images/test_animal.jpg"


def main() -> int:
    if not MODEL.is_file():
        print(f"missing model: {MODEL}", file=sys.stderr)
        return 1
    if not IMAGE.is_file():
        print(f"missing image: {IMAGE}", file=sys.stderr)
        return 1

    img = Image.open(IMAGE).convert("RGB").resize((224, 224), Image.BILINEAR)
    arr = np.asarray(img, dtype=np.float32) / 255.0
    arr = arr[np.newaxis, ...]

    interp = tf.lite.Interpreter(model_path=str(MODEL))
    interp.allocate_tensors()
    in_det = interp.get_input_details()[0]
    out_det = interp.get_output_details()[0]
    print(f"input  shape: {in_det['shape']}  dtype: {in_det['dtype']}")
    print(f"output shape: {out_det['shape']}  dtype: {out_det['dtype']}")

    interp.set_tensor(in_det["index"], arr)
    interp.invoke()
    logits = interp.get_tensor(out_det["index"])[0]
    print(f"logits sum: {logits.sum():.6f}  min: {logits.min():.6f}  "
          f"max: {logits.max():.6f}")

    top5 = np.argsort(-logits)[:5]
    print("top-5:")
    for rank, idx in enumerate(top5, 1):
        print(f"  {rank}. class_id={int(idx):5d}  conf={logits[idx] * 100:7.4f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
