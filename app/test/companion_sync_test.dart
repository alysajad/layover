import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:layover/features/companion/data/trip_store.dart';
import 'package:layover/features/companion/domain/models.dart';

class MockClient extends Mock implements SupabaseClient {}

class MockAuth extends Mock implements GoTrueClient {}

class RpcResponse extends Fake implements PostgrestFilterBuilder<dynamic> {
  RpcResponse(this.response);
  final Future<dynamic> response;
  @override
  Future<dynamic> timeout(
    Duration timeLimit, {
    FutureOr<dynamic> Function()? onTimeout,
  }) => response.timeout(timeLimit, onTimeout: onTimeout);
}

class SyncFixture {
  final client = MockClient();
  final auth = MockAuth();
  final events = StreamController<AuthState>.broadcast(sync: true);
  User? user = account('alice');
  late final TripStore store;
  int reads = 0, writes = 0;
  String title = 'Trip before edit';
  Future<Json> Function()? read;
  Future<Json> Function(Json)? write;
  final requests = <Json>[];
  static User account(String id) => User(
    id: id,
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
  );
  Json snapshot([String? name]) => {
    'trips': [
      {
        'id': 'trip-${user?.id}',
        'title': name ?? title,
        'organizer_user_id': user?.id,
      },
    ],
    'members': [],
    'profile': {'id': user?.id},
  };
  SyncFixture() {
    when(() => client.auth).thenReturn(auth);
    when(() => auth.currentUser).thenAnswer((_) => user);
    when(() => auth.currentSession).thenAnswer(
      (_) => user == null
          ? null
          : Session(accessToken: 'test', tokenType: 'bearer', user: user!),
    );
    when(() => auth.onAuthStateChange).thenAnswer((_) => events.stream);
    when(() => auth.signOut(scope: SignOutScope.local)).thenAnswer((_) async {
      switchAccount(null);
    });
    when(() => client.rpc<dynamic>(any(), params: any(named: 'params')))
        .thenAnswer((call) {
          if (call.positionalArguments.first == 'companion_snapshot') {
            reads++;
            return RpcResponse(read?.call() ?? Future.value(snapshot()));
          }
          writes++;
          final params = Map<String, dynamic>.from(
            call.namedArguments[#params] as Map,
          );
          requests.add(params);
          return RpcResponse(
            write?.call(params) ?? Future.value(<String, dynamic>{}),
          );
        });
    store = TripStore(client: client, persistence: true);
  }
  void switchAccount(String? id) {
    user = id == null ? null : account(id);
    events.add(
      AuthState(
        id == null ? AuthChangeEvent.signedOut : AuthChangeEvent.signedIn,
        user == null
            ? null
            : Session(accessToken: 'test', tokenType: 'bearer', user: user!),
      ),
    );
  }

  Future<void> dispose() async {
    store.dispose();
    await events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('silent refreshes coalesce and a committed mutation always fetches new data', () async {
    final f = SyncFixture();
    addTearDown(f.dispose);
    await f.store.initialize();
    final pending = Completer<Json>();
    final old = f.snapshot();
    f.read = () => pending.future;
    final first = f.store.refresh(silent: true);
    final second = f.store.refresh(silent: true);
    expect(f.reads, 2);
    f.write = (_) async {
      f.title = 'Committed edit';
      return {};
    };
    final command = f.store.command('update_trip', {'trip_id': 'trip-alice'});
    await Future<void>.delayed(Duration.zero);
    expect(f.writes, 0);
    f.read = null;
    pending.complete(old);
    await Future.wait([first, second, command]);
    expect(f.store.trip!.title, 'Committed edit');
    expect(f.reads, 3);
    expect(f.writes, 1);
    expect(f.store.lastSyncedAt, isNotNull);
  });

  test(
    'old snapshots and commands cannot overwrite a different account',
    () async {
      final f = SyncFixture();
      addTearDown(f.dispose);
      await f.store.initialize();
      final old = f.snapshot();
      final pending = Completer<Json>();
      f.read = () => pending.future;
      final poll = f.store.refresh(silent: true);
      f.read = null;
      f.switchAccount('bob');
      await Future<void>.delayed(Duration.zero);
      pending.complete(old);
      await poll;
      expect(f.store.trip!.id, 'trip-bob');
      final write = Completer<Json>();
      f.write = (_) => write.future;
      final request = f.store.command('create_trip', {'title': 'Bob trip'});
      await Future<void>.delayed(Duration.zero);
      f.switchAccount('alice');
      await Future<void>.delayed(Duration.zero);
      write.complete({'trip_id': 'trip-bob'});
      expect(await request, isNull);
      expect(f.store.trip!.id, 'trip-alice');
      expect(f.store.canRetry, false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('layover.pending.bob'), isNotNull);
      expect(prefs.getString('layover.pending.alice'), isNull);
    },
  );

  test(
    'uncertain writes retry the same request once and stay account-bound',
    () async {
      final f = SyncFixture();
      addTearDown(f.dispose);
      await f.store.initialize();
      f.write = (_) => Future.error(TimeoutException('lost reply'));
      expect(await f.store.command('add_expense', {'title': 'Dinner'}), isNull);
      expect(f.store.canRetry, true);
      final id = f.requests.single['p_request_id'];
      await f.store.command('comment', {'body': 'blocked'});
      expect(f.writes, 1);
      f.write = (_) async => {};
      await f.store.retry();
      expect(f.requests.last['p_request_id'], id);
      expect(f.store.canRetry, false);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'layover.pending.alice',
        ),
        isNull,
      );
    },
  );

  test('offline state strips financial data and authorization denial clears summaries', () async {
    final f = SyncFixture();
    addTearDown(f.dispose);
    f.read = () async => {
      ...f.snapshot(),
      'expenses': [
        {'id': 'private-money'},
      ],
    };
    await f.store.initialize();
    f.read = () => Future.error(TimeoutException('offline'));
    await f.store.refresh();
    expect(f.store.offline, true);
    expect(f.store.trip, isNotNull);
    expect(f.store.snapshot.data['expenses'], isNull);
    f.read = () => Future.error(
      const PostgrestException(message: 'Denied', code: '42501'),
    );
    await f.store.refresh();
    expect(f.store.snapshot.trips, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'layover.summary.alice',
      ),
      isNull,
    );
  });

  testWidgets(
    'foreground polling updates automatically, pauses and resumes without overlap',
    (tester) async {
      final f = SyncFixture();
      addTearDown(f.dispose);
      await f.store.initialize();
      f.title = 'Other member changed this';
      await tester.pump(const Duration(seconds: 5));
      expect(f.store.trip!.title, f.title);
      final reads = f.reads;
      f.store.setForeground(false);
      await tester.pump(const Duration(seconds: 30));
      expect(f.reads, reads);
      f.store.setForeground(true);
      await tester.pump();
      expect(f.reads, reads + 1);
      final pending = Completer<Json>();
      f.read = () => pending.future;
      await tester.pump(const Duration(seconds: 5));
      final during = f.reads;
      unawaited(f.store.refresh(silent: true));
      await tester.pump(const Duration(seconds: 10));
      expect(f.reads, during);
      pending.complete(f.snapshot());
      await tester.pump();
      f.store.setForeground(false);
    },
  );
}
