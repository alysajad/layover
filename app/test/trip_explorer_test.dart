import 'package:flutter_test/flutter_test.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/trip_explorer/data/explorer_repository.dart';
import 'package:layover/features/trip_explorer/domain/explorer.dart';

Json settings() => {
  'currency': 'INR',
  'budget_minor': 100000,
  'group_size': 3,
  'start_at': '2030-01-01T09:00:00Z',
  'end_at': '2030-01-01T17:00:00Z',
  'origin': [73.8278, 15.4909],
  'destination': null,
  'zone': {
    'type': 'circle',
    'center': [73.8278, 15.4909],
    'radius_m': 5000,
  },
  'caps': <String, dynamic>{},
  'modes': ['walk', 'drive'],
  'keep_order': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('currency precision, zero, rounding and invalid input', () {
    expect(readMoney('10.01', 'INR'), 1001);
    expect(readMoney('10.001', 'KWD'), 10001);
    expect(readMoney('10', 'JPY'), 10);
    expect(readMoney('0', 'INR'), 0);
    expect(readMoney('0.0', 'INR'), 0);
    expect(
      () => validateSettings({...settings(), 'end_at': '2030-01-08T09:00:01Z'}),
      throwsFormatException,
    );
    expect(() => readMoney('-1', 'INR'), throwsFormatException);
    expect(() => readMoney('1.001', 'INR'), throwsFormatException);
    expect(() => readMoney('1.1', 'JPY'), throwsFormatException);
    expect(amountText(10001, 'KWD'), '10.001');
  });
  test('all bases, ranges, unknowns, contingency and stable equal split', () {
    final items = [
      costItem(
        'p',
        'admission',
        'People',
        'INR',
        low: 100,
        high: 200,
        basis: 'per_person',
        status: 'manual',
        author: 'a',
      ),
      costItem(
        'v',
        'transport',
        'Vehicles',
        'INR',
        low: 500,
        high: 600,
        basis: 'per_vehicle',
        quantity: 2,
        status: 'manual',
        author: 'a',
      ),
      costItem(
        't',
        'admission',
        'Tickets',
        'INR',
        low: 100,
        high: 100,
        basis: 'per_ticket',
        quantity: 4,
        status: 'manual',
        author: 'a',
      ),
      costItem(
        'g',
        'food',
        'Group',
        'INR',
        low: 200,
        high: 200,
        status: 'manual',
        author: 'a',
      ),
      costItem(
        'f',
        'contingency',
        'Flat',
        'INR',
        low: 101,
        high: 101,
        basis: 'flat',
        status: 'manual',
        author: 'a',
      ),
      costItem('u', 'fees', 'Unknown', 'INR'),
    ];
    final total = totalCosts(items, 3, 'INR');
    expect(total.low, 2001);
    expect(total.high, 2501);
    expect(total.unknown, 1);
    expect(total.shares(100, 3).reduce((a, b) => a + b), 100);
    expect(
      () => totalCosts(
        [
          costItem(
            'huge',
            'food',
            'Too large',
            'INR',
            low: 999999999999,
            high: 999999999999,
            basis: 'per_person',
            quantity: 10000,
            status: 'manual',
            author: 'a',
          ),
        ],
        50,
        'INR',
      ),
      throwsFormatException,
    );
    expect(budgetState(total, settings()), 'Incomplete estimate');
    expect(
      budgetState(total, {...settings(), 'budget_minor': 2000}),
      'Over budget',
    );
    expect(
      budgetState(total, {
        ...settings(),
        'caps': {'transport': 1100},
      }),
      'transport cap exceeded',
    );
    expect(
      () => totalCosts(
        [
          {...items.first, 'currency': 'USD'},
        ],
        3,
        'INR',
      ),
      throwsFormatException,
    );
    expect(
      () => totalCosts(
        [
          {...items.first, 'high_minor': 99},
        ],
        3,
        'INR',
      ),
      throwsFormatException,
    );
    expect(
      () => totalCosts([items.first, items.first], 3, 'INR'),
      throwsFormatException,
    );
  });
  test(
    'whole route replaces component leg fares, including unknown components',
    () {
      final items = [
        costItem('leg:0', 'transport', 'Unknown leg', 'INR'),
        costItem(
          'leg:1',
          'transport',
          'Known leg',
          'INR',
          low: 100,
          high: 100,
          status: 'manual',
          author: 'a',
        ),
        costItem(
          'route',
          'transport',
          'Whole journey',
          'INR',
          low: 200,
          high: 300,
          status: 'manual',
          author: 'a',
          covers: ['leg:0', 'leg:1'],
        ),
      ];
      final total = totalCosts(items, 3, 'INR');
      expect(total.low, 200);
      expect(total.high, 300);
      expect(total.unknown, 0);
      expect(
        () => totalCosts(
          [
            ...items,
            costItem(
              'duplicate',
              'transport',
              'Overlap',
              'INR',
              covers: ['leg:0'],
            ),
          ],
          3,
          'INR',
        ),
        throwsFormatException,
      );
    },
  );
  test('zone containment, boundaries, limits and self-intersection', () {
    final circle = Zone(settings()['zone']);
    expect(circle.contains([73.8278, 15.4909]), isTrue);
    expect(circle.contains([0, 0]), isFalse);
    final polygon = Zone({
      'type': 'polygon',
      'vertices': [
        [0, 0],
        [0.1, 0],
        [0.1, 0.1],
        [0, 0.1],
      ],
    });
    expect(polygon.contains([0.05, 0.05]), isTrue);
    expect(polygon.contains([0, 0.05]), isTrue);
    expect(polygon.contains([0.2, 0.2]), isFalse);
    expect(
      () => Zone({
        'type': 'circle',
        'center': [0, 0],
        'radius_m': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => Zone({
        'type': 'polygon',
        'vertices': [
          [0, 0],
          [0.1, 0.1],
          [0.1, 0],
          [0, 0.1],
        ],
      }),
      throwsFormatException,
    );
    expect(() => coordinate([181, 0]), throwsFormatException);
  });
  test('bounded candidates keep required stops, no false budget certainty, deterministic scores', () async {
    final trip = TripStore(persistence: false);
    addTearDown(trip.dispose);
    await trip.initialize();
    final repo = ExplorerRepository(trip, 'demo-goa');
    final p = await repo.discover(Zone(settings()['zone']), 'all', 'INR');
    for (var i = 0; i < p.length; i++) {
      p[i]['selection_type'] = i == 0 ? 'must_visit' : 'optional';
    }
    var calls = 0;
    Future<List<Json>> route(List<List<double>> points, String mode) {
      calls++;
      return repo.routes(points, mode);
    }

    final candidates = await generateItineraries(settings(), p, [], route);
    expect(candidates.length, 3);
    expect(candidates.first['mode'], 'walk');
    expect(calls, lessThanOrEqualTo(18));
    expect(
      candidates.every(
        (c) => rows(c['stops']).any((s) => s['id'] == p.first['id']),
      ),
      isTrue,
    );
    expect(
      candidates.every((c) => c['budget_state'] == 'Incomplete estimate'),
      isTrue,
    );
    final repeat = await generateItineraries(settings(), p, [], repo.routes);
    expect(candidates.map((c) => c['id']), repeat.map((c) => c['id']));
    expect(candidates.map((c) => c['id']).toSet().length, 3);
    final failures = <String>[];
    expect(
      await generateItineraries(
        settings(),
        p,
        [],
        (_, _) async => throw const FormatException('Rate limited'),
        failures: failures,
      ),
      isEmpty,
    );
    expect(failures, isNotEmpty);
  });
  test(
    'immutable save, idempotency, sharing, member and account isolation',
    () async {
      final trip = TripStore(persistence: false);
      addTearDown(trip.dispose);
      await trip.initialize();
      final repo = ExplorerRepository(trip, 'demo-goa');
      final places = await repo.discover(
        Zone(settings()['zone']),
        'all',
        'INR',
      );
      places.first['selection_type'] = 'must_visit';
      final candidates = await generateItineraries(
        settings(),
        places,
        [],
        repo.routes,
      );
      final snapshot = {
        'schema_version': 1,
        'settings': settings(),
        'places': places,
        'allowances': <Json>[],
        'itineraries': candidates,
        'selected_candidate': 0,
      };
      final id = repo.newId();
      final v1 = await repo.save(id, 'Day out', snapshot, null);
      expect((await repo.save(id, 'Day out', snapshot, null))['id'], id);
      final v2 = await repo.save(repo.newId(), 'Day out edited', snapshot, id);
      expect(v2['version'], 2);
      expect(v1['title'], 'Day out');
      await repo.share(id);
      trip.switchDemoUser('demo-rahul');
      expect(repo.accessible, isFalse);
      await expectLater(repo.versions(), throwsFormatException);
      final member = ExplorerRepository(trip, 'demo-goa');
      expect((await member.versions()).map((v) => v['id']), [id]);
      await expectLater(
        member.save(member.newId(), 'No', snapshot, null),
        throwsFormatException,
      );
      await expectLater(member.share(id), throwsFormatException);
      expect(trip.snapshot.expenses('demo-goa'), isEmpty);
    },
  );
}
