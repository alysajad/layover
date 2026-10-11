import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/domain/models.dart';
import 'package:layover/features/trip_explorer/data/explorer_repository.dart';
import 'package:layover/features/trip_explorer/presentation/explorer_map.dart';
import 'package:layover/features/trip_explorer/presentation/explorer_screen.dart';

class _Client extends Mock implements SupabaseClient {}

class _Query extends Mock implements SupabaseQueryBuilder {}

class _Rows extends Mock implements PostgrestFilterBuilder<PostgrestList> {}

class _Trip extends TripStore {
  _Trip(SupabaseClient client) : super(client: client, persistence: false) {
    selectedTrip = 'trip';
    snapshot = TripSnapshot({
      'trips': [
        {
          'id': 'trip',
          'title': 'Holiday',
          'destination': 'Goa',
          'organizer_user_id': 'alice',
        },
      ],
      'members': [
        {'trip_id': 'trip', 'user_id': 'alice'},
      ],
    });
  }
  @override
  String get userId => 'alice';
  @override
  bool get signedIn => true;
}

class _Gps extends GeolocatorPlatform {
  LocationPermission permission = LocationPermission.whileInUse;
  bool enabled = true;
  int fixes = 0, requests = 0;
  Completer<Position>? pending;
  Object? failure;
  Position get fix => Position(
    longitude: 75.84,
    latitude: 11.27,
    timestamp: DateTime.now(),
    accuracy: 230,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return permission;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    fixes++;
    if (failure != null) throw failure!;
    return pending?.future ?? fix;
  }
}

void main() {
  late _Gps gps;
  late _Trip trip;
  late _Rows records;
  setUp(() {
    final old = GeolocatorPlatform.instance;
    gps = _Gps();
    GeolocatorPlatform.instance = gps;
    addTearDown(() => GeolocatorPlatform.instance = old);
    final client = _Client(), query = _Query();
    records = _Rows();
    when(() => client.from('exploration_plans')).thenAnswer((_) => query);
    when(() => query.select()).thenAnswer((_) => records);
    when(() => records.eq('trip_id', 'trip')).thenAnswer((_) => records);
    when(() => records.order('created_at', ascending: false))
        .thenAnswer((_) => records);
    when(() => records.limit(100)).thenAnswer((_) => records);
    when(() => records.timeout(const Duration(seconds: 20)))
        .thenAnswer((_) async {
          throw const PostgrestException(
            message: 'Missing exploration_plans',
            code: 'PGRST205',
          );
        });
    trip = _Trip(client);
    addTearDown(trip.dispose);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ExplorerScreen(trip: trip, tripId: 'trip'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  ExplorerMap map(WidgetTester tester) =>
      tester.widget<ExplorerMap>(find.byType(ExplorerMap));

  testWidgets(
    'GPS centers the map despite a missing saved-plan table; retry clears its error',
    (tester) async {
      await open(tester);
      expect(gps.fixes, 1);
      expect(map(tester).focus, [75.84, 11.27]);
      expect(map(tester).origin, [75.84, 11.27]);
      expect(map(tester).showSelection, isTrue);
      expect(map(tester).initialZoom, 13);
      expect(
        find.textContaining('Explorer setup on the server is incomplete'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Using approximate location (±230 m)'),
        findsOneWidget,
      );
      expect(
        find.text(
          'The request failed. Your saved versions are unchanged. Retry when connected.',
        ),
        findsNothing,
      );
      when(() => records.timeout(const Duration(seconds: 20)))
          .thenAnswer((_) async => []);
      await tester.ensureVisible(find.text('Retry saved plans'));
      await tester.tap(find.text('Retry saved plans'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Explorer setup on the server is incomplete'),
        findsNothing,
      );
      expect(map(tester).focus, [75.84, 11.27]);
      expect(gps.fixes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a slow saved-plan request leaves GPS and area controls available',
    (tester) async {
      final pending = Completer<PostgrestList>();
      when(() => records.timeout(const Duration(seconds: 20)))
          .thenAnswer((_) => pending.future);
      await open(tester);
      expect(map(tester).focus, [75.84, 11.27]);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).enabled,
        isTrue,
      );
      pending.complete([]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final permission in [
    LocationPermission.denied,
    LocationPermission.deniedForever,
  ]) {
    testWidgets(
      '$permission keeps the map editable without a fictitious start marker',
      (tester) async {
        gps.permission = permission;
        await open(tester);
        expect(gps.fixes, 0);
        expect(gps.requests, permission == LocationPermission.denied ? 1 : 0);
        expect(map(tester).showSelection, isFalse);
        expect(map(tester).focus, isNull);
        expect(
          tester.widget<TextField>(find.byType(TextField).last).enabled,
          isTrue,
        );
        if (permission == LocationPermission.deniedForever) {
          expect(find.text('Open app settings'), findsOneWidget);
        } else {
          expect(
            find.textContaining('Location access was not granted'),
            findsOneWidget,
          );
        }
      },
    );
  }

  testWidgets(
    'disabled services offer location settings; a timeout offers retry',
    (tester) async {
      gps.enabled = false;
      await open(tester);
      expect(find.text('Open location settings'), findsOneWidget);
      expect(gps.fixes, 0);
      gps.enabled = true;
      gps.failure = TimeoutException('GPS timeout');
      await tester.ensureVisible(find.text('Use my location'));
      await tester.tap(find.text('Use my location'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your location took too long to arrive'),
        findsOneWidget,
      );
      expect(find.text('Open location settings'), findsNothing);
      expect(map(tester).showSelection, isFalse);
    },
  );

  testWidgets('a delayed GPS fix does not replace a manually selected area', (
    tester,
  ) async {
    gps.pending = Completer<Position>();
    await open(tester);
    map(tester).onZone!({
      'type': 'circle',
      'center': [73.8, 15.5],
      'radius_m': 3000,
    });
    await tester.pump();
    gps.pending!.complete(gps.fix);
    await tester.pumpAndSettle();
    expect(map(tester).origin, [73.8, 15.5]);
    expect(map(tester).zone['radius_m'], 3000);
    expect(find.textContaining('Using approximate location'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'GPS completing after leaving Explorer cannot update the disposed screen',
    (tester) async {
      gps.pending = Completer<Position>();
      await open(tester);
      await tester.pumpWidget(const SizedBox());
      gps.pending!.complete(gps.fix);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test('missing server setup and timeouts have distinct actionable errors', () {
    expect(
      explorerErrorMessage(
        const FunctionException(status: 404, details: {'code': 'NOT_FOUND'}),
      ),
      contains('Place search and discovery are not available yet'),
    );
    expect(
      explorerErrorMessage(
        const PostgrestException(message: 'missing', code: 'PGRST202'),
      ),
      contains('Explorer setup on the server is incomplete'),
    );
    expect(
      explorerErrorMessage(TimeoutException('timeout')),
      contains('took too long'),
    );
    expect(
      explorerErrorMessage(
        const FunctionException(
          status: 503,
          details: {'error': 'Place and route service is not configured'},
        ),
      ),
      'Place and route service is not configured',
    );
  });
}
