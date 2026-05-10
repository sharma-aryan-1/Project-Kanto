// Live camera → background-isolate inference pipeline.
//
// Architecture:
//
//   [Camera plugin]          (UI isolate)
//        │ CameraImage
//        ▼
//   ScannerService._handleFrame
//        │ extracts plane bytes as TransferableTypedData
//        │ (transfers ownership; no big-buffer copy across isolates)
//        ▼
//   _isolateEntry (worker isolate)
//        │ YUV420 → RGB float[0,1] AND simultaneous bilinear resize to 224x224
//        │ Interpreter.invoke()  (model bytes loaded once at init)
//        │ argmax over [1, 10000] logits
//        ▼
//   ScannerService._onIsolateMessage  (UI isolate)
//        │ updates ScannerStatus
//        ▼
//   scannerStatusProvider (Riverpod StreamProvider)
//
// Throttling: a single _isProcessing flag means while a frame is in flight,
// every CameraImage delivered by the plugin is dropped. As soon as the
// isolate returns a result we accept the next frame. This gives "as fast as
// the model can run" frame rate with zero queueing.
//
// Why we don't use IsolateInterpreter from tflite_flutter:
// IsolateInterpreter only runs invoke() in a separate isolate. Our cost is
// dominated by the YUV→RGB+resize preprocessing, which would still block the
// UI. Spawning our own isolate lets both stages run off the UI thread.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

const String _kModelAsset = 'assets/model/best_float.tflite';
const int _kInputSize = 224;
const int _kNumClasses = 10000;

// ─── Public types ──────────────────────────────────────────────────────────

class ScannerResult {
  final int classId;
  final double confidence;
  final double inferenceMs;
  final DateTime at;

  const ScannerResult({
    required this.classId,
    required this.confidence,
    required this.inferenceMs,
    required this.at,
  });
}

@immutable
class ScannerStatus {
  final bool isReady;
  final bool isStreaming;
  final bool isProcessing;
  final ScannerResult? lastResult;
  final String? error;

  const ScannerStatus({
    this.isReady = false,
    this.isStreaming = false,
    this.isProcessing = false,
    this.lastResult,
    this.error,
  });

  ScannerStatus copyWith({
    bool? isReady,
    bool? isStreaming,
    bool? isProcessing,
    ScannerResult? lastResult,
    Object? error = _sentinel,
  }) {
    return ScannerStatus(
      isReady: isReady ?? this.isReady,
      isStreaming: isStreaming ?? this.isStreaming,
      isProcessing: isProcessing ?? this.isProcessing,
      lastResult: lastResult ?? this.lastResult,
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
    final modelData = await rootBundle.load(_kModelAsset);
    final modelBytes = modelData.buffer.asUint8List();

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
            _onIsolateError(msg['message'] as String? ?? 'unknown isolate error');
            break;
        }
      }
    });

    _isolate = await Isolate.spawn(_isolateEntry, _mainReceive!.sendPort);
    await readyForInit.future;

    _isolateSend!.send(<String, Object>{
      'type': 'init',
      'modelBytes': TransferableTypedData.fromList([modelBytes]),
    });
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

    // ResolutionPreset.low is typically 320x240 (Android) / 192x144 (iOS).
    // We only need 224x224 for the model — burning CPU on YUV decode of a
    // 1080p frame is wasted work.
    _controller = CameraController(
      back,
      ResolutionPreset.low,
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
    _publish(
      _status.copyWith(
        isProcessing: false,
        lastResult: ScannerResult(
          classId: msg['classId'] as int,
          confidence: (msg['confidence'] as num).toDouble(),
          inferenceMs: (msg['inferenceMs'] as num).toDouble(),
          at: DateTime.now(),
        ),
        error: null,
      ),
    );
  }

  void _onIsolateError(String message) {
    _isProcessing = false;
    _publish(
      _status.copyWith(isProcessing: false, error: message),
    );
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

void _isolateEntry(SendPort mainSend) async {
  final port = ReceivePort();
  mainSend.send(port.sendPort);

  Interpreter? interpreter;
  List<int> inputShape = const [];
  bool isNHWC = true;

  await for (final raw in port) {
    if (raw is! Map) continue;
    final type = raw['type'];
    try {
      if (type == 'init') {
        final ttd = raw['modelBytes'] as TransferableTypedData;
        final bytes = ttd.materialize().asUint8List();
        interpreter = Interpreter.fromBuffer(bytes);
        inputShape = interpreter.getInputTensor(0).shape;
        if (inputShape.length == 4) {
          isNHWC = inputShape[1] == _kInputSize && inputShape[3] == 3;
        }
        mainSend.send(<String, Object>{'type': 'ready'});
      } else if (type == 'frame') {
        if (interpreter == null) continue;
        final result = _runFrame(raw, interpreter, isNHWC: isNHWC);
        mainSend.send(result);
      } else if (type == 'shutdown') {
        interpreter?.close();
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
  Map raw,
  Interpreter interpreter, {
  required bool isNHWC,
}) {
  final sw = Stopwatch()..start();

  final format = raw['format'] as String;
  final width = raw['width'] as int;
  final height = raw['height'] as int;
  final planes = (raw['planes'] as List)
      .map((e) => (e as TransferableTypedData).materialize().asUint8List())
      .toList(growable: false);
  final rowStrides = (raw['rowStrides'] as List).cast<int>();
  final pixelStrides = (raw['pixelStrides'] as List).cast<int?>();

  final input = Float32List(_kInputSize * _kInputSize * 3);

  if (format == 'yuv420') {
    _yuv420ToInputBilinear(
      yPlane: planes[0],
      uPlane: planes[1],
      vPlane: planes[2],
      yRowStride: rowStrides[0],
      uRowStride: rowStrides[1],
      vRowStride: rowStrides[2],
      uPixelStride: pixelStrides[1] ?? 1,
      vPixelStride: pixelStrides[2] ?? 1,
      srcW: width,
      srcH: height,
      dst: input,
      isNHWC: isNHWC,
    );
  } else if (format == 'bgra8888') {
    _bgra8888ToInputBilinear(
      bytes: planes[0],
      rowStride: rowStrides[0],
      srcW: width,
      srcH: height,
      dst: input,
      isNHWC: isNHWC,
    );
  } else {
    return <String, Object>{
      'type': 'error',
      'message': 'unsupported format: $format',
    };
  }

  interpreter.getInputTensor(0).setTo(input);
  interpreter.invoke();
  final outBytes = interpreter.getOutputTensor(0).data;
  final logits = outBytes.buffer.asFloat32List(
    outBytes.offsetInBytes,
    outBytes.lengthInBytes ~/ 4,
  );

  var bestIdx = 0;
  var bestVal = logits[0];
  final n = logits.length < _kNumClasses ? logits.length : _kNumClasses;
  for (var i = 1; i < n; i++) {
    if (logits[i] > bestVal) {
      bestVal = logits[i];
      bestIdx = i;
    }
  }

  sw.stop();
  return <String, Object>{
    'type': 'result',
    'classId': bestIdx,
    'confidence': bestVal,
    'inferenceMs': sw.elapsedMicroseconds / 1000.0,
  };
}

// ─── Pixel kernels ─────────────────────────────────────────────────────────
//
// Both kernels do a single-pass YUV/BGRA-decode + bilinear resize directly
// into the model's [1, 224, 224, 3] Float32 input. Bilinear (4-tap, pixel
// centers) is used here rather than the antialiased separable variant in
// MlService — for live frames the camera is already only ~1.4× larger than
// the input on ResolutionPreset.low, so the antialiasing benefit doesn't
// pay for the cost. Static-photo classification still uses the heavier
// kernel for parity with the Python ground truth.

void _yuv420ToInputBilinear({
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
  required bool isNHWC,
}) {
  final scaleX = srcW / _kInputSize;
  final scaleY = srcH / _kInputSize;

  for (var dy = 0; dy < _kInputSize; dy++) {
    final sy = (dy + 0.5) * scaleY - 0.5;
    final iy0 = sy.floor();
    final fy = sy - iy0;
    final iyA = iy0 < 0 ? 0 : (iy0 >= srcH ? srcH - 1 : iy0);
    final iyBraw = iy0 + 1;
    final iyB = iyBraw < 0 ? 0 : (iyBraw >= srcH ? srcH - 1 : iyBraw);

    for (var dx = 0; dx < _kInputSize; dx++) {
      final sx = (dx + 0.5) * scaleX - 0.5;
      final ix0 = sx.floor();
      final fx = sx - ix0;
      final ixA = ix0 < 0 ? 0 : (ix0 >= srcW ? srcW - 1 : ix0);
      final ixBraw = ix0 + 1;
      final ixB = ixBraw < 0 ? 0 : (ixBraw >= srcW ? srcW - 1 : ixBraw);

      final w00 = (1.0 - fx) * (1.0 - fy);
      final w10 = fx * (1.0 - fy);
      final w01 = (1.0 - fx) * fy;
      final w11 = fx * fy;

      // Bilinear-blend Y (full resolution).
      final y00 = yPlane[iyA * yRowStride + ixA];
      final y10 = yPlane[iyA * yRowStride + ixB];
      final y01 = yPlane[iyB * yRowStride + ixA];
      final y11 = yPlane[iyB * yRowStride + ixB];
      final y = y00 * w00 + y10 * w10 + y01 * w01 + y11 * w11;

      // Sample U/V at the chroma half-resolution; nearest-neighbour is fine
      // here, the chroma channel is already low-frequency.
      final cx = (ixA >> 1);
      final cy_ = (iyA >> 1);
      final u = uPlane[cy_ * uRowStride + cx * uPixelStride].toDouble();
      final v = vPlane[cy_ * vRowStride + cx * vPixelStride].toDouble();

      // BT.601 full-range YUV → RGB.
      final cb = u - 128.0;
      final cr = v - 128.0;
      var r = y + 1.402 * cr;
      var g = y - 0.344136 * cb - 0.714136 * cr;
      var b = y + 1.772 * cb;
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

      _writeRGB(dst, dx, dy, r / 255.0, g / 255.0, b / 255.0, isNHWC);
    }
  }
}

void _bgra8888ToInputBilinear({
  required Uint8List bytes,
  required int rowStride,
  required int srcW,
  required int srcH,
  required Float32List dst,
  required bool isNHWC,
}) {
  final scaleX = srcW / _kInputSize;
  final scaleY = srcH / _kInputSize;

  for (var dy = 0; dy < _kInputSize; dy++) {
    final sy = (dy + 0.5) * scaleY - 0.5;
    final iy0 = sy.floor();
    final fy = sy - iy0;
    final iyA = iy0 < 0 ? 0 : (iy0 >= srcH ? srcH - 1 : iy0);
    final iyBraw = iy0 + 1;
    final iyB = iyBraw < 0 ? 0 : (iyBraw >= srcH ? srcH - 1 : iyBraw);

    for (var dx = 0; dx < _kInputSize; dx++) {
      final sx = (dx + 0.5) * scaleX - 0.5;
      final ix0 = sx.floor();
      final fx = sx - ix0;
      final ixA = ix0 < 0 ? 0 : (ix0 >= srcW ? srcW - 1 : ix0);
      final ixBraw = ix0 + 1;
      final ixB = ixBraw < 0 ? 0 : (ixBraw >= srcW ? srcW - 1 : ixBraw);

      final w00 = (1.0 - fx) * (1.0 - fy);
      final w10 = fx * (1.0 - fy);
      final w01 = (1.0 - fx) * fy;
      final w11 = fx * fy;

      // BGRA layout: B at +0, G at +1, R at +2, A at +3.
      final off00 = iyA * rowStride + ixA * 4;
      final off10 = iyA * rowStride + ixB * 4;
      final off01 = iyB * rowStride + ixA * 4;
      final off11 = iyB * rowStride + ixB * 4;

      final r = (bytes[off00 + 2] * w00 +
              bytes[off10 + 2] * w10 +
              bytes[off01 + 2] * w01 +
              bytes[off11 + 2] * w11) /
          255.0;
      final g = (bytes[off00 + 1] * w00 +
              bytes[off10 + 1] * w10 +
              bytes[off01 + 1] * w01 +
              bytes[off11 + 1] * w11) /
          255.0;
      final b = (bytes[off00 + 0] * w00 +
              bytes[off10 + 0] * w10 +
              bytes[off01 + 0] * w01 +
              bytes[off11 + 0] * w11) /
          255.0;

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
