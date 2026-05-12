// Live camera → background-isolate two-stage inference pipeline.
//
// Architecture (Crop-and-Classify):
//
//   [Camera plugin]          (UI isolate)
//        │ CameraImage
//        ▼
//   ScannerService._handleFrame
//        │ extracts plane bytes as TransferableTypedData
//        │ (transfers ownership; no big-buffer copy across isolates)
//        ▼
//   _isolateEntry (worker isolate)
//        │ 1. YUV420/BGRA8888 → full-res RGB float[0,1] buffer
//        │ 2. Letterbox-resize → detector input (e.g. 640×640)
//        │    Detector (YOLOv8) invoke → parse [1, 84, A] → best-conf box
//        │ 3. Unmap box to source coords; expand to square (shift to fit)
//        │ 4. Crop-and-resize square → classifier input (224×224)
//        │    Classifier (yolov8n-cls) invoke → argmax over 10 000 logits
//        ▼
//   ScannerService._onIsolateResult  (UI isolate)
//        │ pushes (classId, confidence) into temporal smoothing buffer
//        │ emits locked target or scanning state
//        ▼
//   scannerStatusProvider (Riverpod StreamProvider)
//
// Throttling: a single _isProcessing flag means while a frame is in flight,
// every CameraImage delivered by the plugin is dropped. As soon as the
// isolate returns a result we accept the next frame. This gives "as fast as
// the pipeline can run" frame rate with zero queueing.
//
// Why two stages: a single 224×224 classifier on the raw frame is dominated
// by whatever happens to fill the frame — typically background. Routing
// through the detector first lets us discard background pixels before
// classification, dramatically improving per-frame confidence on small or
// off-centre subjects.

import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

const String _kDetectorAsset = 'assets/model/detector.tflite';
const String _kClassifierAsset = 'assets/model/best_float.tflite';
const int _kInputSize = 224;
const int _kNumClasses = 10000;
// YOLOv8's canonical letterbox fill colour (114/255 normalised to [0,1]).
const double _kGrayPad = 114.0 / 255.0;

// ─── Temporal smoothing (probability-vector averaging) ────────────────────
// The classifier reports 38 %/68 % top-1/top-5 accuracy — the right answer
// is consistently in the top-K, just unstably ranked at #1. So instead of
// voting on argmax we keep the full softmax probability vector per frame
// and average across the buffer, weighted by the detector's confidence
// that there's actually a subject in that frame. We lock onto the averaged
// top-1 once it clears a probability floor AND enough frames have a real
// detection. Frames whose detector confidence falls below the skip floor
// are pushed into the buffer with zero weight (they don't contribute to
// the average) so the buffer cadence stays steady.
const int _kSmoothingBufferSize = 12;
// Thresholds tuned for the *post-fix* pipeline (correct rotation, expanded
// crop, valid pixel inputs). Earlier values had been panicked down to
// near-zero because the classifier was being fed solid-colour swatches —
// no longer needed now that real bird pixels are reaching the model.
const double _kLockThreshold = 0.08;
const double _kMinDetectorConf = 0.10;
const int _kMinLockFrames = 3;
const double _kDetectorSkipFloor = 0.10;
const int _kTopK = 3;

// Crop margin: detector boxes are tight around the subject and frequently
// clip wings/tails/feathers/etc. that the classifier was trained to use.
// We expand the box by this fraction on each side before squaring.
const double _kCropMargin = 0.15;

// Centre-crop scale (used when _kUseDetector is false). The maximum
// inscribed square of the camera frame is wider than what the user actually
// sees through the cover-fit viewfinder — the viewfinder crops the left and
// right edges of the camera frame. Multiplying by this scale shrinks the
// crop to roughly match the reticle so the classifier sees what the user
// thinks they're targeting. 1.0 = full inscribed square (more context, more
// out-of-view pixels). 0.4 ≈ tight reticle match.
const double _kCenterCropScale = 0.65;

// Detector throttling. The 640×640 YOLOv8 detector dominates per-frame cost
// on CPU (~1.3–2.0 s). We re-run it every _kDetectorEvery processed frames
// and reuse the cached square crop on the others — the cost of a stale box
// for a fraction of a second is much smaller than the cost of waiting 2 s
// between predictions. Set to 1 to disable throttling.
const int _kDetectorEvery = 2;

// Master switch for the detector pipeline. False (default) skips detector
// loading and inference entirely; we take a square centre crop of the frame
// and feed that straight to the classifier. Rationale: iNat21-Mini is ~38 %
// insects + 25 % plants + 12 % fungi — none of which the COCO-trained
// YOLOv8 detector has classes for, so its "best anchor" lands on irrelevant
// regions for the majority of subjects. The classifier was trained on
// user-framed iNat photos that are already roughly centred, so a centre
// crop matches training-time conditions better than a wildly-placed COCO
// crop. Flip true to A/B against the detector path.
const bool _kUseDetector = false;

// Per-frame debug data shipped to the UI so we can visualise what the
// classifier is actually being fed. Costs ~200 KB / frame on the SendPort
// plus a small RGBA conversion in the worker. Flip off when not debugging.
const bool _kDebugOverlay = true;

class _FrameDist {
  final Float32List? probs; // null when frame was skipped (zero-weight entry)
  final double detectorConf;
  const _FrameDist({required this.probs, required this.detectorConf});
}

// ─── Public types ──────────────────────────────────────────────────────────

class ScannerResult {
  // Top-1: aliases topK[0] when a target is locked; (0, 0.0) when scanning.
  final int classId;
  final double confidence;
  // Up to _kTopK ranked candidates after smoothing. Empty when scanning.
  final List<({int classId, double probability})> topK;
  final double inferenceMs;
  final DateTime at;

  const ScannerResult({
    required this.classId,
    required this.confidence,
    required this.topK,
    required this.inferenceMs,
    required this.at,
  });
}

/// Per-frame diagnostic snapshot used by the debug overlay. Populated only
/// when [_kDebugOverlay] is enabled in the worker isolate.
@immutable
class DebugFrame {
  // 224×224 RGBA bytes (row-major, top-left origin) that were fed to the
  // classifier this frame. Null when the frame was skipped at the detector
  // floor (classifier didn't run).
  final Uint8List? classifierInputRgba;
  // Bbox in source pixel coords (top-left + side length, always a square).
  final double boxSx;
  final double boxSy;
  final double boxSide;
  // Detector confidence (fresh detection or cached) for this frame.
  final double detectorConf;
  // Source camera frame dimensions.
  final int srcW;
  final int srcH;
  // True when the detector did not run this frame (we reused the cached box).
  final bool wasCached;
  // True when the frame was skipped at the detector floor (no classifier).
  final bool wasSkipped;

  const DebugFrame({
    required this.classifierInputRgba,
    required this.boxSx,
    required this.boxSy,
    required this.boxSide,
    required this.detectorConf,
    required this.srcW,
    required this.srcH,
    required this.wasCached,
    required this.wasSkipped,
  });
}

@immutable
class ScannerStatus {
  final bool isReady;
  final bool isStreaming;
  final bool isProcessing;
  final ScannerResult? lastResult;
  final DebugFrame? debug;
  final String? error;

  const ScannerStatus({
    this.isReady = false,
    this.isStreaming = false,
    this.isProcessing = false,
    this.lastResult,
    this.debug,
    this.error,
  });

  ScannerStatus copyWith({
    bool? isReady,
    bool? isStreaming,
    bool? isProcessing,
    ScannerResult? lastResult,
    Object? debug = _sentinel,
    Object? error = _sentinel,
  }) {
    return ScannerStatus(
      isReady: isReady ?? this.isReady,
      isStreaming: isStreaming ?? this.isStreaming,
      isProcessing: isProcessing ?? this.isProcessing,
      lastResult: lastResult ?? this.lastResult,
      debug: identical(debug, _sentinel) ? this.debug : debug as DebugFrame?,
      error: identical(error, _sentinel) ? this.error : error as String?,
    );
  }
}

const Object _sentinel = Object();

// ─── Service ───────────────────────────────────────────────────────────────

class ScannerService {
  ScannerService._();

  CameraController? _controller;
  Isolate? _isolate;
  SendPort? _isolateSend;
  ReceivePort? _mainReceive;

  bool _isProcessing = false;

  final Queue<_FrameDist> _buffer = Queue<_FrameDist>();

  final _statusController = StreamController<ScannerStatus>.broadcast();
  ScannerStatus _status = const ScannerStatus();

  Stream<ScannerStatus> get statusStream => _statusController.stream;
  ScannerStatus get status => _status;
  CameraController? get controller => _controller;

  void _publish(ScannerStatus s) {
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  /// Spawns the worker isolate, ships model bytes to it, picks the back
  /// camera at low resolution, and waits for both halves to be ready.
  static Future<ScannerService> create() async {
    final svc = ScannerService._();
    await svc._initIsolate();
    await svc._initCamera();
    svc._publish(svc._status.copyWith(isReady: true));
    return svc;
  }

  Future<void> _initIsolate() async {
    final classifierData = await rootBundle.load(_kClassifierAsset);
    final classifierBytes = classifierData.buffer.asUint8List();

    // Only load the detector asset when we're going to use it. 12.9 MB is
    // not worth keeping resident in RAM when the path is disabled.
    Uint8List? detectorBytes;
    if (_kUseDetector) {
      final detectorData = await rootBundle.load(_kDetectorAsset);
      detectorBytes = detectorData.buffer.asUint8List();
    }

    _mainReceive = ReceivePort();
    final readyForInit = Completer<void>();
    final initialized = Completer<void>();

    _mainReceive!.listen((msg) {
      if (msg is SendPort) {
        _isolateSend = msg;
        readyForInit.complete();
        return;
      }
      if (msg is Map) {
        switch (msg['type']) {
          case 'ready':
            if (!initialized.isCompleted) initialized.complete();
            break;
          case 'result':
            _onIsolateResult(msg);
            break;
          case 'error':
            _onIsolateError(
              msg['message'] as String? ?? 'unknown isolate error',
            );
            break;
        }
      }
    });

    _isolate = await Isolate.spawn(_isolateEntry, _mainReceive!.sendPort);
    await readyForInit.future;

    final initMsg = <String, Object>{
      'type': 'init',
      'classifierBytes': TransferableTypedData.fromList([classifierBytes]),
    };
    if (detectorBytes != null) {
      initMsg['detectorBytes'] = TransferableTypedData.fromList(
        [detectorBytes],
      );
    }
    _isolateSend!.send(initMsg);
    await initialized.future;
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras available on this device.');
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    // ResolutionPreset.high is ~720×480. The classifier still only consumes
    // a 224×224 crop, but a higher source resolution (a) makes the
    // viewfinder visibly sharper and (b) gives the classifier cleaner
    // pixels after the bilinear downsample. Extra YUV-decode cost is
    // ~15–25 ms — well within the per-frame budget now that the detector
    // is gone.
    _controller = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
  }

  // ── stream control ──

  Future<void> startStream() async {
    final c = _controller;
    if (c == null) throw StateError('ScannerService not initialized.');
    if (c.value.isStreamingImages) return;
    await c.startImageStream(_handleFrame);
    _publish(_status.copyWith(isStreaming: true, error: null));
  }

  Future<void> stopStream() async {
    final c = _controller;
    if (c == null) return;
    if (!c.value.isStreamingImages) return;
    await c.stopImageStream();
    _isProcessing = false;
    // Drop stale observations so a future resume starts with a fresh buffer.
    _buffer.clear();
    _publish(_status.copyWith(isStreaming: false, isProcessing: false));
  }

  // ── frame plumbing ──

  void _handleFrame(CameraImage image) {
    // Throttle: drop everything until the in-flight frame returns.
    if (_isProcessing) return;
    final send = _isolateSend;
    if (send == null) return;

    final group = image.format.group;
    final String formatTag;
    if (group == ImageFormatGroup.yuv420) {
      formatTag = 'yuv420';
    } else if (group == ImageFormatGroup.bgra8888) {
      formatTag = 'bgra8888';
    } else {
      // We can't process this format — quietly drop the frame.
      return;
    }

    // Transfer plane buffers without copying. The TransferableTypedData
    // contract: ownership moves to the isolate when it materialize()s.
    final planeBytes = <TransferableTypedData>[];
    final planeBytesPerRow = <int>[];
    final planeBytesPerPixel = <int?>[];
    for (final p in image.planes) {
      planeBytes.add(TransferableTypedData.fromList([p.bytes]));
      planeBytesPerRow.add(p.bytesPerRow);
      planeBytesPerPixel.add(p.bytesPerPixel);
    }

    _isProcessing = true;
    _publish(_status.copyWith(isProcessing: true));

    send.send(<String, Object?>{
      'type': 'frame',
      'format': formatTag,
      'width': image.width,
      'height': image.height,
      'planes': planeBytes,
      'rowStrides': planeBytesPerRow,
      'pixelStrides': planeBytesPerPixel,
    });
  }

  void _onIsolateResult(Map msg) {
    _isProcessing = false;

    final inferenceMs = (msg['inferenceMs'] as num).toDouble();
    final detectorConf = (msg['detectorConf'] as num? ?? 0.0).toDouble();
    final skipped = msg['skipped'] as bool? ?? false;

    Float32List? probs;
    if (!skipped) {
      final ttd = msg['probs'] as TransferableTypedData;
      final length = msg['probsLength'] as int;
      final bytes = ttd.materialize().asUint8List();
      // View the byte buffer as Float32 without copying.
      probs = bytes.buffer.asFloat32List(bytes.offsetInBytes, length);
    }

    _buffer.addLast(_FrameDist(probs: probs, detectorConf: detectorConf));
    if (_buffer.length > _kSmoothingBufferSize) {
      _buffer.removeFirst();
    }

    final topK = _computeSmoothedTopK();

    // Materialise the debug payload (when present) so the UI can render the
    // diagnostic overlay. Skipped frames carry bbox + conf but no RGBA.
    DebugFrame? debug;
    final hasDebug = msg['debugSrcW'] != null;
    if (hasDebug) {
      Uint8List? rgba;
      final rgbaTtd = msg['debugInputRgba'] as TransferableTypedData?;
      if (rgbaTtd != null) {
        rgba = rgbaTtd.materialize().asUint8List();
      }
      debug = DebugFrame(
        classifierInputRgba: rgba,
        boxSx: (msg['debugBoxSx'] as num).toDouble(),
        boxSy: (msg['debugBoxSy'] as num).toDouble(),
        boxSide: (msg['debugBoxSide'] as num).toDouble(),
        detectorConf: detectorConf,
        srcW: msg['debugSrcW'] as int,
        srcH: msg['debugSrcH'] as int,
        wasCached: msg['debugWasCached'] as bool? ?? false,
        wasSkipped: skipped,
      );
    }

    _publish(
      _status.copyWith(
        isProcessing: false,
        lastResult: ScannerResult(
          // classId/confidence alias topK[0] when locked; 0/0 otherwise.
          classId: topK.isNotEmpty ? topK.first.classId : 0,
          confidence: topK.isNotEmpty ? topK.first.probability : 0.0,
          topK: topK,
          inferenceMs: inferenceMs,
          at: DateTime.now(),
        ),
        debug: debug,
        error: null,
      ),
    );
  }

  /// Weighted-average the per-frame probability vectors in the buffer
  /// (weights = detector confidence), then return the top-K classes.
  /// Returns an empty list if the lock conditions aren't met — that's the
  /// scanning state.
  List<({int classId, double probability})> _computeSmoothedTopK() {
    if (_buffer.isEmpty) return const [];

    // Tally how many entries actually carry signal (skipped frames don't).
    var validFrames = 0;
    var totalWeight = 0.0;
    int? probsLength;
    for (final f in _buffer) {
      if (f.probs == null) continue;
      if (f.detectorConf < _kMinDetectorConf) continue;
      validFrames++;
      totalWeight += f.detectorConf;
      probsLength ??= f.probs!.length;
    }
    if (validFrames < _kMinLockFrames || probsLength == null) {
      return const [];
    }

    // Weighted sum of probability vectors.
    final n = probsLength;
    final avg = Float64List(n);
    for (final f in _buffer) {
      if (f.probs == null) continue;
      if (f.detectorConf < _kMinDetectorConf) continue;
      final w = f.detectorConf;
      final p = f.probs!;
      final m = p.length < n ? p.length : n;
      for (var i = 0; i < m; i++) {
        avg[i] += p[i] * w;
      }
    }
    final inv = 1.0 / totalWeight;
    // We only need top-K, so don't materialise the normalised vector —
    // track top-K probabilities and normalise just those at the end.

    // Partial top-K scan (small K → linear scan with insertion is fine).
    final topIds = List<int>.filled(_kTopK, -1);
    final topVals = List<double>.filled(_kTopK, -1.0);
    for (var i = 0; i < n; i++) {
      final v = avg[i];
      if (v <= topVals[_kTopK - 1]) continue;
      // Insert into the small sorted array.
      var pos = _kTopK - 1;
      while (pos > 0 && v > topVals[pos - 1]) {
        topVals[pos] = topVals[pos - 1];
        topIds[pos] = topIds[pos - 1];
        pos--;
      }
      topVals[pos] = v;
      topIds[pos] = i;
    }

    final top1Prob = topVals[0] * inv;
    if (top1Prob < _kLockThreshold) return const [];

    final out = <({int classId, double probability})>[];
    for (var i = 0; i < _kTopK; i++) {
      if (topIds[i] < 0) break;
      out.add((classId: topIds[i], probability: topVals[i] * inv));
    }
    return out;
  }

  void _onIsolateError(String message) {
    _isProcessing = false;
    _publish(_status.copyWith(isProcessing: false, error: message));
  }

  // ── teardown ──

  Future<void> dispose() async {
    try {
      await stopStream();
    } catch (_) {}
    _isolateSend?.send(<String, Object>{'type': 'shutdown'});
    await _controller?.dispose();
    _controller = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _mainReceive?.close();
    _mainReceive = null;
    if (!_statusController.isClosed) await _statusController.close();
  }
}

// ─── Worker isolate ────────────────────────────────────────────────────────

class _DetectorMeta {
  final int w;
  final int h;
  final int numAnchors;
  final int numClasses;
  // YOLOv8 TFLite default is [1, 4+nc, anchors] (channel-first). Some
  // exporters transpose to [1, anchors, 4+nc] — we probe at init and index
  // accordingly.
  final bool channelFirst;
  const _DetectorMeta({
    required this.w,
    required this.h,
    required this.numAnchors,
    required this.numClasses,
    required this.channelFirst,
  });
}

class _ClassifierMeta {
  final bool isNHWC;
  const _ClassifierMeta(this.isNHWC);
}

// Per-worker mutable state: frame counter + the most recent square crop
// region (in source-image pixel coords) and the detector confidence that
// produced it. The throttling logic in _runFrame consults this to decide
// whether to invoke the detector or reuse the cached crop.
class _WorkerState {
  int processedFrames = 0;
  bool hasCachedBox = false;
  double cachedSx = 0;
  double cachedSy = 0;
  double cachedSide = 0;
  double cachedDetectorConf = 0;
}

void _isolateEntry(SendPort mainSend) async {
  final port = ReceivePort();
  mainSend.send(port.sendPort);

  Interpreter? detector;
  Interpreter? classifier;
  _DetectorMeta? detMeta;
  _ClassifierMeta? clsMeta;
  final state = _WorkerState();

  await for (final raw in port) {
    if (raw is! Map) continue;
    final type = raw['type'];
    try {
      if (type == 'init') {
        final clsTtd = raw['classifierBytes'] as TransferableTypedData;
        classifier = Interpreter.fromBuffer(clsTtd.materialize().asUint8List());

        // ── Classifier metadata.
        final clsInShape = classifier.getInputTensor(0).shape;
        var isNHWC = true;
        if (clsInShape.length == 4) {
          isNHWC = clsInShape[1] == _kInputSize && clsInShape[3] == 3;
        }
        clsMeta = _ClassifierMeta(isNHWC);

        // ── Detector is optional (master switch _kUseDetector). Only
        //    initialise + probe metadata when bytes were actually sent.
        final detTtd = raw['detectorBytes'] as TransferableTypedData?;
        if (detTtd != null) {
          detector = Interpreter.fromBuffer(detTtd.materialize().asUint8List());

          final detInShape = detector.getInputTensor(0).shape; // [1, H, W, 3]
          final detH = detInShape.length == 4 ? detInShape[1] : 640;
          final detW = detInShape.length == 4 ? detInShape[2] : 640;

          final detOutShape = detector.getOutputTensor(0).shape;
          // Strip leading 1s; we want the two payload dims.
          final payload = detOutShape.where((d) => d != 1).toList();
          if (payload.length != 2) {
            throw StateError(
              'Unexpected detector output rank: ${detOutShape.toString()}',
            );
          }
          final d0 = payload[0];
          final d1 = payload[1];
          // Channels << anchors in practice (e.g. 84 vs 8400).
          final channelFirst = d0 < d1;
          final numChannels = channelFirst ? d0 : d1;
          final numAnchors = channelFirst ? d1 : d0;
          if (numChannels < 5) {
            throw StateError(
              'Detector has < 5 channels (need 4 box + ≥1 class).',
            );
          }
          detMeta = _DetectorMeta(
            w: detW,
            h: detH,
            numAnchors: numAnchors,
            numClasses: numChannels - 4,
            channelFirst: channelFirst,
          );
        }

        mainSend.send(<String, Object>{'type': 'ready'});
      } else if (type == 'frame') {
        if (classifier == null || clsMeta == null) {
          continue;
        }
        final result = _runFrame(
          raw,
          detector: detector,
          classifier: classifier,
          detMeta: detMeta,
          clsMeta: clsMeta,
          state: state,
        );
        mainSend.send(result);
      } else if (type == 'shutdown') {
        detector?.close();
        classifier?.close();
        port.close();
        return;
      }
    } catch (e, st) {
      mainSend.send(<String, Object>{
        'type': 'error',
        'message': 'isolate: $e',
        'stack': st.toString(),
      });
    }
  }
}

Map<String, Object> _runFrame(
  Map raw, {
  required Interpreter? detector,
  required Interpreter classifier,
  required _DetectorMeta? detMeta,
  required _ClassifierMeta clsMeta,
  required _WorkerState state,
}) {
  final sw = Stopwatch()..start();
  state.processedFrames++;

  final format = raw['format'] as String;
  final camW = raw['width'] as int;
  final camH = raw['height'] as int;
  final planes = (raw['planes'] as List)
      .map((e) => (e as TransferableTypedData).materialize().asUint8List())
      .toList(growable: false);
  final rowStrides = (raw['rowStrides'] as List).cast<int>();
  final pixelStrides = (raw['pixelStrides'] as List).cast<int?>();

  // ── 1. Decode camera frame → full-resolution RGB float buffer [0,1] ──
  // The camera plugin delivers frames in *sensor* orientation. For the
  // typical Android back camera that's 90° CW from device-portrait, so the
  // raw buffer is "sideways" relative to what the user sees on screen.
  final rgbRaw = Float32List(camW * camH * 3);
  if (format == 'yuv420') {
    _decodeYuv420ToRgb(
      yPlane: planes[0],
      uPlane: planes[1],
      vPlane: planes[2],
      yRowStride: rowStrides[0],
      uRowStride: rowStrides[1],
      vRowStride: rowStrides[2],
      uPixelStride: pixelStrides[1] ?? 1,
      vPixelStride: pixelStrides[2] ?? 1,
      srcW: camW,
      srcH: camH,
      dst: rgbRaw,
    );
  } else if (format == 'bgra8888') {
    _decodeBgra8888ToRgb(
      bytes: planes[0],
      rowStride: rowStrides[0],
      srcW: camW,
      srcH: camH,
      dst: rgbRaw,
    );
  } else {
    return <String, Object>{
      'type': 'error',
      'message': 'unsupported format: $format',
    };
  }

  // ── 1b. Rotate 90° CW so subjects appear upright (matching training).
  // After this the working frame is (srcW, srcH) = (camH, camW).
  final srcW = camH;
  final srcH = camW;
  final rgb = Float32List(srcW * srcH * 3);
  _rotate90CWRgb(rgbRaw, camW, camH, rgb);

  // ── 2-3. Locate the crop region ──
  //
  // Two paths, gated by _kUseDetector:
  //   A) Detector path: run YOLOv8 (throttled), parse best anchor, unmap,
  //      expand by crop margin, square + clamp. Cached across frames.
  //   B) Center-crop path: just take the maximum inscribed square at the
  //      centre of the frame. No detector inference. detectorConf = 1.0
  //      so the skip/min/lock gates downstream all pass trivially.
  double sx, sy, side, detectorConf;
  bool wasCached = false;

  if (_kUseDetector && detector != null && detMeta != null) {
    final shouldDetect = !state.hasCachedBox ||
        (state.processedFrames % _kDetectorEvery == 0);

    if (shouldDetect) {
      final detInput = Float32List(detMeta.w * detMeta.h * 3);
      final lb = _letterboxIntoDetectorInput(
        src: rgb,
        srcW: srcW,
        srcH: srcH,
        dst: detInput,
        dstW: detMeta.w,
        dstH: detMeta.h,
      );

      detector.getInputTensor(0).setTo(detInput);
      detector.invoke();
      final detOutBytes = detector.getOutputTensor(0).data;
      final detRaw = detOutBytes.buffer.asFloat32List(
        detOutBytes.offsetInBytes,
        detOutBytes.lengthInBytes ~/ 4,
      );

      final best = _bestAnchor(detRaw, detMeta);
      detectorConf = best.conf;

      // Some YOLOv8 TFLite exports emit cxcywh in detector-input pixel
      // space (e.g. 0–640); others emit normalised values (0–1). Detect
      // heuristically: every coord well under 2 means normalised, so
      // scale up to pixel space. Without this, normalised outputs unmap
      // to a sub-pixel crop and the classifier sees a flat colour swatch.
      var bcx = best.cx;
      var bcy = best.cy;
      var bw = best.w;
      var bh = best.h;
      if (bcx < 2.0 && bcy < 2.0 && bw < 2.0 && bh < 2.0) {
        bcx *= detMeta.w;
        bcy *= detMeta.h;
        bw *= detMeta.w;
        bh *= detMeta.h;
      }

      // detector-input pixel coords → source pixel coords (undo letterbox)
      final cxSrc = (bcx - lb.padX) / lb.scale;
      final cySrc = (bcy - lb.padY) / lb.scale;
      // Expand the rect by the crop margin so the classifier sees context
      // (wings/tail) that the tight detector box would otherwise clip.
      final wSrc = (bw / lb.scale) * (1.0 + _kCropMargin);
      final hSrc = (bh / lb.scale) * (1.0 + _kCropMargin);

      // Square it (extend the short axis), then shift inward to keep
      // within the frame.
      var s = math.max(wSrc, hSrc);
      final maxSide = math.min(srcW, srcH).toDouble();
      if (s > maxSide) s = maxSide;
      side = s;

      var x = cxSrc - side / 2.0;
      var y = cySrc - side / 2.0;
      if (x < 0) x = 0;
      if (y < 0) y = 0;
      if (x + side > srcW) x = srcW - side;
      if (y + side > srcH) y = srcH - side;
      sx = x;
      sy = y;

      state.cachedSx = sx;
      state.cachedSy = sy;
      state.cachedSide = side;
      state.cachedDetectorConf = detectorConf;
      state.hasCachedBox = true;
      wasCached = false;
    } else {
      sx = state.cachedSx;
      sy = state.cachedSy;
      side = state.cachedSide;
      detectorConf = state.cachedDetectorConf;
      wasCached = true;
    }
  } else {
    // Center-square crop, sized to roughly match the reticle so it lines
    // up with what the user sees in the (cover-fit) viewfinder.
    final maxSide = math.min(srcW, srcH).toDouble();
    side = maxSide * _kCenterCropScale;
    sx = (srcW - side) / 2.0;
    sy = (srcH - side) / 2.0;
    detectorConf = 1.0;
  }

  // Low-conf-frame skip: if the (fresh or cached) detection confidence is
  // below the floor, don't burn classifier cycles on a random patch. We
  // still ship a result so the smoother's cadence keeps advancing — but
  // with skipped:true so the main isolate pushes a zero-weight entry.
  if (detectorConf < _kDetectorSkipFloor) {
    sw.stop();
    final r = <String, Object>{
      'type': 'result',
      'skipped': true,
      'detectorConf': detectorConf,
      'inferenceMs': sw.elapsedMicroseconds / 1000.0,
    };
    if (_kDebugOverlay) {
      r['debugSrcW'] = srcW;
      r['debugSrcH'] = srcH;
      r['debugBoxSx'] = sx;
      r['debugBoxSy'] = sy;
      r['debugBoxSide'] = side;
      r['debugWasCached'] = wasCached;
    }
    return r;
  }

  // (sx, sy, side) carry through into the classifier path. Both branches
  // above already clamped them to the source bounds, so no further fix-up
  // is needed here.

  // ── 4. Crop-and-resize the square → classifier input (224×224) ──
  final clsInput = Float32List(_kInputSize * _kInputSize * 3);
  _cropResizeIntoClassifier(
    src: rgb,
    srcW: srcW,
    srcH: srcH,
    cropX: sx,
    cropY: sy,
    cropSide: side,
    dst: clsInput,
    isNHWC: clsMeta.isNHWC,
  );

  // ── 5. Classify ── single forward pass. (h-flip TTA was removed once
  // the input pipeline was fixed; it was bandaiding a much bigger bug.)
  classifier.getInputTensor(0).setTo(clsInput);
  classifier.invoke();
  final outView = classifier.getOutputTensor(0).data;
  final outProbs = outView.buffer.asFloat32List(
    outView.offsetInBytes,
    outView.lengthInBytes ~/ 4,
  );
  // Copy the prob vector out of the tensor view (the underlying buffer
  // gets reused on the next invoke).
  final n = math.min(outProbs.length, _kNumClasses);
  final probs = Float32List.fromList(
    n == outProbs.length ? outProbs : outProbs.sublist(0, n),
  );

  sw.stop();

  // Ship the prob vector back to the main isolate zero-copy. The smoother
  // averages these across frames.
  final probsBytes = probs.buffer.asUint8List(
    probs.offsetInBytes,
    probs.lengthInBytes,
  );
  final r = <String, Object>{
    'type': 'result',
    'skipped': false,
    'probs': TransferableTypedData.fromList([probsBytes]),
    'probsLength': n,
    'detectorConf': detectorConf,
    'inferenceMs': sw.elapsedMicroseconds / 1000.0,
  };
  if (_kDebugOverlay) {
    final rgba = _classifierInputToRgba(clsInput, isNHWC: clsMeta.isNHWC);
    r['debugInputRgba'] = TransferableTypedData.fromList([rgba]);
    r['debugSrcW'] = srcW;
    r['debugSrcH'] = srcH;
    r['debugBoxSx'] = sx;
    r['debugBoxSy'] = sy;
    r['debugBoxSide'] = side;
    r['debugWasCached'] = wasCached;
  }
  return r;
}

// Render the classifier input (NHWC or NCHW Float32List in [0,1]) into a
// row-major RGBA Uint8List ready for ui.decodeImageFromPixels in the UI.
Uint8List _classifierInputToRgba(
  Float32List src, {
  required bool isNHWC,
}) {
  const n = _kInputSize * _kInputSize;
  final out = Uint8List(n * 4);
  if (isNHWC) {
    for (var i = 0; i < n; i++) {
      final s = i * 3;
      final d = i * 4;
      var r = (src[s] * 255.0).round();
      var g = (src[s + 1] * 255.0).round();
      var b = (src[s + 2] * 255.0).round();
      r = r.clamp(0, 255);
      g = g.clamp(0, 255);
      b = b.clamp(0, 255);
      out[d] = r;
      out[d + 1] = g;
      out[d + 2] = b;
      out[d + 3] = 255;
    }
  } else {
    for (var i = 0; i < n; i++) {
      final d = i * 4;
      var r = (src[i] * 255.0).round();
      var g = (src[n + i] * 255.0).round();
      var b = (src[2 * n + i] * 255.0).round();
      r = r.clamp(0, 255);
      g = g.clamp(0, 255);
      b = b.clamp(0, 255);
      out[d] = r;
      out[d + 1] = g;
      out[d + 2] = b;
      out[d + 3] = 255;
    }
  }
  return out;
}

// Rotate an interleaved-RGB Float32List 90° clockwise. Camera frames arrive
// in raw sensor orientation, which is 90° CW from device portrait on a
// typical Android back camera. Rotating the buffer before detection and
// classification keeps subjects upright (matching the training data).
//   src dims: (srcW, srcH)        — sensor orientation
//   dst dims: (srcH, srcW)        — display orientation
//   Mapping:  old (x, y) → new ((srcH - 1) - y, x)
void _rotate90CWRgb(
  Float32List src,
  int srcW,
  int srcH,
  Float32List dst,
) {
  // dst width = srcH; dst row stride = srcH * 3.
  for (var y = 0; y < srcH; y++) {
    final newX = (srcH - 1) - y;
    final srcRowOff = y * srcW * 3;
    for (var x = 0; x < srcW; x++) {
      final srcOff = srcRowOff + x * 3;
      // new pixel coords: (newX, x) in a dst with width=srcH
      final dstOff = (x * srcH + newX) * 3;
      dst[dstOff] = src[srcOff];
      dst[dstOff + 1] = src[srcOff + 1];
      dst[dstOff + 2] = src[srcOff + 2];
    }
  }
}

// ─── Detector parsing ──────────────────────────────────────────────────────
//
// YOLOv8 emits cxcywh in detector-input pixel space and per-class scores
// already sigmoid-activated. We don't care about the class index here (the
// detector is just an attention mechanism) — we want the *anchor* whose
// best-class score is highest, plus that anchor's box.

({double cx, double cy, double w, double h, double conf}) _bestAnchor(
  Float32List logits,
  _DetectorMeta m,
) {
  final a = m.numAnchors;
  final c = m.numClasses;
  var bestConf = -1.0;
  var bestAnchor = 0;

  if (m.channelFirst) {
    // [4+C, A] (with batch dim stripped). Channel ch at anchor i → ch*A + i.
    final classEnd = (4 + c) * a;
    for (var i = 0; i < a; i++) {
      var maxScore = logits[4 * a + i];
      for (var idx = 5 * a + i; idx < classEnd; idx += a) {
        final s = logits[idx];
        if (s > maxScore) maxScore = s;
      }
      if (maxScore > bestConf) {
        bestConf = maxScore;
        bestAnchor = i;
      }
    }
    return (
      cx: logits[bestAnchor],
      cy: logits[a + bestAnchor],
      w: logits[2 * a + bestAnchor],
      h: logits[3 * a + bestAnchor],
      conf: bestConf,
    );
  } else {
    // [A, 4+C]. Anchor i at channel ch → i*(4+C) + ch.
    final stride = 4 + c;
    for (var i = 0; i < a; i++) {
      final base = i * stride;
      var maxScore = logits[base + 4];
      for (var ch = 5; ch < stride; ch++) {
        final s = logits[base + ch];
        if (s > maxScore) maxScore = s;
      }
      if (maxScore > bestConf) {
        bestConf = maxScore;
        bestAnchor = i;
      }
    }
    final base = bestAnchor * stride;
    return (
      cx: logits[base],
      cy: logits[base + 1],
      w: logits[base + 2],
      h: logits[base + 3],
      conf: bestConf,
    );
  }
}

// ─── Pixel kernels ─────────────────────────────────────────────────────────
//
// The pipeline decodes the camera frame once into a dense RGB float buffer
// and then samples it twice: once via letterbox into the detector input,
// once via crop-and-resize into the classifier input. Both samplers use
// 4-tap bilinear (pixel-centre convention) — the antialiased separable
// variant in MlService is only worth it for very large downscales.

void _decodeYuv420ToRgb({
  required Uint8List yPlane,
  required Uint8List uPlane,
  required Uint8List vPlane,
  required int yRowStride,
  required int uRowStride,
  required int vRowStride,
  required int uPixelStride,
  required int vPixelStride,
  required int srcW,
  required int srcH,
  required Float32List dst,
}) {
  for (var y = 0; y < srcH; y++) {
    final cyRow = (y >> 1);
    final yRowOff = y * yRowStride;
    final uRowOff = cyRow * uRowStride;
    final vRowOff = cyRow * vRowStride;
    var dOff = y * srcW * 3;
    for (var x = 0; x < srcW; x++) {
      final cxCol = x >> 1;
      final yv = yPlane[yRowOff + x].toDouble();
      final u = uPlane[uRowOff + cxCol * uPixelStride].toDouble();
      final v = vPlane[vRowOff + cxCol * vPixelStride].toDouble();

      // BT.601 full-range YUV → RGB.
      final cb = u - 128.0;
      final cr = v - 128.0;
      var r = yv + 1.402 * cr;
      var g = yv - 0.344136 * cb - 0.714136 * cr;
      var b = yv + 1.772 * cb;
      if (r < 0) {
        r = 0;
      } else if (r > 255) {
        r = 255;
      }
      if (g < 0) {
        g = 0;
      } else if (g > 255) {
        g = 255;
      }
      if (b < 0) {
        b = 0;
      } else if (b > 255) {
        b = 255;
      }
      dst[dOff++] = r / 255.0;
      dst[dOff++] = g / 255.0;
      dst[dOff++] = b / 255.0;
    }
  }
}

void _decodeBgra8888ToRgb({
  required Uint8List bytes,
  required int rowStride,
  required int srcW,
  required int srcH,
  required Float32List dst,
}) {
  for (var y = 0; y < srcH; y++) {
    final rowOff = y * rowStride;
    var dOff = y * srcW * 3;
    for (var x = 0; x < srcW; x++) {
      final off = rowOff + x * 4;
      // BGRA → RGB.
      dst[dOff++] = bytes[off + 2] / 255.0;
      dst[dOff++] = bytes[off + 1] / 255.0;
      dst[dOff++] = bytes[off] / 255.0;
    }
  }
}

// Bilinear letterbox-resize from a dense RGB buffer into the detector's
// NHWC input. Returns (scale, padX, padY) so the caller can unmap detected
// boxes back to source coords.
({double scale, double padX, double padY}) _letterboxIntoDetectorInput({
  required Float32List src,
  required int srcW,
  required int srcH,
  required Float32List dst,
  required int dstW,
  required int dstH,
}) {
  final scale = math.min(dstW / srcW, dstH / srcH);
  final newW = srcW * scale;
  final newH = srcH * scale;
  final padX = (dstW - newW) / 2.0;
  final padY = (dstH - newH) / 2.0;

  // Pre-fill with the gray pad colour (YOLOv8 letterbox convention).
  for (var i = 0; i < dst.length; i++) {
    dst[i] = _kGrayPad;
  }

  final xStart = padX.floor();
  final yStart = padY.floor();
  final xEnd = (padX + newW).ceil();
  final yEnd = (padY + newH).ceil();

  for (var dy = yStart; dy < yEnd; dy++) {
    if (dy < 0 || dy >= dstH) continue;
    // Centre of dst pixel mapped back into src coords.
    final sy = (dy - padY + 0.5) / scale - 0.5;
    final iy0 = sy.floor();
    final fy = sy - iy0;
    final iyA = iy0 < 0 ? 0 : (iy0 >= srcH ? srcH - 1 : iy0);
    final iyBraw = iy0 + 1;
    final iyB = iyBraw < 0 ? 0 : (iyBraw >= srcH ? srcH - 1 : iyBraw);

    for (var dx = xStart; dx < xEnd; dx++) {
      if (dx < 0 || dx >= dstW) continue;
      final sx = (dx - padX + 0.5) / scale - 0.5;
      final ix0 = sx.floor();
      final fx = sx - ix0;
      final ixA = ix0 < 0 ? 0 : (ix0 >= srcW ? srcW - 1 : ix0);
      final ixBraw = ix0 + 1;
      final ixB = ixBraw < 0 ? 0 : (ixBraw >= srcW ? srcW - 1 : ixBraw);

      final w00 = (1.0 - fx) * (1.0 - fy);
      final w10 = fx * (1.0 - fy);
      final w01 = (1.0 - fx) * fy;
      final w11 = fx * fy;

      final off00 = (iyA * srcW + ixA) * 3;
      final off10 = (iyA * srcW + ixB) * 3;
      final off01 = (iyB * srcW + ixA) * 3;
      final off11 = (iyB * srcW + ixB) * 3;

      final r =
          src[off00] * w00 +
          src[off10] * w10 +
          src[off01] * w01 +
          src[off11] * w11;
      final g =
          src[off00 + 1] * w00 +
          src[off10 + 1] * w10 +
          src[off01 + 1] * w01 +
          src[off11 + 1] * w11;
      final b =
          src[off00 + 2] * w00 +
          src[off10 + 2] * w10 +
          src[off01 + 2] * w01 +
          src[off11 + 2] * w11;

      final dOff = (dy * dstW + dx) * 3;
      dst[dOff] = r;
      dst[dOff + 1] = g;
      dst[dOff + 2] = b;
    }
  }
  return (scale: scale, padX: padX, padY: padY);
}

// Bilinear crop-and-resize from a dense RGB buffer into the classifier's
// 224×224 input. The crop region is specified in source pixel coords and
// is expected to already lie within the source bounds.
void _cropResizeIntoClassifier({
  required Float32List src,
  required int srcW,
  required int srcH,
  required double cropX,
  required double cropY,
  required double cropSide,
  required Float32List dst,
  required bool isNHWC,
}) {
  final scale = cropSide / _kInputSize;

  for (var dy = 0; dy < _kInputSize; dy++) {
    final sy = cropY + (dy + 0.5) * scale - 0.5;
    final iy0 = sy.floor();
    final fy = sy - iy0;
    final iyA = iy0 < 0 ? 0 : (iy0 >= srcH ? srcH - 1 : iy0);
    final iyBraw = iy0 + 1;
    final iyB = iyBraw < 0 ? 0 : (iyBraw >= srcH ? srcH - 1 : iyBraw);

    for (var dx = 0; dx < _kInputSize; dx++) {
      final sx = cropX + (dx + 0.5) * scale - 0.5;
      final ix0 = sx.floor();
      final fx = sx - ix0;
      final ixA = ix0 < 0 ? 0 : (ix0 >= srcW ? srcW - 1 : ix0);
      final ixBraw = ix0 + 1;
      final ixB = ixBraw < 0 ? 0 : (ixBraw >= srcW ? srcW - 1 : ixBraw);

      final w00 = (1.0 - fx) * (1.0 - fy);
      final w10 = fx * (1.0 - fy);
      final w01 = (1.0 - fx) * fy;
      final w11 = fx * fy;

      final off00 = (iyA * srcW + ixA) * 3;
      final off10 = (iyA * srcW + ixB) * 3;
      final off01 = (iyB * srcW + ixA) * 3;
      final off11 = (iyB * srcW + ixB) * 3;

      final r =
          src[off00] * w00 +
          src[off10] * w10 +
          src[off01] * w01 +
          src[off11] * w11;
      final g =
          src[off00 + 1] * w00 +
          src[off10 + 1] * w10 +
          src[off01 + 1] * w01 +
          src[off11 + 1] * w11;
      final b =
          src[off00 + 2] * w00 +
          src[off10 + 2] * w10 +
          src[off01 + 2] * w01 +
          src[off11 + 2] * w11;

      _writeRGB(dst, dx, dy, r, g, b, isNHWC);
    }
  }
}

@pragma('vm:prefer-inline')
void _writeRGB(
  Float32List dst,
  int dx,
  int dy,
  double r,
  double g,
  double b,
  bool isNHWC,
) {
  if (isNHWC) {
    final off = (dy * _kInputSize + dx) * 3;
    dst[off] = r;
    dst[off + 1] = g;
    dst[off + 2] = b;
  } else {
    const plane = _kInputSize * _kInputSize;
    final off = dy * _kInputSize + dx;
    dst[off] = r;
    dst[plane + off] = g;
    dst[2 * plane + off] = b;
  }
}

// ─── Riverpod providers ────────────────────────────────────────────────────

final scannerServiceProvider = FutureProvider<ScannerService>((ref) async {
  final service = await ScannerService.create();
  ref.onDispose(service.dispose);
  return service;
});

final scannerStatusProvider = StreamProvider<ScannerStatus>((ref) async* {
  final service = await ref.watch(scannerServiceProvider.future);
  // Replay current state to subscribers that join late.
  yield service.status;
  yield* service.statusStream;
});
