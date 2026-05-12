# Project Kanto

An offline mobile species classifier. Point your phone's camera at a plant, bird, fungus, fish, or insect and the app names what it sees — no internet, no API calls, no telemetry. Everything runs on-device.

The Flutter app ships a YOLOv8n-cls model fine-tuned on iNaturalist 2021 Mini (10 000 species, 38 % top-1 / 68 % top-5 on the val split). The viewfinder displays the top-3 ranked predictions in real time with averaged confidences, so the practical hit rate tracks the top-5 number rather than top-1. End-to-end per-frame budget is ~150–200 ms on a mid-range Android device.

```
[ camera ] → decode → rotate 90° CW → centre-crop (0.65 of inscribed square)
          → 224×224 classifier → softmax-average buffer of 12 frames
          → top-3 ranked HUD
```

## Status

Working on Android (Samsung mid-tier, ResolutionPreset.high). Detector path exists but is gated off by a feature flag — the COCO-trained detector mis-targeted any non-bird subject (fish, flowers, fungi, insects, ≈ 87 % of iNat21's class mix), and a plain centre crop matches the training distribution better anyway. iOS not yet tested. No tests, no linter beyond `flutter analyze`, no CI.

## Quick-look features

- **Live viewfinder with top-3 species ID** — common name, scientific name, family, confidence bar, plus two ranked runner-ups
- **Offline** — model + 10 000-entry taxonomy bundled into the APK
- **Embedded database** — Isar NoSQL, seeded on first launch from the bundled JSON
- **Animated targeting reticle** — turns green on lock-on
- **Debug overlay** — corner panel showing the 224×224 the classifier is being fed, the bbox, detector confidence, and source dims (toggleable via a const)

## Repo layout

```
app/                                  Flutter front-end
  assets/
    data/taxonomy.json                10 000-entry species atlas
    model/best_float.tflite           classifier (float32, 57 MB)
    model/best_int8.tflite            classifier (INT8, 14.5 MB, fallback)
    model/detector.tflite             YOLOv8n detector (12.9 MB, currently unused)
  lib/
    main.dart                         app entry; dark M3 theme + edge-to-edge chrome
    core/
      models/species.dart             Isar @collection schema
      services/
        scanner_service.dart          live ML pipeline (isolate + worker)
        isar_service.dart             DB open + first-launch seed
        ml_service.dart               static-image classifier (kept for sanity-checking)
    ui/scanner_screen.dart            viewfinder UI, top-3 HUD, debug overlay

ml_pipeline/                          Python training/export pipeline
  src/
    data_fetcher.py                   phase 1 — fetch iNat21-Mini, build taxonomy CSV
    data_prep.py                      phase 2a — reshape into YOLO classification tree
    train.py                          phase 2b — fine-tune yolov8n-cls.pt
    export.py                         phase 3 — INT8/float TFLite, copy to app/assets
    sanity_check.py                   single-image bundled-TFLite check
    diagnostics/                      PIL/Ultralytics ground-truth comparison scripts
    convert_to_json.py                CSV → taxonomy.json
  configs/hyp.yaml                    augmentation profile (HSV, rotation, translation)
  runs/                               training output; only best/last weights are tracked

CLAUDE.md                             canonical guide to the ML pipeline phases
```

## Running the app

The bundled artifacts (`app/assets/model/*.tflite`, `app/assets/data/taxonomy.json`) are tracked, so you don't have to retrain to launch the app.

```
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # generates species.g.dart
flutter run -d <device_id>
```

First launch seeds the Isar database from `assets/data/taxonomy.json` (~3 s on Android). Subsequent launches are instant. Camera permission is requested by the `camera` plugin on first use.

The detector asset isn't loaded on launch unless `_kUseDetector` is flipped on (see [Configuration](#configuration)).

## How the pipeline works

The live path is a single Dart isolate spawned by `ScannerService` that holds the TFLite interpreter and runs every camera frame end-to-end. The UI thread is only ever passed compact result messages (top-K + small debug payload) so the viewfinder stays at 60 fps regardless of model latency.

Per frame:

1. **`_handleFrame` (UI isolate)** — `CameraImage` planes are wrapped as `TransferableTypedData` and shipped to the worker. Ownership moves, no big-buffer copy. A `_isProcessing` flag drops any frame delivered while the previous one is still in flight, giving "as fast as the model can run" cadence with zero queueing.
2. **YUV420 / BGRA8888 decode** — BT.601 full-range → RGB float32 [0,1], single pass into a working buffer at the camera's native resolution (≈720×480 on `ResolutionPreset.high`).
3. **90° CW rotation** — Android back cameras are mounted 90° CW from device portrait, so the raw frame is sideways. We rotate into the working `rgb` buffer; from there everything operates in display orientation.
4. **Centre-square crop** — `side = min(srcW, srcH) * 0.65`, centred. The 0.65 scale roughly matches the reticle's screen footprint so the classifier sees what the user thinks they're aiming at.
5. **Bilinear resize to 224×224 (NHWC float32)** — into the classifier input tensor.
6. **`classifier.invoke()`** — yolov8n-cls fine-tuned on iNat21-Mini. Output is a post-softmax probability vector of length 10 000 (Ultralytics' classify head softmaxes during export).
7. **Result handoff** — `Float32List` of class probabilities (≈40 KB) shipped back as `TransferableTypedData`. Zero copy.
8. **Temporal smoothing (main isolate)** — rolling 12-frame buffer. Each frame contributes its full softmax vector, weighted by detector confidence (1.0 in the centre-crop path). We compute a weighted average across the buffer, then partial-sort to extract the top-3. Lock-on requires (a) averaged top-1 ≥ 0.08, (b) at least 3 of the 12 frames had detector conf ≥ 0.10. Otherwise we emit "scanning" and the HUD shows the radar banner.
9. **Top-3 HUD** — the AnimatedSwitcher is keyed by `topk-${id1}-${id2}-${id3}`, so probability fluctuations re-render in place but a change to the *set* of ranked candidates animates the card swap. Each row independently watches a `FutureProvider.autoDispose.family<Species, int>` against Isar, so species names appear as Isar resolves them.

### Detector path (gated off)

When `_kUseDetector = true`, an additional stage runs *before* the classifier: letterbox-resize to 640×640 → YOLOv8 detector → parse `[1, 84, A]` output → take the highest-confidence anchor's bbox → unmap to source coords → expand by 15 % margin → square + clamp → crop. The detector is throttled to every 2nd processed frame with the box cached on the in-between frames. A heuristic detects normalised vs pixel-space bbox conventions automatically. See `_runFrame` in `scanner_service.dart`.

## Reproducing the model

See `CLAUDE.md` for the canonical pipeline. Short version:

```bash
# inside the tf-env conda env (WSL on Windows), repo root as cwd
python ml_pipeline/src/data_fetcher.py inat21-mini --validate-paths --drop-missing
python ml_pipeline/src/data_prep.py --link-mode hardlink     # Windows-safe
python ml_pipeline/src/train.py                              # auto-detects CUDA → MPS → CPU
python ml_pipeline/src/export.py                             # writes both INT8 and float TFLite
```

The reference run at `ml_pipeline/runs/yolov8n-cls-inat21-mini-a100/` is 50 epochs, batch 384, imgsz 224 on an A100. `export.py` writes `best_int8.tflite` and `best_float.tflite` straight into `app/assets/model/`.

`requirements.txt` pins `torch==2.4.1 + torchvision==0.19.1`, but plain `pip install -r requirements.txt` will silently grab the CPU-only torchvision wheel. Reinstall from the CUDA wheel index after the regular install — `train.py` detects the resulting `torchvision::nms` error and prints recovery instructions.

## Configuration

All the tunable knobs live as `const` at the top of `app/lib/core/services/scanner_service.dart`:

| Constant | Default | What it does |
|---|---|---|
| `_kUseDetector` | `false` | Master switch for the two-stage Crop-and-Classify path. False = centre crop only. |
| `_kCenterCropScale` | `0.65` | How tight the centre crop is relative to the inscribed square. 1.0 = full square (wider than viewfinder), 0.4 ≈ reticle-tight. |
| `_kSmoothingBufferSize` | `12` | Rolling buffer of per-frame probability vectors. |
| `_kLockThreshold` | `0.08` | Averaged top-1 prob needed for a lock-on emission. |
| `_kMinLockFrames` | `3` | How many qualifying frames the buffer needs before locking. |
| `_kMinDetectorConf` | `0.10` | Per-frame detector confidence floor for the smoother (detector path only). |
| `_kDetectorSkipFloor` | `0.10` | Below this the worker returns "skipped" without invoking the classifier (detector path only). |
| `_kDetectorEvery` | `2` | Detector throttle (every Nth frame; cache reused otherwise). |
| `_kCropMargin` | `0.15` | Margin around detector boxes before squaring, to recover clipped wings/tails. |
| `_kDebugOverlay` | `true` | Ship per-frame RGBA inset + bbox + det-conf to the UI overlay. |

UI threshold (`_kConfidenceThreshold` in `scanner_screen.dart`) is `0.0` — the smoother does the real gating; anything above 0 is "locked".

## Key implementation decisions (and one war story)

**The two-stage pipeline got rolled back to one stage.** The original architecture was Crop-and-Classify: a YOLOv8-COCO detector finds the subject, the classifier identifies it. In practice the detector mis-targeted on most non-bird subjects (COCO has no fish/flower/fungus/insect classes) and added ~1.5 s of CPU latency per frame. The centre-crop fallback now matches the iNat21 training distribution (user-framed photos with the subject roughly centred) and runs ~10× faster. The detector code is still there behind `_kUseDetector` for A/B comparison.

**The catastrophic preprocessing bug.** For a long stretch the model returned "chimney swift" for *every* input, regardless of subject. After every smoother / TTA / threshold tweak failed to budge it, the debug overlay revealed the smoking gun: the 224×224 classifier input was a *solid colour* on every frame. Root cause: the YOLOv8 detector was emitting **normalised** (0–1) bbox coordinates while our parser was treating them as detector-input pixel space (0–640). Dividing a 0.001-wide box by `lb.scale ≈ 2` produced a sub-pixel crop region — every output pixel sampled the same source pixel, smeared into a single colour. The fix is a runtime heuristic (`if all coords < 2.0, multiply by detector input dims`) that handles both export conventions. Lesson: when accuracy is unexpectedly catastrophic, instrument what the model is actually receiving before tuning anything downstream.

**Temporal averaging beats vote-based smoothing.** The original smoother voted on argmax across the buffer; if the model rotated between two near-tied classes, no class hit the vote threshold and the HUD never locked. Replacing it with full-probability-vector averaging (then argmax + top-K) directly exploits the 68 % top-5 stat — the right class is almost always *near the top* of each frame's distribution; averaging concentrates it.

**Sensor rotation is non-negotiable.** Android back cameras are mounted 90° CW from device portrait. The raw camera buffer has the subject lying on its side. The classifier was trained on upright photos, so rotation correction is required for correct results. Implementation: `_rotate90CWRgb` runs as a separate pass between decode and detection.

**The centre crop must match the reticle, not the inscribed square.** The viewfinder uses cover-fit scaling, which crops the left/right edges of the camera frame to fill the screen. The maximum inscribed square of the camera frame is *wider* than what the user sees — so the classifier was getting pixels the user couldn't see. `_kCenterCropScale = 0.65` shrinks the crop to roughly match the reticle's screen footprint.

**INT8 export needs stratified subset calibration.** Ultralytics' INT8 calibration `torch.cat`s every batch into a single tensor; running it over the full 100k val split blows up RAM at imgsz=224. `export.py` picks a stratified subset of ~200 images round-robin over shuffled class IDs and feeds that as a tiny train+val tree to Ultralytics with `fraction=1.0`.

## Platform notes

- **Windows**: default working directory is `D:\Project Kanto`. `data_prep.py` defaults to symlinks, which require Administrator or Developer Mode on Windows — use `--link-mode hardlink` as the same-volume drop-in fallback.
- **WSL**: ML pipeline scripts run inside a `tf-env` conda environment with Python 3.11.
- **Flutter Android**: `isar_flutter_libs` needs AGP 8 namespace patching, handled by a reflection-based shim in `app/android/build.gradle.kts` (placed before `evaluationDependsOn(":app")` — placing it after triggers "Project already evaluated").
- **GPU delegate** for TFLite is *not* currently wired up. `tflite_flutter` 0.11 supports `GpuDelegateV2` on Android — would likely give 3–5× speed-up on convolutional models, but partial INT8 op support means it's worth a measured spike rather than a blind enable.
