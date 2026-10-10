import 'dart:convert';
import 'dart:math' as math;

import '../../companion/domain/models.dart';
export '../../companion/domain/models.dart' show Json, rows;

Json copyJson(Json value) => jsonDecode(jsonEncode(value)) as Json;
String checkedNow() => DateTime.now().toUtc().toIso8601String();
const currencies = {'INR': 2, 'USD': 2, 'EUR': 2, 'GBP': 2, 'JPY': 0, 'KWD': 3};
const categories = ['transport', 'admission', 'food', 'fees', 'contingency'];
const costBases = [
  'per_person',
  'per_vehicle',
  'per_group',
  'per_ticket',
  'flat',
];

int readMoney(String input, String currency) {
  final digits = currencies[currency];
  if (digits == null) {
    throw const FormatException('Choose a supported currency.');
  }
  final value = input.trim();
  if (digits == 2 && !RegExp(r'^0(\.0{1,2})?$').hasMatch(value)) {
    return parseMoney(value);
  }
  if (!RegExp(digits == 0 ? r'^\d{1,9}$' : '^\\d{1,9}(\\.\\d{1,$digits})?\$')
      .hasMatch(value)) {
    throw FormatException('Use at most $digits decimal places for $currency.');
  }
  final parts = value.split('.');
  return int.parse(parts[0]) * math.pow(10, digits).toInt() +
      (parts.length == 1 ? 0 : int.parse(parts[1].padRight(digits, '0')));
}

String amountText(int minor, String currency) {
  final digits = currencies[currency]!;
  final factor = math.pow(10, digits).toInt();
  return digits == 0
      ? '$minor'
      : '${minor ~/ factor}.${(minor % factor).toString().padLeft(digits, '0')}';
}

String moneyText(int minor, String currency) =>
    '$currency ${amountText(minor, currency)}';

List<double> coordinate(dynamic value) {
  if (value is! List ||
      value.length != 2 ||
      value.any((v) => v is! num || !v.isFinite)) {
    throw const FormatException('Enter valid longitude and latitude.');
  }
  final p = value.map((v) => (v as num).toDouble()).toList();
  if (p[0].abs() > 180 || p[1].abs() > 85) {
    throw const FormatException('Longitude must be ±180 and latitude ±85.');
  }
  return p;
}

double metres(List<double> a, List<double> b) {
  final lat = (b[1] - a[1]) * math.pi / 180;
  final lon = (b[0] - a[0]) * math.pi / 180;
  final h =
      math.pow(math.sin(lat / 2), 2) +
      math.cos(a[1] * math.pi / 180) *
          math.cos(b[1] * math.pi / 180) *
          math.pow(math.sin(lon / 2), 2);
  return 12742000 * math.asin(math.sqrt(h.clamp(0, 1)));
}

class Zone {
  Zone(Json input) : data = copyJson(input) {
    validate();
  }
  final Json data;
  bool get circle => data['type'] == 'circle';
  List<double> get center => coordinate(data['center']);
  double get radius => (data['radius_m'] as num).toDouble();
  List<List<double>> get vertices =>
      (data['vertices'] as List).map(coordinate).toList();
  void validate() {
    if (circle) {
      center;
      if (data['radius_m'] is! num ||
          !radius.isFinite ||
          radius < 100 ||
          radius > 30000) {
        throw const FormatException(
          'Choose a radius from 100 to 30,000 metres.',
        );
      }
      if (center[1].abs() + radius / 111320 > 85 ||
          center[0].abs() +
                  radius / (111320 * math.cos(center[1] * math.pi / 180)) >
              180) {
        throw const FormatException(
          'Choose an area away from polar regions and the antimeridian.',
        );
      }
      return;
    }
    if (data['type'] != 'polygon' || data['vertices'] is! List) {
      throw const FormatException('Choose a circle or polygon.');
    }
    final p = vertices;
    if (p.length < 3 ||
        p.length > 20 ||
        p.map((v) => v.join(',')).toSet().length != p.length) {
      throw const FormatException('A polygon needs 3–20 distinct vertices.');
    }
    final bounds = bbox;
    if (bounds[2] - bounds[0] > 1 || bounds[3] - bounds[1] > 1) {
      throw const FormatException(
        'Keep the polygon within one degree of latitude/longitude.',
      );
    }
    double cross(List<double> a, List<double> b, List<double> c) =>
        (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    var area = 0.0;
    for (var i = 0; i < p.length; i++) {
      final a = p[i], b = p[(i + 1) % p.length];
      area += a[0] * b[1] - b[0] * a[1];
      for (var j = i + 2; j < p.length; j++) {
        if (i == 0 && j == p.length - 1) continue;
        final c = p[j], d = p[(j + 1) % p.length];
        if (cross(a, b, c) * cross(a, b, d) <= 0 &&
            cross(c, d, a) * cross(c, d, b) <= 0 &&
            math.max(math.min(a[0], b[0]), math.min(c[0], d[0])) <=
                math.min(math.max(a[0], b[0]), math.max(c[0], d[0])) &&
            math.max(math.min(a[1], b[1]), math.min(c[1], d[1])) <=
                math.min(math.max(a[1], b[1]), math.max(c[1], d[1]))) {
          throw const FormatException('Polygon edges must not cross or touch.');
        }
      }
    }
    if (area.abs() < 0.00000001) {
      throw const FormatException('Polygon area is too small.');
    }
  }

  List<double> get bbox {
    final p = vertices;
    return [
      p.map((v) => v[0]).reduce(math.min),
      p.map((v) => v[1]).reduce(math.min),
      p.map((v) => v[0]).reduce(math.max),
      p.map((v) => v[1]).reduce(math.max),
    ];
  }

  bool contains(List<double> point) {
    if (circle) return metres(center, point) <= radius;
    final p = vertices;
    var inside = false;
    for (var i = 0, j = p.length - 1; i < p.length; j = i++) {
      final a = p[i], b = p[j];
      final cross =
          (point[0] - a[0]) * (b[1] - a[1]) - (point[1] - a[1]) * (b[0] - a[0]);
      if (cross.abs() < 1e-10 &&
          point[0] >= math.min(a[0], b[0]) &&
          point[0] <= math.max(a[0], b[0]) &&
          point[1] >= math.min(a[1], b[1]) &&
          point[1] <= math.max(a[1], b[1])) {
        return true;
      }
      if ((a[1] > point[1]) != (b[1] > point[1]) &&
          point[0] < (b[0] - a[0]) * (point[1] - a[1]) / (b[1] - a[1]) + a[0]) {
        inside = !inside;
      }
    }
    return inside;
  }

  Json get geometry {
    final points = circle
        ? List.generate(64, (i) {
            final angle = i * 2 * math.pi / 64;
            return [
              center[0] +
                  radius *
                      math.cos(angle) /
                      (111320 * math.cos(center[1] * math.pi / 180)),
              center[1] + radius * math.sin(angle) / 111320,
            ];
          })
        : vertices;
    return {
      'type': 'Polygon',
      'coordinates': [
        [...points, points.first],
      ],
    };
  }
}

void validateSettings(Json s) {
  if (!currencies.containsKey(s['currency']) ||
      s['budget_minor'] is! int ||
      s['budget_minor'] <= 0 ||
      s['budget_minor'] > 999999999999 ||
      s['group_size'] is! int ||
      s['group_size'] < 1 ||
      s['group_size'] > 50) {
    throw const FormatException('Set a budget and a group size from 1 to 50.');
  }
  final start = DateTime.tryParse('${s['start_at']}'),
      end = DateTime.tryParse('${s['end_at']}');
  if (start == null ||
      end == null ||
      !end.isAfter(start) ||
      end.difference(start) > const Duration(days: 7)) {
    throw const FormatException(
      'Choose a time window of up to seven days, ending after it starts.',
    );
  }
  coordinate(s['origin']);
  if (s['destination'] != null) coordinate(s['destination']);
  Zone(Map<String, dynamic>.from(s['zone'] as Map));
  final caps = Map<String, dynamic>.from(s['caps'] as Map? ?? {});
  if (caps.entries.any(
    (e) => !categories.contains(e.key) || e.value is! int || e.value < 0,
  )) {
    throw const FormatException('Category caps must be nonnegative amounts.');
  }
  final modes = List<String>.from(s['modes'] as List);
  if (modes.isEmpty ||
      modes.length > 3 ||
      modes.any((m) => !['walk', 'bicycle', 'drive'].contains(m))) {
    throw const FormatException('Choose walking, cycling or driving.');
  }
}

Json costItem(
  String id,
  String category,
  String description,
  String currency, {
  int? low,
  int? high,
  String basis = 'per_group',
  int quantity = 1,
  String status = 'unknown',
  String source = 'Not available',
  String? author,
  List<String> covers = const [],
}) => {
  'id': id,
  'category': category,
  'description': description,
  'currency': currency,
  'low_minor': low,
  'high_minor': high,
  'cost_basis': basis,
  'quantity': quantity,
  'estimate_status': status,
  'source': source,
  'checked_at': checkedNow(),
  'confidence': status == 'unknown'
      ? 'unknown'
      : status == 'manual'
      ? 'user_supplied'
      : 'assumption',
  'author': ?author,
  'covers': covers,
};

class CostTotal {
  const CostTotal(this.low, this.high, this.unknown, this.byCategory);
  final int low, high, unknown;
  final Map<String, (int, int)> byCategory;
  String label(String currency) =>
      '${moneyText(low, currency)}${low == high ? '' : ' – ${moneyText(high, currency)}'}${unknown > 0 ? ' + $unknown unknown' : ''}';
  List<int> shares(int amount, int group) => amount == 0
      ? List.filled(group, 0)
      : splitAmount(amount, {
          for (var i = 0; i < group; i++) '$i': 1,
        }).values.toList();
  String perPerson(String currency, int group) {
    final a = shares(low, group).reduce(math.min),
        b = shares(high, group).reduce(math.max);
    return '${moneyText(a, currency)}${a == b ? '' : ' – ${moneyText(b, currency)}'}${unknown > 0 ? ' + unknown costs' : ''}';
  }
}

CostTotal totalCosts(List<Json> items, int group, String currency) {
  if (group < 1 || group > 50) {
    throw const FormatException('Invalid group size.');
  }
  final ids = <String>{};
  final covered = <String>{};
  for (final item in items) {
    if (!ids.add(item['id'] as String)) {
      throw const FormatException('Duplicate cost item.');
    }
    for (final id in List<String>.from(item['covers'] as List? ?? [])) {
      if (!covered.add(id) ||
          id == item['id'] ||
          item['category'] != 'transport' ||
          !id.startsWith('leg:')) {
        throw const FormatException('Overlapping fare coverage.');
      }
    }
  }
  if (covered.any((id) => !ids.contains(id))) {
    throw const FormatException('Whole-route fare references a missing leg.');
  }
  var low = 0, high = 0, unknown = 0;
  final byCategory = <String, (int, int)>{};
  for (final item in items) {
    if (item['currency'] != currency ||
        !costBases.contains(item['cost_basis']) ||
        !categories.contains(item['category']) ||
        item['quantity'] is! int ||
        item['quantity'] < 1 ||
        item['quantity'] > 10000) {
      throw const FormatException(
        'Invalid cost currency, category, basis or quantity.',
      );
    }
    if (covered.contains(item['id'])) continue;
    final a = item['low_minor'], b = item['high_minor'];
    if (a == null || b == null || item['estimate_status'] == 'unknown') {
      unknown++;
      continue;
    }
    if (a is! int || b is! int || a < 0 || b < a || b > 999999999999) {
      throw const FormatException(
        'Use nonnegative cost ranges, with high ≥ low.',
      );
    }
    final multiplier =
        (item['cost_basis'] == 'per_person' ? group : 1) *
        (item['quantity'] as int);
    if (BigInt.from(high) + BigInt.from(b) * BigInt.from(multiplier) >
        BigInt.from(9007199254740991)) {
      throw const FormatException(
        'Total exceeds the supported monetary range.',
      );
    }
    low += a * multiplier;
    high += b * multiplier;
    final category = item['category'] as String;
    final before = byCategory[category] ?? (0, 0);
    byCategory[category] = (
      before.$1 + a * multiplier,
      before.$2 + b * multiplier,
    );
  }
  return CostTotal(low, high, unknown, byCategory);
}

String budgetState(CostTotal total, Json settings) {
  final caps = Map<String, dynamic>.from(settings['caps'] as Map? ?? {});
  final exceeded = caps.keys
      .where((k) => (total.byCategory[k]?.$2 ?? 0) > (caps[k] as int))
      .toList();
  if (total.low > (settings['budget_minor'] as int)) return 'Over budget';
  if (exceeded.isNotEmpty) return '${exceeded.join(', ')} cap exceeded';
  if (total.high > (settings['budget_minor'] as int)) {
    return 'May exceed budget';
  }
  if (total.unknown > 0) return 'Incomplete estimate';
  return 'Within budget';
}

typedef RouteLookup = Future<List<Json>> Function(
  List<List<double>> points,
  String mode,
);

// ponytail: six stop sequences, three modes; expand only after coverage/latency measurements.
Future<List<Json>> generateItineraries(
  Json settings,
  List<Json> places,
  List<Json> allowances,
  RouteLookup route, {
  List<String>? failures,
}) async {
  validateSettings(settings);
  final zone = Zone(Map<String, dynamic>.from(settings['zone'] as Map));
  final selected = places
      .where((p) => p['selection_type'] != 'excluded')
      .toList();
  if (selected.isEmpty || selected.length > 12) {
    throw const FormatException('Select 1–12 places.');
  }
  if (selected.any((p) => !zone.contains(coordinate(p['point'])))) {
    throw const FormatException(
      'Selected places must be inside the discovery zone.',
    );
  }
  if (selected.any(
    (p) =>
        p['dwell_minutes'] is! int ||
        p['dwell_minutes'] < 0 ||
        p['dwell_minutes'] > 480,
  )) {
    throw const FormatException('Dwell time must be 0–480 minutes.');
  }
  final required = selected
      .where((p) => p['selection_type'] == 'must_visit')
      .toList();
  if (required.length > 6) {
    throw const FormatException('Choose at most six must-visit places.');
  }
  final optional =
      selected.where((p) => p['selection_type'] == 'optional').toList()..sort(
        (a, b) => (b['priority'] as int).compareTo(a['priority'] as int),
      );
  final origin = coordinate(settings['origin']);
  List<Json> order(List<Json> input) {
    if (settings['keep_order'] == true) {
      return selected.where((p) => input.contains(p)).toList();
    }
    final pool = List<Json>.of(input), result = <Json>[];
    var at = origin;
    while (pool.isNotEmpty) {
      pool.sort((a, b) {
        final c = metres(
          at,
          coordinate(a['point']),
        ).compareTo(metres(at, coordinate(b['point'])));
        return c == 0 ? '${a['id']}'.compareTo('${b['id']}') : c;
      });
      final next = pool.removeAt(0);
      result.add(next);
      at = coordinate(next['point']);
    }
    return result;
  }

  final sequences = <List<Json>>[
    if (required.isNotEmpty) order(required),
    for (final p in optional.take(3)) order([...required, p]),
    for (var n = 2; n <= 3 && n <= optional.length; n++)
      order([...required, ...optional.take(n)]),
  ];
  final unique = <String>{}, candidates = <Json>[];
  final currency = settings['currency'] as String,
      group = settings['group_size'] as int;
  final window = DateTime.parse(settings['end_at'])
      .difference(DateTime.parse(settings['start_at']))
      .inSeconds;
  for (final stops in sequences.take(6)) {
    if (stops.length > 8 || !unique.add(stops.map((s) => s['id']).join('|'))) {
      continue;
    }
    for (final mode in List<String>.from(settings['modes'] as List)) {
      final points = [
        origin,
        ...stops.map((s) => coordinate(s['point'])),
        if (settings['destination'] != null)
          coordinate(settings['destination']),
      ];
      List<Json> routes;
      try {
        routes = await route(points, mode);
      } catch (e) {
        failures?.add('$mode: ${e.toString().replaceFirst('Exception: ', '')}');
        continue;
      }
      final geometries = <String>{};
      for (final r in routes.take(2)) {
        if (!geometries.add(jsonEncode(r['geometry']))) continue;
        final legs = rows(r['legs']);
        if (legs.length != points.length - 1) continue;
        final costs = <Json>[
          ...allowances.map(copyJson),
          for (final stop in stops)
            Map<String, dynamic>.from(stop['cost'] as Map),
          for (var i = 0; i < legs.length; i++)
            costItem(
              'leg:$i',
              'transport',
              '$mode · leg ${i + 1}',
              currency,
              low: mode == 'drive' ? null : 0,
              high: mode == 'drive' ? null : 0,
              status: mode == 'drive' ? 'unknown' : 'model_estimate',
              source: mode == 'drive'
                  ? 'Fare unavailable'
                  : 'Assumes ${mode == 'walk' ? 'walking without paid transfers' : 'your own bicycle'}',
            ),
          if (r['toll'] == true || r['ferry'] == true)
            costItem('route-fees', 'fees', 'Tolls / ferry fees', currency),
        ];
        final total = totalCosts(costs, group, currency);
        final duration =
            legs.fold<int>(0, (n, l) => n + (l['duration_seconds'] as int)) +
            stops.fold<int>(0, (n, s) => n + (s['dwell_minutes'] as int) * 60);
        var direct = 0.0;
        for (var i = 0; i < points.length - 1; i++) {
          direct += metres(points[i], points[i + 1]);
        }
        final distance = legs.fold<double>(
          0,
          (n, l) => n + (l['distance_m'] as num).toDouble(),
        );
        candidates.add({
          'id':
              '${stops.map((s) => s['id']).join('|')}:$mode:${geometries.length}',
          'stops': stops.map(copyJson).toList(),
          'mode': mode,
          'legs': legs,
          'geometry': r['geometry'],
          'path_kind': r['path_kind'] ?? 'balanced',
          'alternative_unavailable': r['alternative_unavailable'] == true,
          'provider': r['provider'],
          'checked_at': r['checked_at'],
          'costs': costs,
          'duration_seconds': duration,
          'distance_m': distance,
          'backtracking_m': math.max(0, distance - direct),
          'total_low_minor': total.low,
          'total_high_minor': total.high,
          'unknown_count': total.unknown,
          'budget_state': budgetState(total, settings),
          'within_time': duration <= window,
          'generated_at': checkedNow(),
          'assumptions_version': 1,
        });
      }
    }
  }
  // Feasible, fully priced options sort before uncertain or infeasible options.
  int penalty(Json c) =>
      (c['within_time'] == true ? 0 : 4) +
      (c['budget_state'] == 'Within budget'
          ? 0
          : c['budget_state'] == 'Incomplete estimate'
          ? 1
          : 2);
  final result = <Json>[];
  final chosen = <String>{};
  for (final archetype in ['Budget-first', 'Time-first', 'Explore-more']) {
    final sorted = List<Json>.of(candidates)
      ..sort((a, b) {
        var c = penalty(a).compareTo(penalty(b));
        if (c != 0) return c;
        if (archetype == 'Budget-first') {
          c = (a['unknown_count'] as int).compareTo(b['unknown_count'] as int);
          if (c != 0) return c;
        }
        if (archetype == 'Explore-more') {
          int relevance(Json p) =>
              rows(p['stops'])
                  .fold<int>(0, (v, s) => v + 10 + (s['priority'] as int)) +
              rows(p['stops']).map((s) => s['category']).toSet().length * 5;
          c = relevance(b).compareTo(relevance(a));
        } else {
          final key = archetype == 'Time-first'
              ? 'duration_seconds'
              : 'total_high_minor';
          c = (a[key] as int).compareTo(b[key] as int);
        }
        if (c != 0) return c;
        c = (a['duration_seconds'] as int).compareTo(
          b['duration_seconds'] as int,
        );
        if (c != 0) return c;
        c = (a['backtracking_m'] as num).compareTo(b['backtracking_m'] as num);
        return c != 0 ? c : '${a['id']}'.compareTo('${b['id']}');
      });
    final best = sorted
        .where(
          (c) => !chosen.contains(
            '${rows(c['stops']).map((p) => p['id']).join('|')}:${c['mode']}',
          ),
        )
        .firstOrNull;
    if (best == null) continue;
    chosen.add(
      '${rows(best['stops']).map((p) => p['id']).join('|')}:${best['mode']}',
    );
    result.add({
      ...best,
      'archetype': archetype,
      'route_alternatives': [
        for (final c in candidates)
          if (c['id'] != best['id'] &&
              c['mode'] == best['mode'] &&
              rows(c['stops']).map((p) => p['id']).join('|') ==
                  rows(best['stops']).map((p) => p['id']).join('|'))
            c,
      ],
    });
  }
  return result;
}
