import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/live_map/data/device_location.dart';
import 'package:layover/features/live_map/data/live_map_api.dart';
import 'package:layover/features/live_map/data/live_map_store.dart';
import 'package:layover/features/live_map/domain/models.dart';

class Account extends TripStore {
  Account() : super(persistence: false);
  String identity = 'alice';
  @override
  String get userId => identity;
  @override
  bool get signedIn => identity.isNotEmpty;
  void switchAccount() {
    identity = 'bob';
    notifyListeners();
  }
}

class FakeDevice extends DeviceLocation {
  final fixesController = StreamController<Json>.broadcast();
  bool denied = false;
  int permissions = 0, acquisitions = 0;
  @override
  Future<void> requestPermission() async {
    permissions++;
    if (denied)
      throw const FormatException('Permission denied; viewing is available.');
  }

  @override
  Stream<Json> fixes() {
    acquisitions++;
    return fixesController.stream;
  }
}

class FakeApi extends LiveMapApi {
  FakeApi() : super(null);
  final List<String> actions = [];
  int polls = 0, publishes = 0, generation = 0;
  bool fail = false;
  bool sharing = false;
  Completer<Json>? pendingSnapshot, pendingConsent, pendingPublish;
  List<Json> locations = [];
  Json data() => {
    'session': {
      'id': 's',
      'created_by': 'alice',
      'name': 'Friends',
      'status': 'active',
      'expires_at': DateTime.now()
          .add(const Duration(hours: 2))
          .toIso8601String(),
    },
    'server_time': DateTime.now().toIso8601String(),
    'members': [
      {
        'user_id': 'alice',
        'display_name': 'Alice',
        'membership_status': 'joined',
        'sharing_status': sharing ? 'sharing' : 'stopped',
        'generation': generation,
      },
    ],
    'locations': locations,
  };
  @override
  Future<Json> sessions() async => {'sessions': [], 'contacts': []};
  @override
  Future<Json> snapshot(String id) async {
    polls++;
    if (fail) throw Exception('Network unavailable');
    return pendingSnapshot?.future ?? data();
  }

  @override
  Future<Json> command(String action, Json data) async {
    actions.add(action);
    if (fail) throw Exception('Network unavailable');
    if (action == 'consent') {
      sharing = true;
      generation++;
      if (pendingConsent != null) return pendingConsent!.future;
    }
    if (action == 'stop' || action == 'pause') {
      sharing = false;
      locations = [];
      generation++;
    }
    return {'session_id': 's', 'generation': generation};
  }

  @override
  Future<Json> publish(
    String id,
    int generation,
    int sequence,
    Json fix,
  ) async {
    publishes++;
    if (fail) throw Exception('Network unavailable');
    return pendingPublish?.future ?? {'accepted': true};
  }
}

Json fix({double accuracy = 12, int age = 0}) => {
  'latitude': 15.5,
  'longitude': 73.8,
  'accuracy_m': accuracy,
  'client_timestamp': DateTime.now()
      .subtract(Duration(seconds: age))
      .toIso8601String(),
};
void main() {
  late Account account;
  late FakeApi api;
  late FakeDevice device;
  late LiveMapStore store;
  setUp(() {
    account = Account();
    api = FakeApi();
    device = FakeDevice();
    store = LiveMapStore(trip: account, api: api, device: device);
  });
  tearDown(() async {
    store.dispose();
    account.dispose();
    await device.fixesController.close();
  });
  test('viewing never asks permission; consent starts and stop cancels acquisition', () async {
    await store.enter('s');
    expect(device.permissions, 0);
    expect(store.sharing, false);
    await store.share();
    expect(device.permissions, 1);
    expect(store.sharing, true);
    device.fixesController.add(fix());
    await Future<void>.delayed(Duration.zero);
    expect(api.publishes, 1);
    device.fixesController.add(fix());
    await Future<void>.delayed(Duration.zero);
    expect(api.publishes, 1);
    await store.stop();
    expect(store.sharing, false);
    expect(device.fixesController.hasListener, false);
    expect(api.actions.last, 'stop');
  });
  test(
    'denied permission permits authorized viewing without consent',
    () async {
      device.denied = true;
      await store.enter('s');
      await store.share();
      expect(store.snapshot, isNotNull);
      expect(store.sharing, false);
      expect(api.actions, isNot(contains('consent')));
      expect(store.error, contains('Permission denied'));
    },
  );
  test('background stops; resume only views', () async {
    await store.enter('s');
    await store.share();
    await store.suspend();
    expect(store.snapshot, isNull);
    expect(store.sharing, false);
    expect(api.actions.last, 'pause');
    await store.resume();
    expect(store.snapshot, isNotNull);
    expect(store.sharing, false);
    expect(device.acquisitions, 1);
  });
  test('late snapshot cannot cross account boundary', () async {
    api.pendingSnapshot = Completer<Json>();
    final pending = store.enter('s');
    account.switchAccount();
    api.pendingSnapshot!.complete(api.data());
    await pending;
    expect(store.snapshot, isNull);
    expect(store.sessions, isEmpty);
    expect(store.viewing, false);
  });
  test(
    'late snapshot after suspension is discarded and polls do not overlap',
    () async {
      api.pendingSnapshot = Completer<Json>();
      final pending = store.enter('s');
      await store.refresh();
      expect(api.polls, 1);
      await store.suspend();
      api.pendingSnapshot!.complete(api.data());
      await pending;
      expect(store.snapshot, isNull);
    },
  );
  test('stop racing with consent compensates without starting GPS', () async {
    await store.enter('s');
    api.pendingConsent = Completer<Json>();
    final pending = store.share();
    await Future<void>.delayed(Duration.zero);
    await store.stop();
    api.pendingConsent!.complete({'generation': 1});
    await pending;
    expect(store.sharing, false);
    expect(device.acquisitions, 0);
    expect(api.actions.last, 'stop');
  });
  test(
    'offline stop is immediate, no queued coordinates, and explains lease',
    () async {
      await store.enter('s');
      await store.share();
      api.fail = true;
      await store.stop();
      expect(store.sharing, false);
      expect(device.fixesController.hasListener, false);
      expect(store.snapshot, isNull);
      expect(store.error, contains('30 seconds'));
    },
  );
  test('failed authorization hides all sensitive data and stops GPS', () async {
    await store.enter('s');
    await store.share();
    api.fail = true;
    await store.refresh();
    expect(store.visibleLocations, isEmpty);
    expect(store.snapshot, isNull);
    expect(store.sharing, false);
  });
  test(
    'bad or cached fixes are skipped; poor but usable fix is labeled',
    () async {
      await store.enter('s');
      await store.share();
      device.fixesController.add(fix(age: 31));
      device.fixesController.add(fix(accuracy: 5001));
      await Future<void>.delayed(Duration.zero);
      expect(api.publishes, 0);
      device.fixesController.add(fix(accuracy: 150));
      await Future<void>.delayed(Duration.zero);
      expect(api.publishes, 1);
      expect(store.error, contains('Approximate GPS'));
    },
  );
  test('late publication response cannot restart sharing after stop', () async {
    await store.enter('s');
    await store.share();
    api.pendingPublish = Completer<Json>();
    device.fixesController.add(fix());
    await Future<void>.delayed(Duration.zero);
    await store.stop();
    api.pendingPublish!.complete({'accepted': true});
    await Future<void>.delayed(Duration.zero);
    expect(store.sharing, false);
  });
  test(
    'server freshness separates stale from stopped and hides expired fixes',
    () async {
      final now = DateTime.now();
      api.locations = [
        for (final age in [10, 16, 31])
          {
            'user_id': '$age',
            'latitude': 0,
            'longitude': 0,
            'accuracy_m': 10,
            'received_at': now
                .subtract(Duration(seconds: age))
                .toIso8601String(),
          },
      ];
      await store.enter('s');
      expect(store.visibleLocations.length, 2);
      expect(
        freshness(store.visibleLocations.last, store.serverNow),
        startsWith('Stale'),
      );
      expect(
        distanceMetres(
          {'latitude': 0, 'longitude': 0},
          {'latitude': 0, 'longitude': 1},
        ),
        closeTo(111195, 2),
      );
    },
  );
  test('demo uses synthetic memory data and never asks permission', () async {
    final trip = TripStore(persistence: false);
    await trip.startDemo();
    final demo = LiveMapStore(trip: trip, device: device);
    await demo.enter();
    final created = await demo.command('create', {'name': 'Demo'});
    await demo.enter(created!['session_id'] as String);
    await demo.command('start', {'session_id': demo.sessionId});
    await demo.share();
    expect(device.permissions, 0);
    expect(demo.visibleLocations.length, 1);
    await demo.suspend();
    demo.dispose();
    trip.dispose();
  });
}
