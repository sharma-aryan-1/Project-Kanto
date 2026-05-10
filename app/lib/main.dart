import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/models/species.dart';
import 'core/services/isar_service.dart';
import 'core/services/ml_service.dart';

const String _testImage = 'assets/images/test_animal.jpg';

// ── Providers ──────────────────────────────────────────────────────────────

/// Opens Isar on demand. The FutureProvider caches the open db so subsequent
/// reads don't reopen the file.
final isarServiceProvider = FutureProvider<IsarService>((ref) async {
  final service = await IsarService.open();
  await service.seedDatabase();
  ref.onDispose(service.close);
  return service;
});

final mlServiceProvider = FutureProvider<MlService>((ref) async {
  final service = MlService();
  await service.initialize();
  ref.onDispose(service.dispose);
  return service;
});

// ── App ────────────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: KantoApp()));
}

class KantoApp extends StatelessWidget {
  const KantoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Project Kanto',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const HomePage(),
    );
  }
}

// ── Scan result wrapper ────────────────────────────────────────────────────

class ScanOutcome {
  final ClassificationResult prediction;
  final Species? species;
  const ScanOutcome(this.prediction, this.species);
}

// ── Home ───────────────────────────────────────────────────────────────────

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  ScanOutcome? _outcome;
  String? _error;
  bool _busy = false;

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ml = await ref.read(mlServiceProvider.future);
      final isar = await ref.read(isarServiceProvider.future);

      final prediction = await ml.classifyImage(_testImage);
      final species = await isar.getSpeciesByClassId(prediction.classId);

      if (!mounted) return;
      setState(() => _outcome = ScanOutcome(prediction, species));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isarAsync = ref.watch(isarServiceProvider);
    final mlAsync = ref.watch(mlServiceProvider);
    final ready = isarAsync.hasValue && mlAsync.hasValue;
    final initError = isarAsync.error ?? mlAsync.error;

    return Scaffold(
      appBar: AppBar(title: const Text('Project Kanto')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusBanner(
              ready: ready,
              initError: initError,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: ready && !_busy ? _scan : null,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_busy ? 'Scanning...' : 'Scan Test Image'),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: SingleChildScrollView(
                child: _ResultPanel(outcome: _outcome, error: _error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Status banner ──────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.ready, required this.initError});

  final bool ready;
  final Object? initError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg;
    final IconData icon;
    final String label;
    if (initError != null) {
      bg = scheme.errorContainer;
      icon = Icons.error_outline;
      label = 'Init failed: $initError';
    } else if (!ready) {
      bg = scheme.secondaryContainer;
      icon = Icons.hourglass_top;
      label = 'Loading model + seeding species DB...';
    } else {
      bg = scheme.primaryContainer;
      icon = Icons.check_circle;
      label = 'Model loaded · 10,000 species ready';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

// ── Result card ────────────────────────────────────────────────────────────

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.outcome, required this.error});

  final ScanOutcome? outcome;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error\n\n$error'),
        ),
      );
    }
    final o = outcome;
    if (o == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No scan yet. Press the button to classify the bundled test image.',
          ),
        ),
      );
    }
    final species = o.species;
    final theme = Theme.of(context);
    final confPct = (o.prediction.confidence * 100).toStringAsFixed(2);
    final infMs = o.prediction.inferenceMs.toStringAsFixed(1);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              species?.commonName ?? 'Unknown species (id ${o.prediction.classId})',
              style: theme.textTheme.headlineSmall,
            ),
            if (species != null) ...[
              const SizedBox(height: 4),
              Text(
                species.scientificName,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const Divider(height: 28),
            _MetaRow(
              label: 'Class ID',
              value: '${o.prediction.classId}',
            ),
            _MetaRow(label: 'Family', value: species?.family ?? '—'),
            _MetaRow(label: 'Kingdom', value: species?.kingdom ?? '—'),
            const SizedBox(height: 8),
            _MetaRow(label: 'Confidence', value: '$confPct %'),
            _MetaRow(label: 'Inference', value: '$infMs ms'),
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
