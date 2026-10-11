import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:layover/features/trip_explorer/domain/area_drawing.dart';
import 'package:layover/features/trip_explorer/domain/explorer.dart';
import 'package:layover/features/trip_explorer/presentation/explorer_map.dart';
import 'package:layover/features/trip_explorer/presentation/explorer_forms.dart';

void main() {
  final settings = <String, dynamic>{
    'currency': 'INR',
    'budget_minor': 100000,
    'group_size': 2,
    'start_at': '2026-10-11T09:00:00Z',
    'end_at': '2026-10-11T17:00:00Z',
    'origin': [73.0, 15.0],
    'destination': null,
    'zone': {
      'type': 'circle',
      'center': [73.0, 15.0],
      'radius_m': 5000,
    },
    'caps': <String, dynamic>{},
    'modes': ['walk'],
  };
  test('circle uses drag distance and rejects accidental taps', () {
    final z = Zone(
      drawnZone('circle', [
        [73, 15],
        [73.01, 15],
      ]),
    );
    expect(z.contains([73.005, 15]), true);
    expect(z.contains([73.02, 15]), false);
    expect(
      () => drawnZone('circle', [
        [73, 15],
        [73.00001, 15],
      ]),
      throwsFormatException,
    );
  });
  test('dense freehand outline is bounded and preserves a concave region', () {
    final corners = [
      [73.0, 15.0],
      [73.04, 15.0],
      [73.04, 15.04],
      [73.02, 15.02],
      [73.0, 15.04],
      [73.0, 15.0],
    ];
    final stroke = <List<double>>[];
    for (var i = 0; i < corners.length - 1; i++) {
      for (var j = 0; j < 50; j++) {
        stroke.add([
          for (var k = 0; k < 2; k++)
            corners[i][k] + (corners[i + 1][k] - corners[i][k]) * j / 50,
        ]);
      }
    }
    final z = Zone(drawnZone('freehand', stroke));
    expect(z.vertices.length, lessThanOrEqualTo(20));
    expect(z.contains([73.02, 15.01]), true);
    expect(z.contains([73.02, 15.035]), false);
    final circle = List.generate(
      300,
      (i) => [
        73 + math.cos(i / 300 * 2 * math.pi) * .01,
        15 + math.sin(i / 300 * 2 * math.pi) * .01,
      ],
    );
    expect(
      Zone(drawnZone('freehand', circle)).vertices.length,
      lessThanOrEqualTo(20),
    );
    expect(
      () => drawnZone('freehand', [
        [73, 15],
        [73.02, 15.02],
        [73, 15.02],
        [73.02, 15],
      ]),
      throwsFormatException,
    );
  });
  test(
    'suggestions reserve allowances, multiply group fees and exclude services',
    () {
      Json place(String id, int? price, {String kind = 'culture'}) => {
        'id': id,
        'kind': kind,
        'point': [73.001, 15.001],
        'cost': costItem(
          id,
          'admission',
          id,
          'INR',
          low: price,
          high: price,
          basis: 'per_person',
          status: price == null ? 'unknown' : 'published_tariff',
        ),
      };
      final allowance = costItem(
        'meal',
        'food',
        'Lunch',
        'INR',
        low: 60000,
        high: 60000,
        status: 'manual',
      );
      final places = [
        place('expensive', 30000),
        place('free', 0),
        place('museum', 20000),
        place('bus', 0, kind: 'transport'),
        place('unknown', null),
      ];
      expect(suggestStops(settings, places, [allowance]), ['free', 'museum']);
      expect(
        suggestStops(
          {
            ...settings,
            'caps': {'admission': 10000},
          },
          places,
          [allowance],
        ),
        ['free', 'unknown'],
      );
      expect(
        budgetState(totalCosts([places.last['cost']], 2, 'INR'), settings),
        'Incomplete estimate',
      );
    },
  );
  testWidgets('drawing a circle commits an area with no coordinate entry', (
    tester,
  ) async {
    Json? drawn;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 360,
            child: ExplorerMap(
              zone: settings['zone'],
              places: const [],
              origin: const [73, 15],
              onPoint: null,
              demo: true,
              drawMode: 'circle',
              onZone: (z) => drawn = z,
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(180, 180));
    await gesture.moveTo(const Offset(240, 180));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(drawn?['type'], 'circle');
    expect(drawn?['radius_m'], greaterThan(100));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'budget form uses date pickers and preserves the drawn boundary',
    (tester) async {
      Json? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await settingsForm(
                    context,
                    settings,
                    currencyLocked: false,
                  );
                },
                child: const Text('Settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.textContaining('longitude'), findsNothing);
      expect(find.textContaining('latitude'), findsNothing);
      expect(find.text('Travelers'), findsOneWidget);
      await tester.ensureVisible(find.text('Apply'));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(saved?['zone'], settings['zone']);
      expect(saved?['origin'], settings['origin']);
    },
  );
}
