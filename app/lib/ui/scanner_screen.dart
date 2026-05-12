// Live viewfinder. Bottom→top:
//
//   1. CameraPreview, scaled-to-cover the screen
//   2. Top + bottom vignette (so HUD chrome is readable over bright frames)
//   3. Top status strip (inference time + processing pulse dot)
//   4. Centered targeting reticle (corner brackets + crosshair, color shifts
//      white → green when confidence crosses _kConfidenceThreshold)
//   5. Bottom HUD card (species details when hot, scanning banner otherwise)
//
// All ML state flows through scannerStatusProvider; species lookups are
// memoized per classId via _speciesByClassIdProvider so we hit Isar at most
// once per distinct prediction during a live session.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui show Image, decodeImageFromPixels, PixelFormat;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/species.dart';
import '../core/services/isar_service.dart';
import '../core/services/scanner_service.dart';

// The real gate lives in ScannerService's temporal smoother — it emits
// confidence == 0 for any frame that isn't a locked target. So here we just
// need "is there a lock?": anything > 0 is hot, 0 is cold.
const double _kConfidenceThreshold = 0.0;
const double _kReticleDimension = 260;

/// Caches species lookups per classId. AutoDispose drops cache entries that
/// are no longer being watched (i.e., once the prediction moves on).
final _speciesByClassIdProvider =
    FutureProvider.autoDispose.family<Species?, int>((ref, classId) async {
  final isar = await ref.watch(isarServiceProvider.future);
  return isar.getSpeciesByClassId(classId);
});

// ─── Screen ────────────────────────────────────────────────────────────────

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen>
    with WidgetsBindingObserver {
  ScannerService? _service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_startUp);
  }

  Future<void> _startUp() async {
    try {
      final svc = await ref.read(scannerServiceProvider.future);
      if (!mounted) return;
      _service = svc;
      await svc.startStream();
    } catch (_) {
      // Surfaced by the FutureProvider's error state in build().
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final svc = _service;
    if (svc == null) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        unawaited(svc.stopStream());
        break;
      case AppLifecycleState.resumed:
        unawaited(svc.startStream());
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service?.stopStream();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncService = ref.watch(scannerServiceProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      body: asyncService.when(
        loading: () => const _BootView(),
        error: (e, _) => _ErrorView(message: '$e'),
        data: (service) => _LiveView(service: service),
      ),
    );
  }
}

// ─── Boot ──────────────────────────────────────────────────────────────────

class _BootView extends StatefulWidget {
  const _BootView();

  @override
  State<_BootView> createState() => _BootViewState();
}

class _BootViewState extends State<_BootView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          colors: [Color(0xFF0A1F1A), Colors.black],
          stops: [0.0, 1.0],
          radius: 1.0,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _spin,
              builder: (context, _) => Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: Icon(
                  Icons.center_focus_strong_rounded,
                  size: 64,
                  color: Colors.greenAccent.withValues(alpha: 0.85),
                ),
              ),
            ),
            const SizedBox(height: 32),
            const _LabelText('INITIALIZING SCANNER', spacing: 4),
            const SizedBox(height: 8),
            Text(
              'Loading model · Seeding atlas · Booting camera',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Error ─────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: Colors.redAccent.shade100,
            ),
            const SizedBox(height: 18),
            const Text(
              'Scanner failed to start',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Live ──────────────────────────────────────────────────────────────────

class _LiveView extends ConsumerWidget {
  final ScannerService service;
  const _LiveView({required this.service});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncStatus = ref.watch(scannerStatusProvider);
    final status = asyncStatus.value;
    final result = status?.lastResult;
    final confidence = result?.confidence ?? 0.0;
    final hot = confidence > _kConfidenceThreshold;

    return Stack(
      fit: StackFit.expand,
      children: [
        _CameraFill(controller: service.controller!),
        const _Vignette(),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(child: _TopStrip(status: status)),
        ),
        Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 1.0, end: hot ? 1.04 : 1.0),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: _Reticle(hot: hot),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: SafeArea(
            child: _BottomHUD(result: result, hot: hot),
          ),
        ),
        const Positioned(
          top: 60,
          right: 12,
          child: SafeArea(child: _DebugOverlay()),
        ),
      ],
    );
  }
}

// ─── Camera fill ───────────────────────────────────────────────────────────
//
// CameraPreview reports aspectRatio in landscape (sensor orientation).
// To "cover" a portrait device, scale = aspect * (screen aspect). If that
// product is < 1 we invert it — same trick the official camera plugin
// example uses.

class _CameraFill extends StatelessWidget {
  final CameraController controller;
  const _CameraFill({required this.controller});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    var scale = controller.value.aspectRatio * size.aspectRatio;
    if (scale < 1) scale = 1 / scale;
    return ClipRect(
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.center,
        child: Center(child: CameraPreview(controller)),
      ),
    );
  }
}

// ─── Vignette ──────────────────────────────────────────────────────────────

class _Vignette extends StatelessWidget {
  const _Vignette();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.55),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.7),
            ],
            stops: const [0.0, 0.18, 0.55, 1.0],
          ),
        ),
      ),
    );
  }
}

// ─── Top strip ─────────────────────────────────────────────────────────────

class _TopStrip extends StatelessWidget {
  final ScannerStatus? status;
  const _TopStrip({required this.status});

  @override
  Widget build(BuildContext context) {
    final s = status;
    final hasResult = s?.lastResult != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const _LabelText('PROJECT KANTO', spacing: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(50),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PulsingDot(active: s?.isProcessing ?? false),
                const SizedBox(width: 8),
                Text(
                  hasResult
                      ? '${s!.lastResult!.inferenceMs.toStringAsFixed(0)} ms'
                      : 'standby',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final bool active;
  const _PulsingDot({required this.active});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = widget.active ? _ctrl.value : 0.5;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.greenAccent.withValues(alpha: 0.5 + 0.5 * t),
            boxShadow: [
              BoxShadow(
                color: Colors.greenAccent.withValues(alpha: 0.5 * t),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Reticle ───────────────────────────────────────────────────────────────

class _Reticle extends StatelessWidget {
  final bool hot;
  const _Reticle({required this.hot});

  @override
  Widget build(BuildContext context) {
    final coldColor = Colors.white.withValues(alpha: 0.7);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: hot ? Colors.greenAccent : coldColor),
      duration: const Duration(milliseconds: 250),
      builder: (context, color, _) => SizedBox.square(
        dimension: _kReticleDimension,
        child: CustomPaint(
          painter: _ReticlePainter(color: color ?? coldColor, hot: hot),
        ),
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  final Color color;
  final bool hot;
  _ReticlePainter({required this.color, required this.hot});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cornerLen = w * 0.18;

    if (hot) {
      // Soft outer glow when locked on.
      final glow = Paint()
        ..color = Colors.greenAccent.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      _strokeCornerBrackets(canvas, w, h, cornerLen, glow);
    }

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    _strokeCornerBrackets(canvas, w, h, cornerLen, stroke);

    // Center crosshair: 4 short segments + a tiny dot.
    final c = Offset(w / 2, h / 2);
    canvas.drawLine(c.translate(-14, 0), c.translate(-4, 0), stroke);
    canvas.drawLine(c.translate(4, 0), c.translate(14, 0), stroke);
    canvas.drawLine(c.translate(0, -14), c.translate(0, -4), stroke);
    canvas.drawLine(c.translate(0, 4), c.translate(0, 14), stroke);
    canvas.drawCircle(c, 1.6, Paint()..color = color);
  }

  static void _strokeCornerBrackets(
    Canvas canvas,
    double w,
    double h,
    double cornerLen,
    Paint paint,
  ) {
    // Top-left
    canvas.drawLine(Offset(0, cornerLen), Offset(0, 0), paint);
    canvas.drawLine(Offset(0, 0), Offset(cornerLen, 0), paint);
    // Top-right
    canvas.drawLine(Offset(w - cornerLen, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, cornerLen), paint);
    // Bottom-left
    canvas.drawLine(Offset(0, h - cornerLen), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(cornerLen, h), paint);
    // Bottom-right
    canvas.drawLine(Offset(w, h - cornerLen), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w - cornerLen, h), paint);
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter old) {
    return old.color != color || old.hot != hot;
  }
}

// ─── Bottom HUD ────────────────────────────────────────────────────────────

class _BottomHUD extends StatelessWidget {
  final ScannerResult? result;
  final bool hot;
  const _BottomHUD({required this.result, required this.hot});

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (!hot || result == null || result!.topK.isEmpty) {
      child = const _ScanningBanner(key: ValueKey('scanning'));
    } else {
      // Re-animate only when the *ranked set* of candidates changes — pure
      // probability fluctuations leave the key alone and re-render in place.
      final keySuffix = result!.topK.map((e) => e.classId).join('-');
      child = _SpeciesCard(
        key: ValueKey('topk-$keySuffix'),
        result: result!,
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.4),
          end: Offset.zero,
        ).animate(anim);
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: child,
    );
  }
}

class _ScanningBanner extends StatefulWidget {
  const _ScanningBanner({super.key});

  @override
  State<_ScanningBanner> createState() => _ScanningBannerState();
}

class _ScanningBannerState extends State<_ScanningBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(50),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(50),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: 0.4 + 0.6 * _ctrl.value,
                      child: const Icon(Icons.radar,
                          size: 16, color: Colors.white),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Scanning for biological entities...',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 13,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeciesCard extends ConsumerWidget {
  final ScannerResult result;
  const _SpeciesCard({super.key, required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primary = result.topK.first;
    final primaryAsync = ref.watch(_speciesByClassIdProvider(primary.classId));
    final primarySpecies = primaryAsync.value;
    final runners = result.topK.skip(1).take(2).toList();

    final commonName = primarySpecies?.commonName.isNotEmpty == true
        ? primarySpecies!.commonName
        : 'Class ID ${primary.classId}';
    final scientific = primarySpecies?.scientificName ?? '';
    final family = primarySpecies?.family ?? '';

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.greenAccent.withValues(alpha: 0.28),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(50),
                      border: Border.all(
                        color: Colors.greenAccent.withValues(alpha: 0.35),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      'IDENTIFIED',
                      style: TextStyle(
                        color: Colors.greenAccent.shade200,
                        fontSize: 9,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'ID ${primary.classId}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 10,
                      letterSpacing: 1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                commonName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              if (scientific.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  scientific,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              if (family.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Family · $family',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _ConfidenceBar(confidence: primary.probability),
              if (runners.isNotEmpty) ...[
                const SizedBox(height: 14),
                const _RunnerUpHeader(),
                const SizedBox(height: 6),
                for (final r in runners)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _RunnerUpRow(
                      classId: r.classId,
                      probability: r.probability,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RunnerUpHeader extends StatelessWidget {
  const _RunnerUpHeader();

  @override
  Widget build(BuildContext context) {
    Widget rule() => Expanded(
          child: Container(
            height: 1,
            color: Colors.white.withValues(alpha: 0.12),
          ),
        );
    return Row(
      children: [
        rule(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'OTHER CANDIDATES',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
            ),
          ),
        ),
        rule(),
      ],
    );
  }
}

class _RunnerUpRow extends ConsumerWidget {
  final int classId;
  final double probability;
  const _RunnerUpRow({required this.classId, required this.probability});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSpecies = ref.watch(_speciesByClassIdProvider(classId));
    final species = asyncSpecies.value;
    final name = species?.commonName.isNotEmpty == true
        ? species!.commonName
        : 'Class ID $classId';

    return Row(
      children: [
        Container(
          width: 4,
          height: 4,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.greenAccent.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${(probability * 100).toStringAsFixed(1)}%',
          style: TextStyle(
            color: Colors.greenAccent.withValues(alpha: 0.7),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _ConfidenceBar extends StatelessWidget {
  final double confidence;
  const _ConfidenceBar({required this.confidence});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'CONFIDENCE',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 10,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: confidence, end: confidence),
              duration: const Duration(milliseconds: 200),
              builder: (context, v, _) => Text(
                '${(v * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(50),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: confidence),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => LinearProgressIndicator(
              value: v,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              valueColor: const AlwaysStoppedAnimation(Colors.greenAccent),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Debug overlay ─────────────────────────────────────────────────────────
//
// Floating top-right panel that mirrors back the per-frame diagnostic data
// shipped by ScannerService when _kDebugOverlay is on. Shows the actual
// 224×224 RGB image being fed to the classifier (so we can verify the crop
// is on the subject, with correct colours and orientation), plus the raw
// detector confidence, bbox in source coords, and source-frame dimensions.
// Disappears entirely when the service isn't shipping debug payloads.

const int _kDebugInputSize = 224; // matches _kInputSize in scanner_service.dart

class _DebugOverlay extends ConsumerStatefulWidget {
  const _DebugOverlay();

  @override
  ConsumerState<_DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends ConsumerState<_DebugOverlay> {
  ui.Image? _currentImage;
  Uint8List? _decodingBytes;

  @override
  void dispose() {
    _currentImage?.dispose();
    super.dispose();
  }

  void _maybeDecodeNew(Uint8List? bytes) {
    if (identical(bytes, _decodingBytes)) return;
    _decodingBytes = bytes;
    if (bytes == null) {
      final old = _currentImage;
      if (old != null) {
        old.dispose();
        if (mounted) setState(() => _currentImage = null);
      }
      return;
    }
    ui.decodeImageFromPixels(
      bytes,
      _kDebugInputSize,
      _kDebugInputSize,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted) {
          image.dispose();
          return;
        }
        // Drop stale results — a newer decode may already be in flight.
        if (!identical(bytes, _decodingBytes)) {
          image.dispose();
          return;
        }
        setState(() {
          _currentImage?.dispose();
          _currentImage = image;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<ScannerStatus>>(scannerStatusProvider, (prev, next) {
      _maybeDecodeNew(next.value?.debug?.classifierInputRgba);
    });

    final debug = ref.watch(scannerStatusProvider).value?.debug;
    if (debug == null) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Colors.cyanAccent.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'DEBUG',
                    style: TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 9,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _DebugBadge(debug: debug),
                ],
              ),
              const SizedBox(height: 6),
              _DebugInset(image: _currentImage, skipped: debug.wasSkipped),
              const SizedBox(height: 6),
              _DebugStatLine(
                label: 'det',
                value: debug.detectorConf.toStringAsFixed(3),
              ),
              _DebugStatLine(
                label: 'box',
                value:
                    '${debug.boxSx.toStringAsFixed(0)},'
                    '${debug.boxSy.toStringAsFixed(0)} '
                    '× ${debug.boxSide.toStringAsFixed(0)}',
              ),
              _DebugStatLine(
                label: 'src',
                value: '${debug.srcW}×${debug.srcH}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DebugBadge extends StatelessWidget {
  final DebugFrame debug;
  const _DebugBadge({required this.debug});

  @override
  Widget build(BuildContext context) {
    final String text;
    final Color color;
    if (debug.wasSkipped) {
      text = 'SKIP';
      color = Colors.redAccent;
    } else if (debug.wasCached) {
      text = 'CACHED';
      color = Colors.amberAccent;
    } else {
      text = 'LIVE';
      color = Colors.greenAccent;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 8,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DebugInset extends StatelessWidget {
  final ui.Image? image;
  final bool skipped;
  const _DebugInset({required this.image, required this.skipped});

  @override
  Widget build(BuildContext context) {
    const double dim = 110;
    if (skipped) {
      return Container(
        width: dim,
        height: dim,
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Colors.redAccent.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        alignment: Alignment.center,
        child: const Text(
          'NO INPUT\n(skipped)',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.redAccent,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      );
    }
    final img = image;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: dim,
        height: dim,
        color: Colors.white.withValues(alpha: 0.05),
        child: img == null
            ? const Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.cyanAccent,
                  ),
                ),
              )
            : RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.none),
      ),
    );
  }
}

class _DebugStatLine extends StatelessWidget {
  final String label;
  final String value;
  const _DebugStatLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 9,
                letterSpacing: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _LabelText extends StatelessWidget {
  final String text;
  final double spacing;
  const _LabelText(this.text, {this.spacing = 2});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.7),
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: spacing,
      ),
    );
  }
}
