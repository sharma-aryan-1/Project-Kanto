"""Compare manual pixel-center bilinear (mirroring main.dart) vs PIL.BILINEAR
on the same JPEG, then run both through best_float.tflite."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import tensorflow as tf
from PIL import Image

REPO_ROOT = Path(__file__).resolve().parents[3]
MODEL = REPO_ROOT / "app/assets/model/best_float.tflite"
IMAGE = REPO_ROOT / "app/assets/images/test_animal.jpg"
SIZE = 224


def manual_bilinear(arr: np.ndarray, dst: int) -> np.ndarray:
    """Pixel-center bilinear matching the Dart implementation in main.dart."""
    h, w, _ = arr.shape
    sxs = (np.arange(dst) + 0.5) * (w / dst) - 0.5
    sys_ = (np.arange(dst) + 0.5) * (h / dst) - 0.5

    ix0 = np.floor(sxs).astype(int)
    iy0 = np.floor(sys_).astype(int)
    fx = sxs - ix0
    fy = sys_ - iy0

    ixA = np.clip(ix0, 0, w - 1)
    ixB = np.clip(ix0 + 1, 0, w - 1)
    iyA = np.clip(iy0, 0, h - 1)
    iyB = np.clip(iy0 + 1, 0, h - 1)

    out = np.zeros((dst, dst, 3), dtype=np.float64)
    for y in range(dst):
        for x in range(dst):
            p00 = arr[iyA[y], ixA[x]]
            p10 = arr[iyA[y], ixB[x]]
            p01 = arr[iyB[y], ixA[x]]
            p11 = arr[iyB[y], ixB[x]]
            w00 = (1 - fx[x]) * (1 - fy[y])
            w10 = fx[x] * (1 - fy[y])
            w01 = (1 - fx[x]) * fy[y]
            w11 = fx[x] * fy[y]
            out[y, x] = p00 * w00 + p10 * w10 + p01 * w01 + p11 * w11
    return out


def antialiased_bilinear(arr: np.ndarray, dst: int) -> np.ndarray:
    """PIL-style antialiased bilinear: triangle kernel widened to filterscale."""
    h, w, _ = arr.shape

    def kernels(src_size: int, dst_size: int):
        scale = src_size / dst_size
        filterscale = max(1.0, scale)
        out = []
        for i in range(dst_size):
            center = (i + 0.5) * scale
            xmin = max(0, int(np.floor(center - filterscale + 0.5)))
            xmax = min(src_size, int(np.floor(center + filterscale + 0.5)))
            ws = []
            for k in range(xmin, xmax):
                dist = abs(k + 0.5 - center)
                ws.append(max(0.0, 1.0 - dist / filterscale))
            s = sum(ws) or 1.0
            ws = np.array([w / s for w in ws], dtype=np.float64)
            out.append((xmin, ws))
        return out

    xk = kernels(w, dst)
    yk = kernels(h, dst)

    inter = np.zeros((h, dst, 3), dtype=np.float64)
    for y in range(h):
        for dx in range(dst):
            xmin, ws = xk[dx]
            inter[y, dx] = arr[y, xmin:xmin + len(ws), :].T @ ws

    out = np.zeros((dst, dst, 3), dtype=np.float64)
    for dy in range(dst):
        ymin, ws = yk[dy]
        out[dy] = np.einsum("i,ijk->jk", ws, inter[ymin:ymin + len(ws), :, :])
    return out


def topk(logits: np.ndarray, k: int = 5) -> list[tuple[int, float]]:
    idx = np.argsort(-logits)[:k]
    return [(int(i), float(logits[i])) for i in idx]


def main() -> int:
    pil = Image.open(IMAGE).convert("RGB")
    arr = np.asarray(pil, dtype=np.float64)
    print(f"source: {pil.size}, decoded shape: {arr.shape}")

    pil_resized = np.asarray(pil.resize((SIZE, SIZE), Image.BILINEAR), dtype=np.float64)
    manual = manual_bilinear(arr, SIZE)
    aa = antialiased_bilinear(arr, SIZE)

    d_manual = np.abs(manual - pil_resized)
    d_aa = np.abs(aa - pil_resized)
    print(f"manual    vs PIL:  max={d_manual.max():.4f}  mean={d_manual.mean():.4f}")
    print(f"aa-manual vs PIL:  max={d_aa.max():.4f}  mean={d_aa.mean():.4f}")

    interp = tf.lite.Interpreter(model_path=str(MODEL))
    interp.allocate_tensors()
    in_idx = interp.get_input_details()[0]["index"]
    out_idx = interp.get_output_details()[0]["index"]

    for label, resized in [
        ("PIL.BILINEAR", pil_resized),
        ("manual", manual),
        ("aa-manual", aa),
    ]:
        x = (resized.astype(np.float32) / 255.0)[np.newaxis, ...]
        interp.set_tensor(in_idx, x)
        interp.invoke()
        logits = interp.get_tensor(out_idx)[0]
        top = topk(logits, 5)
        print(f"\n[{label}] top-5:")
        for rank, (cid, conf) in enumerate(top, 1):
            print(f"  {rank}. class_id={cid:5d}  conf={conf * 100:7.4f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
