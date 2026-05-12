# Project Kanto — Flutter app

The Flutter front-end for Project Kanto: a real-time, on-device species
classifier. Camera → 224×224 crop → on-device YOLOv8n-cls TFLite inference
→ temporally-smoothed top-3 HUD.

For the full architecture write-up, training pipeline, configuration knobs,
and reproduction steps, see the [repo-root README](../README.md).

## Quick run

```
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # generates species.g.dart
flutter run -d <device_id>
```
