import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../models/species.dart';

class IsarService {
  Isar? _isar;

  Isar get _db {
    final isar = _isar;
    if (isar == null || !isar.isOpen) {
      throw StateError(
        'IsarService must be initialized before use. Call initialize() first.',
      );
    }
    return isar;
  }

  Future<void> initialize() async {
    if (_isar != null && _isar!.isOpen) return;

    final existing = Isar.getInstance();
    if (existing != null && existing.isOpen) {
      _isar = existing;
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    _isar = await Isar.open([SpeciesSchema], directory: dir.path);
  }

  Future<Species?> getSpeciesByClassId(int id) async {
    return _db.species.where().classIdEqualTo(id).findFirst();
  }

  Future<void> markAsCaught(int classId) async {
    final isar = _db;
    await isar.writeTxn(() async {
      final species =
          await isar.species.where().classIdEqualTo(classId).findFirst();
      if (species == null) return;
      species.isCaught = true;
      species.caughtDate = DateTime.now();
      await isar.species.put(species);
    });
  }

  /// Loads bundled taxonomy JSON and bulk-inserts when the DB is empty (first launch).
  Future<void> seedDatabase() async {
    final isar = _db;

    final existingCount = isar.species.countSync();
    if (existingCount != 0) {
      // ignore: avoid_print — bootstrap instrumentation (temporary)
      print(
        'Isar seed: skipped (database already has $existingCount species rows; '
        'clear app data or uninstall to re-run first-launch seed from '
        'taxonomy.json).',
      );
      return;
    }

    final jsonString =
        await rootBundle.loadString('assets/data/taxonomy.json');

    final parseSw = Stopwatch()..start();
    final decoded = jsonDecode(jsonString) as List<dynamic>;
    final speciesList = decoded.map(_speciesFromTaxonomyJson).toList();
    parseSw.stop();
    final parseMs = parseSw.elapsedMilliseconds;
    final n = speciesList.length;

    if (n == 0) {
      // ignore: avoid_print — bootstrap instrumentation (temporary)
      print('Isar seed: taxonomy.json parsed 0 entries in ${parseMs}ms; nothing to insert.');
      return;
    }

    final insertSw = Stopwatch()..start();
    isar.writeTxnSync(() {
      isar.species.putAllSync(speciesList);
    });
    insertSw.stop();
    final insertMs = insertSw.elapsedMilliseconds;

    // ignore: avoid_print — bootstrap instrumentation (temporary)
    print('Isar seed: parsed $n rows in ${parseMs}ms');
    // ignore: avoid_print — bootstrap instrumentation (temporary)
    print('Isar seed: inserted $n rows in ${insertMs}ms');
  }

  static Species _speciesFromTaxonomyJson(dynamic e) {
    final map = e as Map<String, dynamic>;
    final s = Species()
      ..classId = (map['classId'] as num).toInt()
      ..commonName = map['commonName'] as String? ?? ''
      ..scientificName = map['scientificName'] as String? ?? ''
      ..loreDescription = map['loreDescription'] as String? ?? ''
      ..isCaught = map['isCaught'] as bool? ?? false;
    final caught = map['caughtDate'];
    if (caught != null) {
      s.caughtDate = DateTime.tryParse(caught as String);
    }
    return s;
  }

  Future<void> insertDummyData() async {
    final isar = _db;
    await isar.writeTxn(() async {
      final exists =
          await isar.species.where().classIdEqualTo(0).findFirst();
      if (exists != null) return;

      final dummy = Species()
        ..classId = 0
        ..commonName = 'Blue Jay'
        ..scientificName = 'Cyanocitta cristata'
        ..loreDescription =
            'Debug placeholder: a loud, intelligent corvid known for its blue crest and bold calls.'
        ..isCaught = false;

      await isar.species.put(dummy);
    });
  }
}
