import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../models/species.dart';

class IsarService {
  IsarService._(this._isar);

  final Isar _isar;

  static Future<IsarService> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final isar = await Isar.open(
      [SpeciesSchema],
      directory: dir.path,
      name: 'kanto',
    );
    return IsarService._(isar);
  }

  /// Idempotent first-launch seed: bulk-load every species record from the
  /// bundled taxonomy JSON. Uses a synchronous transaction + putAllSync so
  /// the 10k-row insert lands as a single LMDB write batch.
  Future<int> seedDatabase() async {
    if (_isar.species.countSync() > 0) {
      return _isar.species.countSync();
    }

    final raw = await rootBundle.loadString('assets/data/taxonomy.json');
    final decoded = jsonDecode(raw) as List<dynamic>;
    final species = decoded.map((e) {
      final m = e as Map<String, dynamic>;
      return Species()
        ..classId = m['classId'] as int
        ..commonName = (m['commonName'] as String?) ?? ''
        ..scientificName = (m['scientificName'] as String?) ?? ''
        ..kingdom = (m['kingdom'] as String?) ?? ''
        ..family = (m['family'] as String?) ?? '';
    }).toList(growable: false);

    _isar.writeTxnSync(() {
      _isar.species.putAllSync(species);
    });
    return species.length;
  }

  Future<Species?> getSpeciesByClassId(int classId) {
    return _isar.species.filter().classIdEqualTo(classId).findFirst();
  }

  Future<void> close() => _isar.close();
}

/// Opens Isar and seeds the species atlas on first launch. Cached for the
/// lifetime of the ProviderScope; `ref.onDispose` closes the database when
/// the scope itself tears down (e.g. on hot restart).
final isarServiceProvider = FutureProvider<IsarService>((ref) async {
  final service = await IsarService.open();
  await service.seedDatabase();
  ref.onDispose(service.close);
  return service;
});
