import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/domain/models.dart';
import 'package:layover/features/companion/presentation/companion_screen.dart';
import 'package:layover/features/companion/presentation/forms.dart';

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester, String label, String value) async {
  final finder = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
}

Finder card(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(Card)).first;

void main() {
  for (final width in [360.0, 1200.0]) {
    testWidgets(
      'bookings and group actions persist across all tabs at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 950);
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
        await tap(tester, find.text('Bookings').last);
        await tap(tester, find.byTooltip('Add booking'));
        await fill(tester, 'Title', 'QA hotel');
        await fill(tester, 'Confirmation reference', 'QA-123');
        await tap(tester, find.text('Save'));
        expect(
          store.snapshot
              .entries('demo-goa', 'booking')
              .single
              .text('reference'),
          'QA-123',
        );
        await tap(
          tester,
          find.descendant(
            of: card('QA hotel'),
            matching: find.text('0 comments'),
          ),
        );
        await fill(tester, 'Comment', 'Check-in confirmed');
        await tap(tester, find.text('Continue'));
        expect(find.textContaining('Check-in confirmed'), findsOneWidget);
        await tap(
          tester,
          find.descendant(
            of: card('QA hotel'),
            matching: find.byTooltip('Entry actions'),
          ),
        );
        await tap(tester, find.text('Edit'));
        await fill(tester, 'Title', 'QA hotel updated');
        await tap(tester, find.text('Save'));
        expect(store.snapshot.entries('demo-goa', 'booking').single.version, 2);
        await tap(tester, find.text('Group').last);
        await tap(tester, find.byTooltip('Add task'));
        await fill(tester, 'Title', 'QA packing');
        await tap(tester, find.text('Save'));
        await tap(
          tester,
          find.descendant(
            of: card('QA packing'),
            matching: find.byType(Checkbox),
          ),
        );
        expect(
          store.snapshot
              .entries('demo-goa', 'task')
              .firstWhere((e) => e.title == 'QA packing')
              .done,
          true,
        );
        await tap(tester, find.byTooltip('Add meeting point'));
        await fill(tester, 'Title', 'QA regroup');
        await fill(tester, 'Address', 'Station entrance');
        await tap(tester, find.text('Save'));
        await tap(
          tester,
          find.descendant(
            of: card('QA regroup'),
            matching: find.text('I have arrived'),
          ),
        );
        final meeting = store.snapshot
            .entries('demo-goa', 'meeting')
            .firstWhere((e) => e.title == 'QA regroup');
        expect(
          store.snapshot.responses(meeting.id).single['response']['choice'],
          'arrived',
        );
        await tap(tester, find.byTooltip('Add contact'));
        await fill(tester, 'Title', 'QA hotel desk');
        await fill(tester, 'Contact phone', '+91 12345 67890');
        await tap(tester, find.text('Save'));
        expect(
          store.snapshot.entries('demo-goa', 'contact').single.text('phone'),
          '+91 12345 67890',
        );
        await tap(tester, find.text('Post announcement'));
        await fill(tester, 'Title', 'QA departure notice');
        await fill(tester, 'Notes', 'Meet at eight');
        await tap(tester, find.text('Save'));
        await tap(tester, find.text('Overview').last);
        expect(find.text('QA departure notice'), findsOneWidget);
        await tap(tester, find.text('Bookings').last);
        expect(find.text('QA hotel updated'), findsOneWidget);
        await tap(
          tester,
          find.descendant(
            of: card('QA hotel updated'),
            matching: find.byTooltip('Entry actions'),
          ),
        );
        await tap(tester, find.text('Remove'));
        await tap(tester, find.text('Confirm'));
        expect(store.snapshot.entries('demo-goa', 'booking'), isEmpty);
        await tap(tester, find.text('Group').last);
        await tap(tester, find.text('Archive'));
        await tap(tester, find.text('Confirm'));
        expect(store.trip!.archived, true);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == 'Add task',
                ),
              )
              .onPressed,
          isNull,
        );
        await tap(tester, find.text('Restore'));
        await tap(tester, find.text('Confirm'));
        expect(store.trip!.archived, false);
        store.switchDemoUser('demo-rahul');
        await tester.pumpAndSettle();
        expect(find.text('Archive'), findsNothing);
        expect(find.text('Post announcement'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('pot revision preserves unequal shares and opening version', (
    tester,
  ) async {
    final store = TripStore(persistence: false);
    addTearDown(store.dispose);
    await store.initialize();
    final oldVersion = store.snapshot.pot('demo-goa')!['version'];
    Map<String, dynamic>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showMoneyForm(
                context,
                store,
                pot: true,
                initial: {
                  'title': 'Stay',
                  'amount': '100.00',
                  'shares': {
                    'demo-asha': 1000,
                    'demo-rahul': 3000,
                    'demo-meera': 6000,
                  },
                },
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tap(tester, find.text('Open'));
    expect(find.text('Exact amounts'), findsOneWidget);
    // A concurrent server revision must not silently replace the form's token.
    (store.snapshot.data['pots'] as List).first['version'] = 99;
    await tap(tester, find.text('Review'));
    expect(result?['version'], oldVersion);
    expect(result?['weights'], {
      'demo-asha': 1000,
      'demo-rahul': 3000,
      'demo-meera': 6000,
    });
    expect(result?['split_mode'], 'exact');
  });

  testWidgets(
    'open form remains on its original trip and rejects lost membership',
    (tester) async {
      final store = TripStore(persistence: false);
      addTearDown(store.dispose);
      await store.initialize();
      Json? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showEntryForm(context, store, 'booking');
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tap(tester, find.text('Open'));
      await fill(tester, 'Title', 'Trip A booking');
      (store.snapshot.data['trips'] as List).add({
        'id': 'other',
        'title': 'Other trip',
        'organizer_user_id': store.userId,
      });
      store.selectTrip('other');
      await tap(tester, find.text('Save'));
      expect(result?['trip_id'], 'demo-goa');
      result = null;
      await tap(tester, find.text('Open'));
      await fill(tester, 'Title', 'Removed trip');
      (store.snapshot.data['trips'] as List).removeWhere(
        (t) => t['id'] == 'other',
      );
      await tap(tester, find.text('Save'));
      expect(result, isNull);
      expect(find.textContaining('no longer available'), findsOneWidget);
    },
  );
}
