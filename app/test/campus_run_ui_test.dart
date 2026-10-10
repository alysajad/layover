import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:layover/app/theme.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/live_map/data/campus_simulation.dart';
import 'package:layover/features/live_map/data/device_location.dart';
import 'package:layover/features/live_map/data/live_map_store.dart';
import 'package:layover/features/live_map/domain/models.dart';
import 'package:layover/features/live_map/presentation/live_map_screen.dart';

class TestAdmin extends TripStore {
  TestAdmin() : super(persistence: false);
  @override
  bool get signedIn => true;
  @override
  String get userId => 'real-admin-account';
}

class NoGps extends DeviceLocation {
  @override
  Future<void> requestPermission() async =>
      fail('Simulation requested GPS permission');
  @override
  Stream<Json> fixes() => throw StateError('Simulation acquired GPS');
}

void main() {
  test(
    'account stays admin and simulation consent never acquires GPS',
    () async {
      final trip = TestAdmin();
      final sim = CampusSimulation(adminId: trip.userId);
      final store = LiveMapStore(trip: trip, api: sim, device: NoGps());
      addTearDown(store.dispose);
      addTearDown(trip.dispose);
      final initialTrip = trip.snapshot;
      await store.enter(CampusSimulation.sessionId);
      expect(trip.demo, false);
      expect(store.organizer, true);
      await store.share();
      expect(store.sharing, true);
      expect(store.visibleLocations, hasLength(4));
      await store.stop();
      expect(store.visibleLocations, hasLength(3));
      await store.command('remove', {
        'session_id': CampusSimulation.sessionId,
        'target_id': 'sim-runner-0',
      });
      expect(store.visibleLocations, hasLength(2));
      await store.command('destination', {
        'session_id': CampusSimulation.sessionId,
        'name': 'Meet here',
        'latitude': 10.044,
        'longitude': 76.326,
      });
      expect(store.snapshot!.destination!['name'], 'Meet here');
      await store.suspend();
      expect(store.snapshot, isNull);
      sim.reset();
      await store.enter(CampusSimulation.sessionId);
      expect(store.organizer, true);
      expect(store.visibleLocations, hasLength(3));
      expect(trip.snapshot, same(initialTrip));
      expect(trip.userId, 'real-admin-account');
    },
  );
  for (final width in [360.0, 1200.0]) {
    testWidgets('campus controls and synthetic consent at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final trip = TestAdmin();
      addTearDown(trip.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLayoverTheme(),
          home: CampusTestRoute(trip: trip),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SIMULATION · YOU ARE ADMIN'), findsOneWidget);
      expect(find.text('You · admin (this phone)'), findsOneWidget);
      await tester.tap(find.text('Pause runners'));
      await tester.pumpAndSettle();
      expect(find.text('Resume runners'), findsOneWidget);
      await tester.tap(find.text('Test controls'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('offline').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('5× speed'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Back to map'));
      await tester.tap(find.text('Back to map'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show my test marker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show test marker'));
      await tester.pumpAndSettle();
      expect(find.text('Your test marker is visible'), findsOneWidget);
      await tester.tap(find.text('Stop sharing'));
      await tester.pumpAndSettle();
      expect(find.text('Your GPS stays off'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(trip.demo, false);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
