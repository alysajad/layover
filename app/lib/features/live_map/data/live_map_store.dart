import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../companion/data/trip_store.dart';
import '../domain/models.dart';
import 'device_location.dart';
import 'live_map_api.dart';

class LiveMapStore extends ChangeNotifier {
  LiveMapStore({required this.trip, LiveMapApi? api, DeviceLocation? device})
    : api = api ?? (trip.demo ? DemoLiveMapApi(trip) : LiveMapApi(trip.client)),
      device = device ?? DeviceLocation(),
      _identity = '${trip.demo}:${trip.userId}' {
    trip.addListener(_accountChanged);
    _auth = trip.client?.auth.onAuthStateChange.listen(
      (_) => _accountChanged(),
    );
  }
  final TripStore trip;
  final LiveMapApi api;
  final DeviceLocation device;
  bool get simulated => api.simulated;
  final String _identity;
  List<Json> sessions = [], contacts = [];
  LiveSnapshot? snapshot;
  String? sessionId, error;
  bool sharing = false, busy = false, viewing = false;
  bool _disposed = false, _polling = false, _publishing = false;
  int _epoch = 0,
      _shareEpoch = 0,
      _generation = 0,
      _sequence = 0,
      _failures = 0;
  Timer? _timer, _freshness;
  StreamSubscription<Json>? _fixes;
  StreamSubscription<AuthState>? _auth;
  DateTime? _lastPublish;
  DateTime? _leaseUntil;
  final Stopwatch _snapshotAge = Stopwatch();
  Duration _snapshotLag = Duration.zero;
  DateTime get serverNow => (snapshot?.serverTime ?? DateTime.now().toUtc())
      .add(_snapshotAge.elapsed + _snapshotLag);
  bool get validAccount =>
      _identity == '${trip.demo}:${trip.userId}' && trip.signedIn;
  bool get organizer => snapshot?.session['created_by'] == trip.userId;
  bool get active => snapshot?.session['status'] == 'active';
  List<Json> get visibleLocations =>
      snapshot?.locations
          .where(
            (l) =>
                serverNow
                    .difference(DateTime.parse(l['received_at'] as String))
                    .inSeconds <
                30,
          )
          .toList() ??
      [];
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _valid(int epoch) =>
      !_disposed && validAccount && viewing && epoch == _epoch;

  void _accountChanged() {
    if (!validAccount) {
      ++_epoch;
      _cancelAcquisition();
      _timer?.cancel();
      _freshness?.cancel();
      viewing = false;
      snapshot = null;
      sessions = [];
      contacts = [];
      sessionId = null;
      error = 'Account changed. Reopen Live Map from your account.';
      _notify();
    }
  }

  Future<void> enter([String? id]) async {
    if (!validAccount || _disposed) return;
    final previous = sessionId;
    final wasSharing = sharing;
    _cancelAcquisition();
    if (wasSharing && previous != null) {
      unawaited(_remoteStop(previous, 'pause'));
    }
    ++_epoch;
    viewing = true;
    sessionId = id;
    error = null;
    snapshot = null;
    _failures = 0;
    _freshness?.cancel();
    _freshness = Timer.periodic(const Duration(seconds: 1), (_) {
      if (snapshot != null &&
          !DateTime.parse(snapshot!.session['expires_at'] as String)
              .isAfter(serverNow)) {
        _cancelAcquisition();
        snapshot = null;
        sessionId = null;
        error = 'Session expired. Sharing has stopped.';
      }
      if (sharing &&
          _leaseUntil != null &&
          !DateTime.now().isBefore(_leaseUntil!)) {
        unawaited(stop());
        error = 'Sharing lease expired. Choose Share location to resume.';
      }
      _notify();
    });
    await refresh();
  }

  Future<void> refresh() async {
    if (_polling || !viewing || !validAccount || _disposed) return;
    final epoch = _epoch, id = sessionId;
    final requestAge = Stopwatch()..start();
    _polling = true;
    _timer?.cancel();
    try {
      final data = id == null ? await api.sessions() : await api.snapshot(id);
      if (!_valid(epoch)) return;
      if (id == null) {
        sessions = rows(data['sessions']);
        contacts = rows(data['contacts']);
      } else {
        snapshot = LiveSnapshot(data);
        // Conservatively count the entire round trip toward server freshness.
        _snapshotLag = requestAge.elapsed;
        _snapshotAge
          ..reset()
          ..start();
        final me = snapshot!.members
            .where((m) => m['user_id'] == trip.userId)
            .firstOrNull;
        if (sharing &&
            (me?['sharing_status'] != 'sharing' ||
                me?['generation'] != _generation)) {
          _cancelAcquisition();
          error = 'Sharing paused. Choose Share location to resume.';
        }
      }
      if (_failures > 0) error = null;
      _failures = 0;
    } catch (_) {
      if (!_valid(epoch)) return;
      snapshot = null;
      sessions = [];
      _failures = (_failures + 1).clamp(1, 4);
      final wasSharing = sharing;
      final stopUnconfirmed = error?.contains('30 seconds') ?? false;
      _cancelAcquisition();
      error =
          'Unable to confirm session access. Locations are hidden. ${wasSharing || stopUnconfirmed ? 'Sharing stopped locally; remote visibility expires within 30 seconds of the last accepted fix.' : 'Reconnect or return to sessions.'}';
      if (wasSharing && id != null) unawaited(_remoteStop(id, 'pause'));
    } finally {
      _polling = false;
      if (!_disposed && viewing && validAccount) {
        _timer = Timer(
          Duration(seconds: _failures == 0 ? 3 : 3 * (1 << _failures)),
          refresh,
        );
      }
      _notify();
    }
  }

  Future<Json?> command(String action, Json data) async {
    if (busy || !validAccount || !viewing) return null;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await api.command(action, data);
      if (!_valid(epoch)) return null;
      await refresh();
      return result;
    } catch (e) {
      if (_valid(epoch)) error = friendlyError(e);
      return null;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> share() async {
    if (busy || !active || sessionId == null || !viewing) return;
    final id = sessionId!, epoch = ++_epoch, shareEpoch = ++_shareEpoch;
    busy = true;
    error = null;
    _notify();
    try {
      if (!simulated) await device.requestPermission();
      if (!_valid(epoch) || shareEpoch != _shareEpoch) return;
      final result = await api.command('consent', {
        'session_id': id,
        'consent_version': 'live-map-v1',
      });
      if (!_valid(epoch) || shareEpoch != _shareEpoch) {
        if (validAccount) await _remoteStop(id, 'stop');
        return;
      }
      _generation = result['generation'] as int;
      _sequence = 0;
      _lastPublish = null;
      _leaseUntil = simulated
          ? null
          : DateTime.now().add(const Duration(seconds: 28));
      sharing = true;
      if (!simulated) {
        _fixes = device.fixes().listen(
          (fix) => _publish(fix, epoch, shareEpoch),
          onError: (Object _) {
            unawaited(stop());
            error = 'Location acquisition failed. Check location services and permissions, then share again.';
            _notify();
          },
        );
      }
      await refresh();
    } catch (e) {
      if (_valid(epoch)) {
        _cancelAcquisition();
        error = friendlyError(e);
        unawaited(_remoteStop(id, 'stop'));
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _publish(Json fix, int epoch, int shareEpoch) async {
    if (!_valid(epoch) ||
        shareEpoch != _shareEpoch ||
        !sharing ||
        _publishing) {
      return;
    }
    final now = DateTime.now();
    if (_lastPublish != null &&
        now.difference(_lastPublish!) < const Duration(seconds: 5)) {
      return;
    }
    final timestamp = DateTime.tryParse(
      fix['client_timestamp'] as String? ?? '',
    );
    final accuracy = fix['accuracy_m'] as num?;
    if (timestamp == null ||
        now.difference(timestamp) > const Duration(seconds: 30) ||
        timestamp.difference(now) > const Duration(seconds: 10) ||
        accuracy == null ||
        !accuracy.isFinite ||
        accuracy < 0 ||
        accuracy > 5000) {
      error = 'Waiting for a usable fresh GPS fix. Sharing will pause if no fix arrives.';
      _notify();
      return;
    }
    final id = sessionId!;
    _publishing = true;
    _lastPublish = now;
    try {
      await api.publish(id, _generation, ++_sequence, fix);
      if (_valid(epoch) && shareEpoch == _shareEpoch && sharing) {
        // Throttle from acknowledgment so network jitter cannot violate the server rate.
        _lastPublish = DateTime.now();
        _leaseUntil = now.add(const Duration(seconds: 28));
        error = accuracy > 100
            ? 'Approximate GPS: accuracy is worse than 100 metres.'
            : null;
      }
    } catch (_) {
      if (_valid(epoch) && shareEpoch == _shareEpoch) {
        _cancelAcquisition();
        snapshot = null;
        error = 'Location was not accepted. Sharing stopped locally; remote visibility expires within 30 seconds. Resume explicitly after reconnecting.';
        unawaited(_remoteStop(id, 'stop'));
      }
    } finally {
      _publishing = false;
      _notify();
    }
  }

  void _cancelAcquisition() {
    ++_shareEpoch;
    sharing = false;
    _leaseUntil = null;
    unawaited(_fixes?.cancel());
    _fixes = null;
    if (snapshot != null) {
      snapshot = LiveSnapshot({
        ...snapshot!.data,
        'locations': snapshot!.locations
            .where((l) => l['user_id'] != trip.userId)
            .toList(),
      });
    }
  }

  Future<void> _remoteStop(String id, String action) async {
    try {
      await api.command(action, {'session_id': id});
    } catch (_) {
      if (!_disposed && validAccount) {
        error = 'Stopped on this device. If offline, remote visibility ends within 30 seconds of the last accepted fix.';
        _notify();
      }
    }
  }

  Future<void> stop({bool pause = false}) async {
    ++_epoch; // A pre-stop snapshot must not reintroduce the withdrawn position.
    final id = sessionId;
    _cancelAcquisition();
    _notify();
    if (id != null && validAccount) {
      await _remoteStop(id, pause ? 'pause' : 'stop');
    }
    await refresh();
  }

  Future<void> suspend() async {
    final id = sessionId;
    final shouldPause = sharing || busy;
    ++_epoch;
    viewing = false;
    _timer?.cancel();
    _freshness?.cancel();
    _cancelAcquisition();
    snapshot = null;
    _notify();
    if (shouldPause && id != null && validAccount) {
      await _remoteStop(id, 'pause');
    }
  }

  Future<void> resume() => enter(sessionId);
  @override
  void dispose() {
    unawaited(suspend());
    _disposed = true;
    trip.removeListener(_accountChanged);
    unawaited(_auth?.cancel());
    super.dispose();
  }
}
