import 'package:isar/isar.dart';

part 'species.g.dart';

@collection
class Species {
  Id id = Isar.autoIncrement;

  @Index()
  late int classId;

  late String commonName;

  late String scientificName;

  late String loreDescription;

  bool isCaught = false;

  DateTime? caughtDate;
}
