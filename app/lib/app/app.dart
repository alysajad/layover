import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/companion/data/trip_store.dart';
import '../features/companion/presentation/companion_screen.dart';
import 'theme.dart';
import '../features/live_map/data/live_map_store.dart';

final liveMapStoreProvider = Provider.autoDispose
    .family<LiveMapStore, (TripStore, String)>((ref, key) {
      final store = LiveMapStore(trip: key.$1);
      ref.onDispose(store.dispose);
      return store;
    });

final tripStoreProvider = Provider<TripStore>((ref) {
  final store = createTripStore();
  ref.onDispose(store.dispose);
  return store;
});

class LayoverApp extends ConsumerWidget {
  const LayoverApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'Layover',
    debugShowCheckedModeBanner: false,
    theme: buildLayoverTheme(),
    home: CompanionScreen(store: ref.watch(tripStoreProvider)),
  );
}
