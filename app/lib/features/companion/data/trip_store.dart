import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/env.dart';
import '../domain/models.dart';

const uuid = Uuid();

class TripStore extends ChangeNotifier {
  TripStore({
    this.client,
    this.persistence = true,
    this.syncInterval = const Duration(seconds: 5),
  });
  final Duration syncInterval;
  final SupabaseClient? client;
  final bool persistence;
  TripSnapshot snapshot = TripSnapshot.empty();
  bool loading = false;
  bool busy = false;
  bool offline = false;
  bool demo = false;
  String? error;
  String? authError;
  String? selectedTrip;
  String demoUser = 'demo-asha';
  List<Json> drafts = [];
  SharedPreferences? _prefs;
  StreamSubscription<AuthState>? _auth;
  Timer? _refreshTimer;
  bool _disposed = false;
  Json? _retry;
  Future<void>? _refreshFuture;
  String? _accountId;
  int _epoch = 0;
  int _syncFailures = 0;
  bool _foreground = true;
  bool _initialized = false;
  DateTime? lastSyncedAt;

  String get userId => demo ? demoUser : client?.auth.currentUser?.id ?? '';
  bool get signedIn => demo || client?.auth.currentUser != null;
  bool get configured => client != null;
  Trip? get trip =>
      snapshot.trips.where((t) => t.id == selectedTrip).firstOrNull;
  bool get organizer => trip?.organizer == userId;
  String get _cacheKey => 'layover.summary.$userId';
  String get _draftKey => 'layover.drafts.$userId';
  List<Member> get members =>
      selectedTrip == null ? [] : snapshot.members(selectedTrip!);

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (persistence) _prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    if (client == null) {
      await startDemo();
      return;
    }
    _accountId = client!.auth.currentUser?.id;
    _auth = client!.auth.onAuthStateChange.listen(
      (event) {
        final id = client!.auth.currentUser?.id;
        if (id != _accountId || event.event == AuthChangeEvent.signedOut) {
          _clearAccount();
          _accountId = id;
          demo = false;
        }
        authError = null;
        _notify();
        if (!demo && signedIn) unawaited(refresh());
      },
      onError: (Object _) {
        authError = 'Sign-in could not be completed. Please try again.';
        _notify();
      },
    );
    await refresh();
  }

  void _clearAccount() {
    _epoch++;
    _refreshTimer?.cancel();
    _refreshFuture = null;
    snapshot = TripSnapshot.empty();
    selectedTrip = null;
    drafts = [];
    _retry = null;
    busy = false;
    loading = false;
    offline = false;
    error = null;
    authError = null;
    lastSyncedAt = null;
    _syncFailures = 0;
  }

  bool _current(int epoch, String user) =>
      !_disposed && _epoch == epoch && userId == user;

  void _scheduleSync() {
    _refreshTimer?.cancel();
    if (_disposed || !_foreground || demo || !signedIn || client == null) {
      return;
    }
    final multiplier = 1 << _syncFailures.clamp(0, 4);
    final delay = Duration(
      milliseconds: (syncInterval.inMilliseconds * multiplier).clamp(1, 60000),
    );
    _refreshTimer = Timer(delay, () => unawaited(refresh(silent: true)));
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _refreshTimer?.cancel();
    } else {
      unawaited(refresh(silent: true));
    }
  }

  Future<void> startDemo() async {
    _clearAccount();
    demo = true;
    final saved = _prefs?.getString('layover.demo.v2');
    try {
      snapshot = saved == null
          ? demoSnapshot()
          : TripSnapshot(jsonDecode(saved) as Json);
    } catch (_) {
      snapshot = demoSnapshot();
    }
    selectedTrip = snapshot.trips.firstOrNull?.id;
    error = null;
    offline = false;
    _loadDrafts();
    _notify();
  }

  Future<void> resetDemo() async {
    snapshot = demoSnapshot();
    demoUser = 'demo-asha';
    selectedTrip = 'demo-goa';
    await _prefs?.setString('layover.demo.v2', encodeSnapshot(snapshot));
    _notify();
  }

  void selectTrip(String id) {
    if (!snapshot.trips.any((t) => t.id == id)) return;
    selectedTrip = id;
    _notify();
    unawaited(refresh(silent: true));
  }

  void switchDemoUser(String id) {
    demoUser = id;
    _loadDrafts();
    _notify();
  }

  Future<void> signInWithGoogle() async {
    if (client == null) {
      throw const FormatException('Sign-in is not configured for this build.');
    }
    authError = null;
    _notify();
    final opened = await client!.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: Env.authRedirect(webUri: kIsWeb ? Uri.base : null),
      authScreenLaunchMode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
      queryParams: {'prompt': 'select_account'},
    );
    if (!opened) {
      throw const FormatException('Could not open Google sign-in. Try again.');
    }
  }

  Future<void> sendOtp(String email) async {
    await client!.auth.signInWithOtp(email: email.trim());
  }

  Future<void> verifyOtp(String email, String token) async {
    await client!.auth.verifyOTP(
      email: email.trim(),
      token: token.trim(),
      type: OtpType.email,
    );
    demo = false;
    await refresh();
  }

  Future<void> signOut() async {
    final cacheKey = _cacheKey;
    final draftKey = _draftKey;
    final hadSession = client?.auth.currentSession != null;
    _clearAccount();
    demo = false;
    _notify();
    await _prefs?.remove(cacheKey);
    await _prefs?.remove(draftKey);
    // Local sign-out succeeds without a network connection. The server still
    // authorizes every request; unresolved commands remain bound to this account.
    if (hadSession) await client!.auth.signOut(scope: SignOutScope.local);
    _accountId = null;
  }

  void _loadDrafts() {
    try {
      drafts = rows(jsonDecode(_prefs?.getString(_draftKey) ?? '[]'));
    } catch (_) {
      drafts = [];
    }
  }

  Future<void> refresh({bool silent = false}) {
    if (busy) return _refreshFuture ?? Future<void>.value();
    return _refresh(silent: silent);
  }

  Future<void> _refresh({bool silent = false}) {
    if (demo || !signedIn || _disposed) return Future<void>.value();
    if (_refreshFuture != null) return _refreshFuture!;
    final epoch = _epoch;
    final user = userId;
    final future = _fetchSnapshot(epoch, user, silent);
    _refreshFuture = future;
    return future.whenComplete(() {
      if (_current(epoch, user)) {
        _refreshFuture = null;
        _scheduleSync();
      }
    });
  }

  Future<void> _fetchSnapshot(int epoch, String user, bool silent) async {
    final cacheKey = 'layover.summary.$user';
    final draftKey = 'layover.drafts.$user';
    final pendingKey = 'layover.pending.$user';
    if (_retry == null) {
      final pending = _prefs?.getString(pendingKey);
      if (pending != null) {
        try {
          _retry = Map<String, dynamic>.from(jsonDecode(pending) as Map);
        } catch (_) {
          await _prefs?.remove(pendingKey);
        }
      }
    }
    if (!_current(epoch, user)) return;
    if (!silent) loading = true;
    _notify();
    try {
      final data = await client!
          .rpc('companion_snapshot')
          .timeout(const Duration(seconds: 20));
      if (!_current(epoch, user)) return;
      snapshot = TripSnapshot(Map<String, dynamic>.from(data as Map));
      offline = false;
      lastSyncedAt = DateTime.now();
      _syncFailures = 0;
      error = _retry == null ? null : 'An earlier request needs confirmation. Retry it before making another change.';
      selectedTrip = snapshot.trips.any((t) => t.id == selectedTrip)
          ? selectedTrip
          : snapshot.trips.firstOrNull?.id;
      _loadDrafts();
      final ids = snapshot.trips.map((t) => t.id).toSet();
      drafts.removeWhere((d) => !ids.contains(d['trip_id']));
      await _prefs?.setString(draftKey, jsonEncode(drafts));
      if (!_current(epoch, user)) return;
      await _prefs?.setString(cacheKey, jsonEncode(snapshot.offlineCopy()));
    } catch (e) {
      if (!_current(epoch, user)) return;
      _syncFailures++;
      final denied =
          e is AuthException ||
          (e is PostgrestException &&
              ['42501', 'PGRST301', 'PGRST302'].contains(e.code));
      snapshot = TripSnapshot.empty();
      if (denied) {
        await _prefs?.remove(cacheKey);
      } else {
        final cached = _prefs?.getString(cacheKey);
        if (cached != null) {
          try {
            snapshot = TripSnapshot(jsonDecode(cached) as Json);
          } catch (_) {
            await _prefs?.remove(cacheKey);
          }
        }
      }
      if (!_current(epoch, user)) return;
      offline = true;
      selectedTrip = snapshot.trips.any((t) => t.id == selectedTrip)
          ? selectedTrip
          : snapshot.trips.firstOrNull?.id;
      error = friendlyError(e);
      _loadDrafts();
    } finally {
      if (_current(epoch, user)) {
        loading = false;
        _notify();
      }
    }
  }

  Future<Json?> command(String action, Json data, {String? requestId}) async {
    if (busy || _disposed) return null;
    if (!signedIn) {
      error = 'Sign in before changing shared trip data.';
      _notify();
      return null;
    }
    if (!demo && _retry != null && requestId != _retry!['id']) {
      error = 'Retry the unresolved request before making another change.';
      _notify();
      return null;
    }
    if (offline) {
      error = 'Reconnect before changing shared trip data.';
      _notify();
      return null;
    }
    final epoch = _epoch;
    final user = userId;
    final isDemo = demo;
    final pendingKey = 'layover.pending.$user';
    final id = requestId ?? uuid.v4();
    // Capture nested form data before any await or user/account change.
    final payload = jsonDecode(jsonEncode(data)) as Json;
    busy = true;
    error = null;
    _refreshTimer?.cancel();
    _notify();
    try {
      // Finish any poll before mutation, then fetch a snapshot after the commit.
      await _refreshFuture;
      if (!_current(epoch, user)) return null;
      final Json result;
      if (isDemo) {
        final before = encodeSnapshot(snapshot);
        try {
          result = _demoCommand(action, payload);
        } catch (_) {
          snapshot = TripSnapshot(jsonDecode(before) as Json);
          rethrow;
        }
        await _prefs?.setString('layover.demo.v2', encodeSnapshot(snapshot));
      } else {
        final attempt = {'action': action, 'data': payload, 'id': id};
        await _prefs?.setString(pendingKey, jsonEncode(attempt));
        if (!_current(epoch, user)) return null;
        final response = await client!
            .rpc(
              'companion_command',
              params: {
                'p_action': action,
                'p_data': payload,
                'p_request_id': id,
              },
            )
            .timeout(const Duration(seconds: 25));
        if (!_current(epoch, user)) return null;
        result = Map<String, dynamic>.from(response as Map);
        _retry = null;
        await _prefs?.remove(pendingKey);
        if (!_current(epoch, user)) return null;
        await _refresh();
      }
      if (!_current(epoch, user)) return null;
      _retry = null;
      if (result['trip_id'] case final String tripId) {
        if (snapshot.trips.any((t) => t.id == tripId)) selectedTrip = tripId;
      }
      return result;
    } catch (e) {
      if (!_current(epoch, user)) return null;
      error = friendlyError(e);
      if (!isDemo &&
          e is! PostgrestException &&
          e is! FormatException &&
          e is! AuthException) {
        _retry = {'action': action, 'data': payload, 'id': id};
      } else {
        _retry = null;
        await _prefs?.remove(pendingKey);
      }
      return null;
    } finally {
      if (_current(epoch, user)) {
        busy = false;
        _scheduleSync();
        _notify();
      }
    }
  }

  bool get canRetry => _retry != null;
  Future<void> retry() async {
    final attempt = _retry;
    if (attempt == null) {
      await refresh();
      return;
    }
    if (offline) await refresh();
    if (offline) return;
    await command(
      attempt['action'] as String,
      attempt['data'] as Json,
      requestId: attempt['id'] as String,
    );
  }

  Future<void> saveDraft(Json data) async {
    drafts.add({...data, 'draft_id': uuid.v4()});
    await _prefs?.setString(_draftKey, jsonEncode(drafts));
    _notify();
  }

  Future<void> removeDraft(String id) async {
    drafts.removeWhere((d) => d['draft_id'] == id);
    await _prefs?.setString(_draftKey, jsonEncode(drafts));
    _notify();
  }

  Future<void> submitDraft(Json draft) async {
    final payload = {...draft}..remove('draft_id');
    final result = await command(
      'add_expense',
      payload,
      requestId: draft['draft_id'] as String,
    );
    if (result != null) await removeDraft(draft['draft_id'] as String);
  }

  Future<String> upload(String tripId, String filename, Uint8List bytes) async {
    if (offline || demo) {
      throw const FormatException('Attachments require a connected account.');
    }
    if (bytes.length > 10 * 1024 * 1024) {
      throw const FormatException('Maximum file size is 10 MB.');
    }
    final extension = filename.split('.').last.toLowerCase();
    final mime = {
      'pdf': 'application/pdf',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
    }[extension];
    if (mime == null) {
      throw const FormatException('Choose a PDF, PNG, or JPEG.');
    }
    final path = '$tripId/$userId/${uuid.v4()}.$extension';
    await client!.storage
        .from('trip-files')
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));
    return path;
  }

  Future<String> attachmentUrl(String path) async =>
      client!.storage.from('trip-files').createSignedUrl(path, 60);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _auth?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Json _demoCommand(String action, Json data) {
    final d = snapshot.data;
    List<Json> list(String key) {
      final result = rows(d[key]);
      d[key] = result;
      return result;
    }

    final tid = data['trip_id'] as String?;
    final current = snapshot.trips.where((t) => t.id == tid).firstOrNull;
    final owner = current?.organizer;
    final now = DateTime.now().toUtc().toIso8601String();
    var result = <String, dynamic>{};
    void require(bool value, String message) {
      if (!value) throw FormatException(message);
    }

    void onlyOwner() =>
        require(owner == userId, 'Only the organizer can do this.');
    if (tid != null) {
      require(
        snapshot.members(tid).any((m) => m.id == userId && m.active),
        'Trip access denied.',
      );
      require(
        current?.archived != true || action == 'archive_trip',
        'Trip is archived.',
      );
    }
    if (action == 'create_trip' || action == 'duplicate_trip') {
      final id = uuid.v4();
      list('trips').insert(0, {
        'id': id,
        'title': data['title'],
        'destination': data['destination'],
        'start_date': data['start_date'],
        'end_date': data['end_date'],
        'organizer_user_id': userId,
      });
      list('members').add({
        'trip_id': id,
        'user_id': userId,
        'display_name': demoUser == 'demo-asha' ? 'Asha' : 'You',
        'membership_status': 'joined',
      });
      if (action == 'duplicate_trip') {
        final copied = snapshot
            .entries(data['source_id'] as String)
            .where((e) => ['itinerary', 'task'].contains(e.kind))
            .map((e) {
              final details = {...e.details}
                ..remove('date')
                ..remove('time')
                ..remove('assigned_to')
                ..remove('attachment');
              details.remove('remind_at');
              return {
                ...e.data,
                'id': uuid.v4(),
                'trip_id': id,
                'created_by': userId,
                'details': {...details, 'done': false},
                'version': 1,
              };
            })
            .toList();
        list('entries').addAll(copied);
      }
      result = {'trip_id': id};
    } else if (action == 'update_trip') {
      onlyOwner();
      final trip = list('trips').firstWhere((t) => t['id'] == tid);
      for (final key in ['title', 'destination', 'start_date', 'end_date']) {
        trip[key] = data[key];
      }
      trip['updated_at'] = now;
    } else if (action == 'profile') {
      d['profile'] = {...?d['profile'] as Json?, ...data};
    } else if (action == 'save_entry') {
      final entries = list('entries');
      final index = entries.indexWhere((e) => e['id'] == data['id']);
      if (index >= 0) {
        require(
          entries[index]['created_by'] == userId || owner == userId,
          'Entry access denied.',
        );
        require(
          entries[index]['version'] == data['version'],
          'Entry changed. Refresh first.',
        );
      }
      final id = data['id'] as String? ?? uuid.v4();
      final entry = {
        ...data,
        'id': id,
        'created_by': index < 0 ? userId : entries[index]['created_by'],
        'version': index < 0 ? 1 : (entries[index]['version'] as int) + 1,
      };
      if (index < 0) {
        entries.add(entry);
      } else {
        entries[index] = entry;
      }
      result = {'id': id};
    } else if ([
      'delete_entry',
      'toggle_task',
      'respond',
      'comment',
      'choose_entry',
    ].contains(action)) {
      final entries = list('entries');
      final e = entries.firstWhere((e) => e['id'] == data['id']);
      final details = Map<String, dynamic>.from(e['details'] as Map);
      if (action == 'delete_entry') {
        require(
          e['created_by'] == userId || owner == userId,
          'Entry access denied.',
        );
        entries.remove(e);
      } else if (action == 'toggle_task') {
        require(
          e['created_by'] == userId ||
              owner == userId ||
              details['assigned_to'] == userId,
          'Task access denied.',
        );
        e['details'] = {...details, 'done': data['done']};
        e['version'] = (e['version'] as int) + 1;
      } else if (action == 'respond') {
        require(details['selected'] != true, 'Decision is closed.');
        final responses = list('responses');
        responses.removeWhere(
          (r) => r['entry_id'] == data['id'] && r['user_id'] == userId,
        );
        responses.add({
          'entry_id': data['id'],
          'user_id': userId,
          'response': {
            'choice': data['choice'],
            if (data['choices'] != null) 'choices': data['choices'],
          },
          'updated_at': now,
        });
      } else if (action == 'comment') {
        list('comments').add({
          'id': uuid.v4(),
          'entry_id': data['id'],
          'user_id': userId,
          'body': data['body'],
          'created_at': now,
        });
      } else {
        onlyOwner();
        e['details'] = {...details, 'selected': true, 'choice': data['choice']};
        e['version'] = (e['version'] as int) + 1;
      }
    } else if (action == 'save_pot' || action == 'add_expense') {
      final amount = data['amount_minor'] as int;
      final weights = Map<String, dynamic>.from(data['weights'] as Map)
          .map((k, v) => MapEntry(k, (v as num).toInt()));
      final shares = splitAmount(
        amount,
        weights,
        mode: SplitMode.values.byName(data['split_mode'] as String),
        remainderUser: action == 'save_pot' ? owner : null,
      );
      if (action == 'save_pot') {
        onlyOwner();
        final pots = list('pots');
        final index = pots.indexWhere((p) => p['trip_id'] == tid);
        final previous = index < 0 ? null : pots[index];
        final id = previous?['id'] ?? uuid.v4();
        final version = (previous?['terms_version'] as int? ?? 0) + 1;
        final pot = {
          'id': id,
          'trip_id': tid,
          'title': data['title'],
          'target_minor_units': amount,
          'organizer_cover_minor': data['organizer_cover_minor'] ?? 0,
          'deadline_at': data['deadline_at'],
          'terms_text': data['terms'],
          'terms_version': version,
          'version': version,
          'status': 'funding',
        };
        if (index < 0) {
          pots.add(pot);
        } else {
          pots[index] = pot;
        }
        final obligations = list('obligations');
        obligations.removeWhere((o) => o['pot_id'] == id);
        shares.forEach(
          (k, v) => obligations.add({
            'pot_id': id,
            'user_id': k,
            'amount_minor_units': v,
            'obligation_status': 'proposed',
            'accepted_terms_version': null,
          }),
        );
      } else {
        final id = uuid.v4();
        list('expenses').insert(0, {
          ...data,
          'id': id,
          'created_by': userId,
          'splits': shares,
          'created_at': now,
        });
        result = {'id': id};
      }
    } else if (action == 'void_expense') {
      final e = list('expenses').firstWhere((e) => e['id'] == data['id']);
      require(
        snapshot.members(tid!).any((m) => m.id == e['payer_id'] && m.active) &&
            Map<String, dynamic>.from(e['splits'] as Map).keys.every(
              (id) => snapshot.members(tid).any((m) => m.id == id && m.active),
            ),
        'Affected former members must rejoin before this expense can be corrected.',
      );
      require(
        e['created_by'] == userId || owner == userId,
        'Expense access denied.',
      );
      e['voided_at'] = now;
    } else if (action == 'accept_terms') {
      final pot = snapshot.pot(tid!)!;
      require(pot['terms_version'] == data['version'], 'Terms have changed.');
      final obligation = list(
        'obligations',
      ).firstWhere((o) => o['pot_id'] == pot['id'] && o['user_id'] == userId);
      obligation['accepted_terms_version'] = data['version'];
      obligation['obligation_status'] = 'accepted';
    } else if (action == 'report_transfer') {
      require(data['recipient_id'] != userId, 'Choose another recipient.');
      require(
        snapshot
            .members(tid!)
            .any((m) => m.id == data['recipient_id'] && m.active),
        'Choose another active trip member.',
      );
      if (data['replaces_id'] != null) {
        final previous = list('transfers')
            .firstWhere((t) => t['id'] == data['replaces_id']);
        require(previous['sender_id'] == userId, 'Only sender can correct.');
        previous['status'] = 'withdrawn';
      }
      final id = uuid.v4();
      list('transfers').insert(0, {
        ...data,
        'id': id,
        'sender_id': userId,
        'status': 'reported',
        'created_at': now,
      });
      result = {'id': id};
    } else if (action == 'transfer_status') {
      final t = list('transfers').firstWhere((e) => e['id'] == data['id']);
      require(
        data['status'] == 'withdrawn'
            ? t['sender_id'] == userId && t['status'] != 'acknowledged'
            : t['recipient_id'] == userId,
        'Only recipient can acknowledge or dispute.',
      );
      t['status'] = data['status'];
    } else if (action == 'pot_outcome') {
      onlyOwner();
      final p = list('pots').firstWhere((p) => p['trip_id'] == tid);
      require(
        data['status'] != 'booked' || p['status'] == 'target_reached',
        'Target and acceptances required.',
      );
      p['status'] = data['status'];
    } else if (action == 'archive_trip') {
      onlyOwner();
      list('trips').firstWhere((t) => t['id'] == tid)['archived_at'] =
          data['archived'] == true ? now : null;
    } else if (action == 'whatsapp') {
      onlyOwner();
      list('trips').firstWhere((t) => t['id'] == tid)['whatsapp_url'] =
          data['url'];
    } else if (action == 'remove_member') {
      require(
        owner == userId || data['user_id'] == userId,
        'Cannot remove member.',
      );
      require(data['user_id'] != owner, 'Organizer cannot leave.');
      final balance = balances(
        snapshot.expenses(tid!),
        snapshot.transfers(tid),
      );
      require(
        (balance[data['user_id']] ?? 0) == 0 &&
            !snapshot
                .transfers(tid)
                .any(
                  (t) =>
                      ['reported', 'disputed'].contains(t.status) &&
                      (t.sender == data['user_id'] ||
                          t.recipient == data['user_id']),
                ),
        'Settle this member and resolve pending transfers before removing access.',
      );
      list('members').firstWhere(
        (m) => m['trip_id'] == tid && m['user_id'] == data['user_id'],
      )['membership_status'] = 'removed';
    } else if (action == 'read_notification') {
      list('notifications')
              .firstWhere((n) => n['id'] == data['id'])['read_at'] =
          now;
    } else if (action == 'invite' || action == 'join_trip') {
      throw const FormatException(
        'Invitations require a connected account. Demo trips stay on this device.',
      );
    }
    if (tid != null) {
      final pots = list('pots');
      final index = pots.indexWhere((p) => p['trip_id'] == tid);
      if (index >= 0 &&
          [
            'open',
            'funding',
            'target_reached',
            'target_missed',
          ].contains(pots[index]['status'])) {
        final p = pots[index];
        final collected = snapshot
            .transfers(tid)
            .where((t) => t.potId == p['id'] && t.acknowledged)
            .fold(
              0,
              (sum, t) => sum + (t.recipient == owner ? t.amount : -t.amount),
            );
        final accepted = snapshot
            .obligations(p['id'] as String)
            .every((o) => o['accepted_terms_version'] == p['terms_version']);
        p['status'] =
            collected + (p['organizer_cover_minor'] as int? ?? 0) >=
                    (p['target_minor_units'] as int) &&
                accepted
            ? 'target_reached'
            : DateTime.parse(p['deadline_at'] as String)
                  .isBefore(DateTime.now())
            ? 'target_missed'
            : 'funding';
      }
      list('activity').insert(0, {
        'id': uuid.v4(),
        'trip_id': tid,
        'actor_id': userId,
        'action': action,
        'detail': action.replaceAll('_', ' '),
        'created_at': now,
      });
    }
    return result;
  }
}

String friendlyError(Object e) {
  if (e is FormatException) return e.message;
  if (e is PostgrestException) {
    return '${e.message} (reference ${e.code ?? 'database'})';
  }
  if (e is AuthException) return e.message;
  if (e is StorageException) return e.message;
  return 'Could not reach Layover. Reconnect and retry; your request will not be counted twice.';
}

TripSnapshot demoSnapshot() {
  final start = DateTime.now().add(const Duration(days: 14));
  final date = start.toIso8601String().substring(0, 10);
  const tid = 'demo-goa';
  Json entry(String id, String kind, String title, Json details) => {
    'id': id,
    'trip_id': tid,
    'kind': kind,
    'title': title,
    'details': details,
    'created_by': 'demo-asha',
    'version': 1,
  };
  return TripSnapshot({
    'trips': [
      {
        'id': tid,
        'title': 'Goa weekend',
        'destination': 'Assagao, Goa',
        'organizer_user_id': 'demo-asha',
        'start_date': date,
        'end_date': start
            .add(const Duration(days: 3))
            .toIso8601String()
            .substring(0, 10),
      },
    ],
    'members': [
      for (final m in [
        ('demo-asha', 'Asha'),
        ('demo-rahul', 'Rahul'),
        ('demo-meera', 'Meera'),
      ])
        {
          'trip_id': tid,
          'user_id': m.$1,
          'display_name': m.$2,
          'membership_status': 'joined',
        },
    ],
    'entries': [
      entry('poll-date', 'poll', 'Which weekend works?', {
        'options': [
          date,
          start.add(const Duration(days: 7)).toIso8601String().substring(0, 10),
        ],
        'poll_type': 'Dates',
      }),
      entry('stay-1', 'shortlist', 'Courtyard villa, Assagao', {
        'notes': 'Three bedrooms, kitchen, and a shared courtyard.',
        'url': 'https://www.airbnb.com/s/Assagao--India/homes',
        'price': '18000',
      }),
      entry('day-1', 'itinerary', 'Meet for breakfast', {
        'date': date,
        'time': '09:30',
        'address': 'Assagao, Goa',
        'notes': 'Leave time for the drive from the station.',
      }),
      entry('task-1', 'task', 'Bring the first-aid kit', {
        'assigned_to': 'demo-meera',
        'done': false,
      }),
      entry('meet-1', 'meeting', 'Station pickup', {
        'address': 'Madgaon Railway Station, Goa',
        'date': date,
        'time': '08:00',
      }),
      entry('note-1', 'announcement', 'Weekend essentials', {
        'notes': 'Confirm your travel dates before we choose the stay.',
      }),
    ],
    'responses': [],
    'comments': [],
    'expenses': [],
    'transfers': [],
    'pots': [
      {
        'id': 'demo-pot',
        'trip_id': tid,
        'title': 'Shared stay',
        'target_minor_units': 1800000,
        'organizer_cover_minor': 600000,
        'deadline_at': start
            .subtract(const Duration(days: 4))
            .toUtc()
            .toIso8601String(),
        'terms_text': 'Transfers go directly to Asha. Booking and any reimbursements are handled by the group. Confirm the cancellation policy before booking.',
        'terms_version': 1,
        'version': 1,
        'status': 'open',
      },
    ],
    'obligations': [
      for (final id in ['demo-asha', 'demo-rahul', 'demo-meera'])
        {
          'pot_id': 'demo-pot',
          'user_id': id,
          'amount_minor_units': 600000,
          'obligation_status': 'proposed',
          'accepted_terms_version': null,
        },
    ],
    'notifications': [],
    'activity': [],
    'invites': [],
    'profile': {'display_name': 'Asha', 'reminders_enabled': true},
  });
}

TripStore createTripStore() =>
    TripStore(client: Env.isConfigured ? Supabase.instance.client : null);
