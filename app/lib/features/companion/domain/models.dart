import 'dart:convert';

typedef Json = Map<String, dynamic>;

List<Json> rows(dynamic value) => (value as List? ?? [])
    .map((e) => Map<String, dynamic>.from(e as Map))
    .toList();

class Trip {
  Trip(this.data);
  final Json data;
  String get id => data['id'] as String;
  String get title => data['title'] as String;
  String get destination => data['destination'] as String? ?? '';
  String get organizer => data['organizer_user_id'] as String;
  bool get archived => data['archived_at'] != null;
  String get start => data['start_date'] as String? ?? '';
  String get end => data['end_date'] as String? ?? '';
}

class Member {
  Member(this.data);
  final Json data;
  String get id => data['user_id'] as String;
  String get name => data['display_name'] as String? ?? 'Traveler';
  String get status => data['membership_status'] as String? ?? 'joined';
  bool get active => status == 'joined';
}

class TripEntry {
  TripEntry(this.data);
  final Json data;
  String get id => data['id'] as String;
  String get tripId => data['trip_id'] as String;
  String get kind => data['kind'] as String;
  String get title => data['title'] as String;
  String get author => data['created_by'] as String;
  int get version => data['version'] as int? ?? 1;
  Json get details => Map<String, dynamic>.from(data['details'] as Map? ?? {});
  String text(String key) => details[key]?.toString() ?? '';
  bool get done => details['done'] == true;
}

class Expense {
  Expense(this.data);
  final Json data;
  String get id => data['id'] as String;
  String get payer => data['payer_id'] as String;
  String get title => data['title'] as String;
  int get amount => (data['amount_minor'] as num).toInt();
  bool get voided => data['voided_at'] != null;
  Map<String, int> get splits =>
      Map<String, dynamic>.from(data['splits'] as Map)
          .map((k, v) => MapEntry(k, (v as num).toInt()));
}

class Transfer {
  Transfer(this.data);
  final Json data;
  String get id => data['id'] as String;
  String get sender => data['sender_id'] as String;
  String get recipient => data['recipient_id'] as String;
  int get amount => (data['amount_minor'] as num).toInt();
  String get status => data['status'] as String;
  bool get acknowledged => status == 'acknowledged';
  String? get potId => data['pot_id'] as String?;
}

class TripSnapshot {
  TripSnapshot(this.data);
  final Json data;
  factory TripSnapshot.empty() => TripSnapshot({});
  List<Trip> get trips => rows(data['trips']).map(Trip.new).toList();
  List<Member> members(String trip) =>
      rows(data['members'])
          .where((m) => m['trip_id'] == trip)
          .map(Member.new)
          .toList();
  List<TripEntry> entries(String trip, [String? kind]) => rows(data['entries'])
      .where((e) => e['trip_id'] == trip && (kind == null || e['kind'] == kind))
      .map(TripEntry.new)
      .toList();
  List<Expense> expenses(String trip) =>
      rows(data['expenses'])
          .where((e) => e['trip_id'] == trip)
          .map(Expense.new)
          .toList();
  List<Transfer> transfers(String trip) =>
      rows(data['transfers'])
          .where((e) => e['trip_id'] == trip)
          .map(Transfer.new)
          .toList();
  Json? pot(String trip) =>
      rows(data['pots']).where((p) => p['trip_id'] == trip).firstOrNull;
  List<Json> obligations(String pot) =>
      rows(data['obligations']).where((o) => o['pot_id'] == pot).toList();
  String name(String trip, String user) =>
      members(trip).where((m) => m.id == user).firstOrNull?.name ??
      'Former member';
  List<Json> responses(String entry) =>
      rows(data['responses']).where((v) => v['entry_id'] == entry).toList();

  // Only non-financial summaries are retained for offline reading.
  Json offlineCopy() => {
    'trips': data['trips'],
    'members': data['members'],
    'entries': rows(data['entries'])
        .where(
          (e) => [
            'itinerary',
            'booking',
            'meeting',
            'task',
            'announcement',
          ].contains(e['kind']),
        )
        .map(
          (e) => {
            ...e,
            'details': {
              ...Map<String, dynamic>.from(e['details']),
              'attachment': null,
            },
          },
        )
        .toList(),
    'cached_at': DateTime.now().toUtc().toIso8601String(),
  };
}

enum SplitMode { equal, exact, percentage, weighted }

int parseMoney(String value) {
  final normalized = value.trim().replaceAll(',', '');
  if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(normalized)) {
    throw const FormatException(
      'Enter a positive amount with at most two decimals.',
    );
  }
  final parts = normalized.split('.');
  final amount =
      int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
  if (amount <= 0) {
    throw const FormatException('Amount must be greater than zero.');
  }
  return amount;
}

Map<String, int> splitAmount(
  int amount,
  Map<String, int> weights, {
  SplitMode mode = SplitMode.equal,
  String? remainderUser,
}) {
  if (amount <= 0 || weights.isEmpty || weights.values.any((v) => v < 0)) {
    throw const FormatException('Choose participants and valid shares.');
  }
  final keys = weights.keys.toList()..sort();
  if (mode == SplitMode.exact) {
    if (weights.values.fold(0, (a, b) => a + b) != amount) {
      throw const FormatException('Exact shares must add up to the total.');
    }
    return Map.of(weights);
  }
  final values = mode == SplitMode.equal
      ? {for (final k in keys) k: 1}
      : weights;
  final total = values.values.fold(0, (a, b) => a + b);
  if (total == 0 || (mode == SplitMode.percentage && total != 10000)) {
    throw const FormatException(
      'Percentages must total 100%; weights must be positive.',
    );
  }
  final products = {
    for (final k in keys) k: BigInt.from(amount) * BigInt.from(values[k]!),
  };
  final divisor = BigInt.from(total);
  final result = {for (final k in keys) k: (products[k]! ~/ divisor).toInt()};
  var remainder = amount - result.values.fold<int>(0, (a, b) => a + b);
  if (remainderUser != null && result.containsKey(remainderUser)) {
    result[remainderUser] = result[remainderUser]! + remainder;
  } else {
    // Stable largest-remainder allocation, with member ID as the tie-breaker.
    keys.sort((a, b) {
      final compare = (products[b]! % divisor).compareTo(
        products[a]! % divisor,
      );
      return compare == 0 ? a.compareTo(b) : compare;
    });
    for (var i = 0; remainder > 0; i++, remainder--) {
      result[keys[i]] = result[keys[i]]! + 1;
    }
  }
  return result;
}

Map<String, int> balances(List<Expense> expenses, List<Transfer> transfers) {
  final result = <String, int>{};
  void add(String id, int value) =>
      result.update(id, (v) => v + value, ifAbsent: () => value);
  for (final e in expenses.where((e) => !e.voided)) {
    add(e.payer, e.amount);
    e.splits.forEach((id, value) => add(id, -value));
  }
  for (final t in transfers.where((t) => t.acknowledged)) {
    add(t.sender, t.amount);
    add(t.recipient, -t.amount);
  }
  return result;
}

List<Json> settlements(Map<String, int> balance) {
  final remaining = Map<String, int>.of(balance);
  final debtors = remaining.keys.where((k) => remaining[k]! < 0).toList()
    ..sort();
  final creditors = remaining.keys.where((k) => remaining[k]! > 0).toList()
    ..sort();
  final result = <Json>[];
  for (final debtor in debtors) {
    for (final creditor in creditors) {
      final debt = -remaining[debtor]!;
      final credit = remaining[creditor]!;
      final amount = debt < credit ? debt : credit;
      if (amount <= 0) continue;
      result.add({
        'sender_id': debtor,
        'recipient_id': creditor,
        'amount_minor': amount,
      });
      remaining[debtor] = remaining[debtor]! + amount;
      remaining[creditor] = remaining[creditor]! - amount;
    }
  }
  return result;
}

String expensesCsv(TripSnapshot snapshot, String trip) {
  String cell(Object? value) {
    var text = value?.toString() ?? '';
    if (RegExp(r'^[\s]*[=+@\-]').hasMatch(text)) text = "'$text";
    return '"${text.replaceAll('"', '""')}"';
  }

  final lines = <List<Object?>>[
    [
      'Type',
      'Title',
      'From / payer',
      'To / participant',
      'Amount INR',
      'Status',
    ],
    for (final e in snapshot.expenses(trip))
      for (final share in e.splits.entries)
        [
          'Expense',
          e.title,
          snapshot.name(trip, e.payer),
          snapshot.name(trip, share.key),
          (share.value / 100).toStringAsFixed(2),
          e.voided ? 'Voided' : 'Recorded',
        ],
    for (final t in snapshot.transfers(trip))
      [
        'Transfer',
        t.potId == null ? 'Settlement' : 'Pot contribution',
        snapshot.name(trip, t.sender),
        snapshot.name(trip, t.recipient),
        (t.amount / 100).toStringAsFixed(2),
        t.status,
      ],
  ];
  return lines.map((line) => line.map(cell).join(',')).join('\r\n');
}

String encodeSnapshot(TripSnapshot snapshot) => jsonEncode(snapshot.data);
