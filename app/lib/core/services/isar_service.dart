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
