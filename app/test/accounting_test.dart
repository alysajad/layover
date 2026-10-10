import 'package:flutter_test/flutter_test.dart';
import 'package:layover/features/companion/domain/models.dart';

void main() {
  test('money parsing never silently rounds user input', () {
    expect(parseMoney('1,234.56'), 123456);
    for (final bad in ['-1', '0', '1.001', 'abc', 'NaN']) {
      expect(() => parseMoney(bad), throwsFormatException);
    }
  });
  test('all split modes reconcile and ties are stable', () {
    expect(splitAmount(100, {'c': 1, 'b': 1, 'a': 1}), {
      'a': 34,
      'b': 33,
      'c': 33,
    });
    expect(splitAmount(100, {'c': 1, 'b': 1, 'a': 1}, remainderUser: 'c'), {
      'a': 33,
      'b': 33,
      'c': 34,
    });
    expect(splitAmount(1001, {'a': 1, 'b': 2}, mode: SplitMode.weighted), {
      'a': 334,
      'b': 667,
    });
    expect(
      splitAmount(100, {'a': 2500, 'b': 7500}, mode: SplitMode.percentage),
      {'a': 25, 'b': 75},
    );
    expect(
      () => splitAmount(100, {'a': 25, 'b': 50}, mode: SplitMode.exact),
      throwsFormatException,
    );
    expect(
      () => splitAmount(100, {'a': 0}, mode: SplitMode.weighted),
      throwsFormatException,
    );
    expect(
      () => splitAmount(100, {}, mode: SplitMode.equal),
      throwsFormatException,
    );
    for (var amount = 1; amount < 1000; amount += 7) {
      final split = splitAmount(amount, {
        'a': 2,
        'b': 3,
        'c': 7,
      }, mode: SplitMode.weighted);
      expect(split.values.reduce((a, b) => a + b), amount);
    }
  });
  final stay = Expense({
    'id': 'stay',
    'payer_id': 'a',
    'title': 'Villa',
    'amount_minor': 600000,
    'splits': {'a': 200000, 'b': 200000, 'c': 200000},
  });
  Transfer transfer(
    String id,
    String from,
    String to,
    int amount,
    String status,
  ) => Transfer({
    'id': id,
    'sender_id': from,
    'recipient_id': to,
    'amount_minor': amount,
    'status': status,
  });
  test(
    'pot contributions and the eventual booking expense do not double count',
    () {
      final actual = balances(
        [stay],
        [
          transfer('b', 'b', 'a', 200000, 'acknowledged'),
          transfer('c', 'c', 'a', 200000, 'acknowledged'),
        ],
      );
      expect(actual, {'a': 0, 'b': 0, 'c': 0});
      expect(settlements(actual), isEmpty);
    },
  );
  test('pending, disputed and withdrawn transfers never settle debt', () {
    for (final status in ['reported', 'disputed', 'withdrawn']) {
      expect(balances([stay], [transfer('b', 'b', 'a', 200000, status)]), {
        'a': 400000,
        'b': -200000,
        'c': -200000,
      });
    }
  });
  test('refund reverses an advance when the stay is cancelled', () {
    expect(
      balances([], [
        transfer('pay', 'b', 'a', 200000, 'acknowledged'),
        transfer('refund', 'a', 'b', 200000, 'acknowledged'),
      ]),
      {'a': 0, 'b': 0},
    );
  });
  test('correction invalidates old transfer until recipient acknowledges replacement', () {
    expect(
      balances([], [
        transfer('old', 'b', 'a', 200000, 'withdrawn'),
        transfer('new', 'b', 'a', 150000, 'reported'),
      ]),
      isEmpty,
    );
  });
  test('suggested settlements conserve money and clear balances', () {
    final initial = {'a': 700, 'b': -300, 'c': -600, 'd': 200};
    final result = Map.of(initial);
    for (final payment in settlements(initial)) {
      result[payment['sender_id'] as String] =
          result[payment['sender_id']]! + (payment['amount_minor'] as int);
      result[payment['recipient_id'] as String] =
          result[payment['recipient_id']]! - (payment['amount_minor'] as int);
    }
    expect(result.values.every((v) => v == 0), isTrue);
  });
  test('CSV neutralizes formulas and quotes embedded delimiters', () {
    final snapshot = TripSnapshot({
      'expenses': [
        {
          'id': 'x',
          'trip_id': 't',
          'payer_id': 'a',
          'title': '=SUM(1,2)',
          'amount_minor': 100,
          'splits': {'a': 100},
        },
      ],
    });
    expect(expensesCsv(snapshot, 't'), contains('"\'=SUM(1,2)"'));
  });
}
