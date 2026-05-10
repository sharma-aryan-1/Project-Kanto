import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class ClassificationResult {
  final int classId;
  final double confidence;
  final double inferenceMs;

  const ClassificationResult({
    required this.classId,
    required this.confidence,
    required this.inferenceMs,
  });
}

/// Runs the bundled YOLOv8-cls float TFLite model. Pixel preprocessing matches
/// PIL/torchvision antialiased bilinear so predictions agree with the Python
/// reference (see ml_pipeline/src/diagnostics/bilinear_diff.py).
class MlService {
  static const String _modelAsset = 'assets/model/best_float.tflite';
  static const int inputSize = 224;

  Interpreter? _interpreter;
  List<int> _inputShape = const [];
  List<int> _outputShape = const [];

  Future<void> initialize() async {
    if (_interpreter != null) return;
    final data = await rootBundle.load(_modelAsset);
    final interpreter = Interpreter.fromBuffer(data.buffer.asUint8List());
    _inputShape = interpreter.getInputTensor(0).shape;
    _outputShape = interpreter.getOutputTensor(0).shape;
    _interpreter = interpreter;
  }

  List<int> get inputShape => _inputShape;
  List<int> get outputShape => _outputShape;

  Future<ClassificationResult> classifyImage(String assetPath) async {
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('MlService.initialize() was not called.');
    }

    final raw = await rootBundle.load(assetPath);
    final decoded = img.decodeImage(raw.buffer.asUint8List());
    if (decoded == null) {
      throw StateError('Could not decode image: $assetPath');
    }

    final shape = _inputShape;
    if (shape.length != 4) {
      throw StateError('Unexpected input rank: $shape');
    }
    final isNHWC = shape[1] == inputSize && shape[3] == 3;
    final isNCHW = shape[1] == 3 && shape[2] == inputSize;
    if (!isNHWC && !isNCHW) {
      throw StateError('Cannot infer NHWC/NCHW from shape $shape');
    }

    final inputCount = shape.fold<int>(1, (a, b) => a * b);
    final input = Float32List(inputCount);
    _bilinearResizeInto(decoded, input, isNHWC: isNHWC);

    interpreter.getInputTensor(0).setTo(input);
    final stopwatch = Stopwatch()..start();
    interpreter.invoke();
    stopwatch.stop();

    final outBytes = interpreter.getOutputTensor(0).data;
    final logits = outBytes.buffer.asFloat32List(
      outBytes.offsetInBytes,
      outBytes.lengthInBytes ~/ 4,
    );

    var bestIdx = 0;
    var bestVal = logits[0];
    for (var i = 1; i < logits.length; i++) {
      if (logits[i] > bestVal) {
        bestVal = logits[i];
        bestIdx = i;
      }
    }

    return ClassificationResult(
      classId: bestIdx,
      confidence: bestVal,
      inferenceMs: stopwatch.elapsedMicroseconds / 1000.0,
    );
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }

  // Antialiased bilinear matching modern PIL/torchvision semantics. For >1x
  // downscale PIL widens the triangle kernel to filterScale=src/dst, sampling
  // ~filterScale source pixels per output pixel along each axis. Naive 4-tap
  // bilinear gets a different prediction class on this fine-grained model.
  // Two-pass separable resize for ~10x speed-up over a 2D kernel.
  static void _bilinearResizeInto(
    img.Image src,
    Float32List dst, {
    required bool isNHWC,
  }) {
    final srcW = src.width;
    final srcH = src.height;
    final xK = _computeKernels(srcW, inputSize);
    final yK = _computeKernels(srcH, inputSize);

    final inter = Float32List(srcH * inputSize * 3);
    for (var y = 0; y < srcH; y++) {
      for (var dx = 0; dx < inputSize; dx++) {
        final k = xK[dx];
        final ws = k.weights;
        final start = k.start;
        var r = 0.0, g = 0.0, b = 0.0;
        for (var i = 0; i < ws.length; i++) {
          final p = src.getPixel(start + i, y);
          final w = ws[i];
          r += p.r * w;
          g += p.g * w;
          b += p.b * w;
        }
        final base = (y * inputSize + dx) * 3;
        inter[base] = r;
        inter[base + 1] = g;
        inter[base + 2] = b;
      }
    }

    const plane = inputSize * inputSize;
    for (var dy = 0; dy < inputSize; dy++) {
      final k = yK[dy];
      final ws = k.weights;
      final start = k.start;
      for (var dx = 0; dx < inputSize; dx++) {
        var r = 0.0, g = 0.0, b = 0.0;
        for (var i = 0; i < ws.length; i++) {
          final base = ((start + i) * inputSize + dx) * 3;
          final w = ws[i];
          r += inter[base] * w;
          g += inter[base + 1] * w;
          b += inter[base + 2] * w;
        }
        r /= 255.0;
        g /= 255.0;
        b /= 255.0;
        if (isNHWC) {
          final dbase = (dy * inputSize + dx) * 3;
          dst[dbase] = r;
          dst[dbase + 1] = g;
          dst[dbase + 2] = b;
        } else {
          final off = dy * inputSize + dx;
          dst[0 * plane + off] = r;
          dst[1 * plane + off] = g;
          dst[2 * plane + off] = b;
        }
      }
    }
  }

  static List<_Kernel1D> _computeKernels(int srcSize, int dstSize) {
    final scale = srcSize / dstSize;
    final filterScale = scale > 1.0 ? scale : 1.0;
    final kernels = <_Kernel1D>[];
    for (var i = 0; i < dstSize; i++) {
      final center = (i + 0.5) * scale;
      var xmin = (center - filterScale + 0.5).floor();
      var xmax = (center + filterScale + 0.5).floor();
      if (xmin < 0) xmin = 0;
      if (xmax > srcSize) xmax = srcSize;
      final width = xmax - xmin;
      final ws = Float64List(width);
      var sum = 0.0;
      for (var k = 0; k < width; k++) {
        final dist = ((xmin + k + 0.5) - center).abs();
        final w = 1.0 - dist / filterScale;
        final clamped = w > 0 ? w : 0.0;
        ws[k] = clamped;
        sum += clamped;
      }
      if (sum > 0) {
        for (var k = 0; k < width; k++) {
          ws[k] /= sum;
        }
      }
      kernels.add(_Kernel1D(xmin, ws));
    }
    return kernels;
  }
}

class _Kernel1D {
  final int start;
  final Float64List weights;
  const _Kernel1D(this.start, this.weights);
}
