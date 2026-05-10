import 'package:isar/isar.dart';

part 'species.g.dart';

@collection
class Species {
  Id id = Isar.autoIncrement;

  @Index()
  late int classId;

  late String commonName;
  late String scientificName;
  late String kingdom;
  late String family;

  bool isCaught = false;
}
