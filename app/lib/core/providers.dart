import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/species.dart';
import 'services/isar_service.dart';

/// Exposes the shared [IsarService] instance created in `main()` via
/// `ProviderScope(overrides: [...])`.
final isarServiceProvider = Provider<IsarService>((ref) {
  throw StateError(
    'isarServiceProvider must be overridden with ProviderScope in main().',
  );
});

/// Loads the species whose ML `classId` is `0` (dummy data seed).
final speciesClassZeroProvider =
    FutureProvider.autoDispose<Species?>((ref) async {
      final service = ref.watch(isarServiceProvider);
      return service.getSpeciesByClassId(0);
    });
