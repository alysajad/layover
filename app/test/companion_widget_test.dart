import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/presentation/companion_screen.dart';

void main() {
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
      await tester.pumpWidget(const SizedBox());
    });
  }
}
