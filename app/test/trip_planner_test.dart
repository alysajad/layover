import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/domain/models.dart';
import 'package:layover/features/trip_planner/planner_screen.dart';

class ClientMock extends Mock implements SupabaseClient {}

class AuthMock extends Mock implements GoTrueClient {}

class RpcResult extends Fake implements PostgrestFilterBuilder<dynamic> {
  RpcResult(this.value);
  final dynamic value;
  @override
  Future<dynamic> timeout(
    Duration timeLimit, {
    FutureOr<dynamic> Function()? onTimeout,
  }) async => value;
}

void main() {
  late ClientMock client;
  late AuthMock auth;
  late TripStore store;
  late Json plan;
  late String user;
  setUp(() {
    client = ClientMock();
    auth = AuthMock();
    user = 'leader';
    when(() => client.auth).thenReturn(auth);
    when(() => auth.currentUser).thenAnswer(
      (_) => User(
        id: user,
        appMetadata: {},
        userMetadata: {},
        aud: 'authenticated',
        createdAt: '2026-01-01',
      ),
    );
    plan = {
      'state': 'ready',
      'revision': 1,
      'run_id': 'run-one',
      'funded': true,
      'stale': false,
      'settings': {
        'rooms': 1,
        'adults_per_room': 2,
        'food_daily_minor': 50000,
        'transport_daily_minor': 50000,
        'activity_daily_minor': 10000,
        'journey_minor': 100000,
        'origin': 'Kochi',
        'food_preferences': 'Vegetarian',
        'transport_mode': 'transit',
      },
      'result': {
        'source': 'Test provider fixture',
        'checked_at': '2030-01-01',
        'occupancy_note': 'Two adults in one room',
        'warnings': ['Exact meal prices need confirmation.'],
        'options': [
          {
            'hotel': {
              'name': 'Hill stay',
              'rating': 4.5,
              'reviews': 200,
              'quote_note': 'Confirm rooms and final prices with seller',
            },
            'total_minor': 830001,
            'remaining_minor': 169999,
            'costs': {
              'stay': 120001,
              'food': 300000,
              'transport': 150000,
              'activities': 60000,
              'journey': 100000,
              'reserve': 100000,
            },
            'days': [
              {
                'date': '2030-01-02',
                'weather': null,
                'stops': [
                  {'time': '11:00', 'name': 'Tea museum'},
                ],
              },
            ],
            'entries': [
              {
                'kind': 'task',
                'title': 'Pack walking shoes',
                'details': {'notes': 'For sightseeing.'},
              },
            ],
          },
        ],
      },
    };
    when(
      () => client.rpc<dynamic>('planner_state', params: any(named: 'params')),
    ).thenAnswer((_) => RpcResult(plan));
    store = TripStore(client: client, persistence: false);
    store.snapshot = TripSnapshot({
      'trips': [
        {
          'id': 'trip',
          'title': 'Mountain trip',
          'destination': 'Munnar',
          'start_date': '2030-01-01',
          'end_date': '2030-01-03',
          'organizer_user_id': 'leader',
        },
      ],
      'members': [
        {'trip_id': 'trip', 'user_id': 'leader', 'membership_status': 'joined'},
        {'trip_id': 'trip', 'user_id': 'peer', 'membership_status': 'joined'},
      ],
      'pots': [
        {
          'trip_id': 'trip',
          'target_minor_units': 1000000,
          'status': 'target_reached',
        },
      ],
    });
    store.selectedTrip = 'trip';
  });
  tearDown(() => store.dispose());
  Future<void> show(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLayoverTheme(),
        home: PlannerScreen(store: store, tripId: 'trip'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Review is responsive and blocks sharing after funding changes', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [360.0, 1200.0]) {
      await show(tester, width);
      final share = find.widgetWithText(
        FilledButton,
        'Share full itinerary with group',
      );
      await tester.scrollUntilVisible(share, 300);
      expect(tester.widget<FilledButton>(share).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      plan['funded'] = false;
      await tester.tap(find.byTooltip('Refresh plan'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(share).onPressed, isNull);
      plan['funded'] = true;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  testWidgets(
    'Preferences retain integer-money values and account changes hide draft',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester, 360);
      await tester.tap(find.text('Edit preferences'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, '500.00'), findsNWidgets(2));
      expect(find.widgetWithText(TextFormField, '1000.00'), findsOneWidget);
      user = 'peer';
      await tester.tap(find.byTooltip('Refresh plan'));
      await tester.pumpAndSettle();
      expect(find.text('Organizer access required.'), findsOneWidget);
      expect(find.text('Hill stay'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('Published options reopen on the actual shared selection', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    plan['state'] = 'shared';
    plan['selected_option'] = 1;
    final first = rows(plan['result']['options']).first;
    plan['result']['options'] = <Json>[
      first,
      {
        ...first,
        'hotel': {'name': 'Chosen stay'},
      },
    ];
    await show(tester, 360);
    await tester.scrollUntilVisible(find.text('Chosen stay'), 200);
    expect(find.text('Hill stay'), findsNothing);
    expect(find.text('Share full itinerary with group'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
