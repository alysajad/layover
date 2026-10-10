import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/trip_explorer/presentation/explorer_screen.dart';

void main() {
  for (final width in [360.0, 1200.0]) {
    testWidgets('explore, select, compare, save and share at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final trip = TripStore(persistence: false);
      await trip.initialize();
      addTearDown(trip.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLayoverTheme(),
          home: ExplorerScreen(trip: trip, tripId: 'demo-goa'),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tap(String label) async {
        final target = find.text(label).last;
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      await tap('Find places');
      expect(find.text('Demo heritage courtyard'), findsOneWidget);
      final required = find.text('must visit').first;
      await tester.ensureVisible(required);
      await tester.tap(required);
      await tester.pumpAndSettle();
      await tap('Generate alternatives');
      expect(find.text('A few ways to spend the day'), findsOneWidget);
      expect(find.textContaining('Incomplete estimate'), findsWidgets);
      await tap('Save new version');
      expect(find.text('Saved version 1.'), findsOneWidget);
      await tap('Share with trip');
      expect(find.text('Shared with current trip members.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      trip.switchDemoUser('demo-rahul');
      await tester.pumpAndSettle();
      expect(
        find.text('This trip is no longer available to this account.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
