import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/presentation/companion_screen.dart';

void main() {
  testWidgets('compact layout supports enlarged text and trip actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final store = TripStore(persistence: false);
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLayoverTheme(),
        home: CompanionScreen(store: store),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in ['Plan', 'Money', 'Bookings', 'Group', 'Overview']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byTooltip('Trip actions'));
    await tester.pumpAndSettle();
    expect(find.text('Create trip'), findsOneWidget);
    expect(find.text('Edit trip'), findsOneWidget);
    await tester.tap(find.text('Join trip'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Invite code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final width in [360.0, 1200.0]) {
    testWidgets('companion navigation and poll form at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = TripStore(persistence: false);
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLayoverTheme(),
          home: CompanionScreen(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Layover'), findsOneWidget);
      expect(find.text('Goa weekend'), findsWidgets);
      expect(find.text('Live Map · Find your group'), findsOneWidget);
      for (final label in ['Plan', 'Money', 'Bookings', 'Group', 'Overview']) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('Plan').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add to plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Date or budget poll'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Food budget',
      );
      await tester.tap(find.text('Dates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Budget').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Options (one per line)'),
        '1000\n2000',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        store.snapshot
            .entries('demo-goa', 'poll')
            .any((e) => e.title == 'Food budget'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Money').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expenses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Shared dinner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (INR)'),
        '1000.01',
      );
      await tester.ensureVisible(find.text('Equally'));
      await tester.tap(find.text('Equally'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Weights / nights').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(store.snapshot.expenses('demo-goa').single.amount, 100001);
      expect(
        store.snapshot
            .expenses('demo-goa')
            .single
            .splits
            .values
            .reduce((a, b) => a + b),
        100001,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Overview').last);
      store.snapshot.data['trips'] = [];
      store.selectedTrip = null;
      await tester.pumpAndSettle();
      expect(find.text('Your next trip starts here'), findsOneWidget);
      expect(find.text('Live Map · Find your group'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
