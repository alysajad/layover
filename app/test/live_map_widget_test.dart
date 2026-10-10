import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/live_map/data/live_map_store.dart';
import 'package:layover/features/live_map/presentation/live_map_screen.dart';

void main() {
  for (final width in [360.0, 1200.0]) {
    testWidgets('private session, consent, map fallback and stop at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final trip = TripStore(persistence: false);
      await trip.startDemo();
      final store = LiveMapStore(trip: trip);
      addTearDown(store.dispose);
      addTearDown(trip.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLayoverTheme(),
          home: LiveMapScreen(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Find your group'), findsOneWidget);
      await tester.tap(find.text('Create Live Map'));
      await tester.pumpAndSettle();
      expect(find.text('Unlinked · trip contacts'), findsOneWidget);
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start session'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Map preview needs'), findsOneWidget);
      expect(store.sharing, false);
      await tester.tap(find.text('Share location'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Everyone who joins'), findsOneWidget);
      expect(store.sharing, false);
      await tester.tap(find.text('Agree and share'));
      await tester.pumpAndSettle();
      expect(find.text('Sharing live location'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);
      await tester.tap(find.text('Stop sharing'));
      await tester.pumpAndSettle();
      expect(store.sharing, false);
      expect(store.visibleLocations, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
