import 'package:app/core/models/species.dart';
import 'package:app/core/providers.dart';
import 'package:app/core/services/isar_service.dart';
import 'package:app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in so widget tests avoid opening a real Isar database.
class _TestIsarService extends IsarService {
  Species? _speciesAtZero;

  @override
  Future<void> initialize() async {}

  @override
  Future<Species?> getSpeciesByClassId(int id) async =>
      id == 0 ? _speciesAtZero : null;

  @override
  Future<void> markAsCaught(int classId) async {
    final row = _speciesAtZero;
    if (row == null || row.classId != classId) return;
    row.isCaught = true;
    row.caughtDate = DateTime.utc(2026, 5, 8);
  }

  @override
  Future<void> insertDummyData() async {
    if (_speciesAtZero != null) return;
    _speciesAtZero = Species()
      ..classId = 0
      ..commonName = 'Blue Jay'
      ..scientificName = 'Cyanocitta cristata'
      ..loreDescription = 'Widget test lore.'
      ..isCaught = false;
  }
}

void main() {
  testWidgets('TestScreen shows empty state then dummy species', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isarServiceProvider.overrideWithValue(_TestIsarService()),
        ],
        child: const MyApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Database Empty. Awaiting Fuel.'), findsOneWidget);

    await tester.tap(find.text('Inject Dummy Data'));
    await tester.pumpAndSettle();

    expect(find.text('Blue Jay'), findsOneWidget);

    await tester.tap(find.text('Catch Animal'));
    await tester.pumpAndSettle();

    expect(find.text('Caught'), findsOneWidget);
  });
}
