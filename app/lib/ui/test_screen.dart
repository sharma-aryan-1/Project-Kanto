import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';

/// Temporary screen to exercise Isar CRUD flows.
class TestScreen extends ConsumerWidget {
  const TestScreen({super.key});

  static const int _demoClassId = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speciesAsync = ref.watch(speciesClassZeroProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Isar DB Test'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ElevatedButton(
            onPressed: () async {
              await ref.read(isarServiceProvider).insertDummyData();
              ref.invalidate(speciesClassZeroProvider);
            },
            child: const Text('Inject Dummy Data'),
          ),
          const SizedBox(height: 16),
          speciesAsync.when(
            data: (species) {
              if (species == null) {
                return const Text(
                  'Database Empty. Awaiting Fuel.',
                  style: TextStyle(fontSize: 16),
                );
              }
              return Card(
                elevation: 2,
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        species.commonName,
                        style:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        species.scientificName,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontStyle: FontStyle.italic,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                      ),
                      const Divider(height: 24),
                      Text(species.loreDescription),
                      const Divider(height: 24),
                      Row(
                        children: [
                          Icon(
                            species.isCaught
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: species.isCaught
                                ? Colors.green
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            species.isCaught
                                ? 'Caught'
                                : 'Not caught yet',
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (error, _) => Text(
              'Error: $error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor:
                  Theme.of(context).colorScheme.onSecondaryContainer,
            ),
            onPressed: () async {
              await ref.read(isarServiceProvider).markAsCaught(_demoClassId);
              ref.invalidate(speciesClassZeroProvider);
            },
            child: const Text('Catch Animal'),
          ),
        ],
      ),
    );
  }
}
