# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project shape

Project Kanto is a two-part system: an offline mobile species classifier (the
**app/** Flutter front-end) backed by a YOLOv8 nano classification model
trained and quantized by the **ml_pipeline/** Python pipeline. The pipeline
fine-tunes `yolov8n-cls.pt` on iNaturalist 2021 Mini (10,000 species), exports
an INT8 (and float) TFLite model, and drops both into the Flutter asset
bundle. The Flutter app then runs the float TFLite at 224×224 over a live
camera feed and emits a top-3 ranked HUD via a temporally-smoothed softmax
buffer. See the repo-root `README.md` for the full architecture write-up.

## Pipeline phases

The `ml_pipeline/src/` scripts run end-to-end as numbered phases. Run from the
repo root so the default `ml_pipeline/...` paths resolve:

```
# Phase 1 — download iNat21-Mini, build flat taxonomy_map.csv
python ml_pipeline/src/data_fetcher.py inat21-mini --validate-paths --drop-missing

# Phase 2a — reshape CSV into Ultralytics YOLO classification tree
python ml_pipeline/src/data_prep.py
# Use --link-mode hardlink on Windows without admin/Developer Mode
python ml_pipeline/src/data_prep.py --link-mode hardlink

# Phase 2b — train (auto-detects CUDA → MPS → CPU)
python ml_pipeline/src/train.py
python ml_pipeline/src/train.py --epochs 100 --batch 128 --fraction 0.05  # smoke run
python ml_pipeline/src/train.py --resume --name yolov8n-cls-inat21-mini-a100

# Phase 3 — INT8 TFLite export, copies into app/assets/model/
python ml_pipeline/src/export.py
python ml_pipeline/src/export.py --no-int8                # float32 fallback
python ml_pipeline/src/export.py --calib-samples 1000 --calib-seed 42

# Sanity-check the bundled TFLite on a single image
python ml_pipeline/src/sanity_check.py --image test_animal.jpg
```

There are no tests, no linter, and no build system beyond `pip install -r
requirements.txt`.

## Environment gotcha (read before reinstalling torch)

`requirements.txt` pins `torch==2.4.1 + torchvision==0.19.1`, but plain
`pip install -r requirements.txt` will silently grab the **CPU-only**
torchvision wheel from PyPI. That mismatch surfaces mid-training as
`NotImplementedError: torchvision::nms` on CUDA tensors during the first
validation pass. `train.py` detects this exact error and prints recovery
instructions; the fix is to reinstall torch+torchvision from the matching CUDA
wheel index, e.g.:

```
pip install --index-url https://download.pytorch.org/whl/cu118 \
    torch==2.4.1 torchvision==0.19.1
```

The header comment of `requirements.txt` is the canonical reference.

## Data flow & on-disk layout

```
ml_pipeline/data/raw/                       # gitignored — iNat21 archives + extracted JPGs
ml_pipeline/data/processed/
    taxonomy_map.csv                        # flat: image_path,class_id,kingdom,…,scientific_name,common_name
    yolo_dataset/{train,val}/<00000…09999>/ # symlink/hardlink/copy tree built from the CSV
ml_pipeline/runs/<name>/weights/{best,last,epochN}.pt
app/assets/model/{best_int8.tflite, best_float.tflite}   # what the Flutter app loads
app/assets/data/taxonomy.json                            # 10k-entry array consumed by the app
```

Class folder names are zero-padded to 5 digits so Ultralytics' lexicographic
class enumeration matches the numeric `class_id` from the CSV. `data_prep.py`
filters out CSV rows whose JPG is missing on disk — this keeps the train/val
tree symlink-clean for partial datasets.

`stratified_train_val_split` forces single-sample classes into the train split
rather than letting `sklearn.train_test_split` raise — losing a class entirely
would make the 10,000-class head silently shrink.

## Augmentation policy

`ml_pipeline/configs/hyp.yaml` is loaded by `train.py` and unpacked verbatim
into `model.train(**hyp)`. The profile is tuned for hand-held mobile capture
variance (HSV jitter, rotation, translation, mild perspective, random
erasing). `mosaic`, `mixup`, `cutmix`, and `copy_paste` are explicitly **0.0**:
they blend pixels across species and corrupt fine-grained iNat21 class
boundaries. Don't re-enable them without weighing this trade-off. Also note
`flipud=0.0` (vertical flips invert natural silhouettes) while `fliplr=0.5`
is fine.

## INT8 export & calibration

`export.py` defaults to **stratified-subset calibration**: it picks
`--calib-samples` images (default 500) round-robin over shuffled class IDs in
`val/`, materializes a tiny `train/`+`val/` tree under
`ml_pipeline/data/processed/int8_calib_subset/`, and passes that to
Ultralytics with `fraction=1.0`. This is required because Ultralytics
`torch.cat()`s every calibration batch into a single tensor — running over the
full 100k val split blows up RAM at imgsz=224.

If you set `--calib-samples 0`, fall back to fraction-of-full-val mode and
respect the `--calib-cap` (default 1000) safety net.

The exported `.tflite` is auto-copied to
`app/assets/model/best_int8.tflite` (or `best_float.tflite` with `--no-int8`).
The float fallback exists specifically for cases where INT8 hits missing-op /
PAD errors in `tflite_flutter` on device.

## Training run layout

There's a finished A100 reference run at
`ml_pipeline/runs/yolov8n-cls-inat21-mini-a100/` (50 epochs, batch 384,
imgsz 224 — see `args.yaml`). Tracked: `best.pt` and `last.pt` (canonical
training outputs), `args.yaml`, `results.csv`, and the confusion-matrix /
training-curve PNGs — together a self-contained reproducibility artefact.
Gitignored: per-epoch checkpoints (`epochN.pt`, ~10 MB each), and the
intermediate export formats (`best.onnx` + `best_saved_model/`) since
`export.py` regenerates both from `best.pt`. `train.py --save-period 1`
is intentional: a mid-run crash loses at most one epoch of progress.

## Windows-specific notes

* Default working directory is `D:\Project Kanto`. Run scripts from here so
  the relative `ml_pipeline/...` defaults work.
* `os.symlink` requires Administrator or Developer Mode on Windows. Use
  `data_prep.py --link-mode hardlink` as the same-volume drop-in fallback.
  `--link-mode copy` is the last resort.
