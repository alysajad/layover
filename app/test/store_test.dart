import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'demo persists edits and isolates financial status from local drafts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = TripStore();
      await first.initialize();
      await first.command('save_entry', {
        'trip_id': 'demo-goa',
        'kind': 'task',
        'title': 'Pack charger',
        'details': {'done': false},
      });
      await first.saveDraft({
        'trip_id': 'demo-goa',
        'title': 'Lunch',
        'amount_minor': 10000,
      });
      expect(first.snapshot.expenses('demo-goa'), isEmpty);
      first.dispose();
      final second = TripStore();
      await second.initialize();
      expect(
        second.snapshot
            .entries('demo-goa', 'task')
            .any((e) => e.title == 'Pack charger'),
        isTrue,
      );
      expect(second.drafts.single['title'], 'Lunch');
      await second.signOut();
      expect(second.snapshot.trips, isEmpty);
      expect(second.drafts, isEmpty);
      second.dispose();
    },
  );
  test('summary cache removes financial records and attachment paths', () {
    final snapshot = TripSnapshot({
      'trips': [],
      'members': [],
      'entries': [
        {
          'kind': 'booking',
          'details': {'attachment': 'secret/file.pdf', 'notes': 'Booking'},
        },
        {
          'kind': 'contact',
          'details': {'phone': '123'},
        },
      ],
      'expenses': [
        {'amount_minor': 100},
      ],
      'transfers': [
        {'amount_minor': 100},
      ],
      'pots': [
        {'target_minor_units': 100},
      ],
    });
    final cached = snapshot.offlineCopy();
    expect(cached.containsKey('expenses'), isFalse);
    expect(cached.containsKey('transfers'), isFalse);
    expect(rows(cached['entries']), hasLength(1));
    expect(rows(cached['entries']).single['details']['attachment'], isNull);
  });
  test('demo recipient acknowledgment clears the full group stay', () async {
    final store = TripStore(persistence: false);
    await store.initialize();
    for (final member in ['demo-asha', 'demo-rahul', 'demo-meera']) {
      store.switchDemoUser(member);
      await store.command('accept_terms', {
        'trip_id': 'demo-goa',
        'version': 1,
      });
    }
    for (final member in ['demo-rahul', 'demo-meera']) {
      store.switchDemoUser(member);
      final t = await store.command('report_transfer', {
        'trip_id': 'demo-goa',
        'pot_id': 'demo-pot',
        'recipient_id': 'demo-asha',
        'amount_minor': 600000,
      });
      expect(
        await store.command('transfer_status', {
          'trip_id': 'demo-goa',
          'id': t!['id'],
          'status': 'acknowledged',
        }),
        isNull,
      );
      store.switchDemoUser('demo-asha');
      await store.command('transfer_status', {
        'trip_id': 'demo-goa',
        'id': t['id'],
        'status': 'acknowledged',
      });
    }
    expect(store.snapshot.pot('demo-goa')!['status'], 'target_reached');
    await store.command('add_expense', {
      'trip_id': 'demo-goa',
      'title': 'Villa',
      'payer_id': 'demo-asha',
      'amount_minor': 1800000,
      'split_mode': 'equal',
      'weights': {'demo-asha': 1, 'demo-rahul': 1, 'demo-meera': 1},
    });
    expect(
      balances(
        store.snapshot.expenses('demo-goa'),
        store.snapshot.transfers('demo-goa'),
      ).values.every((v) => v == 0),
      isTrue,
    );
    store.dispose();
  });
}
