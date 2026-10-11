import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/app.dart';
import '../../../app/theme.dart';
import '../../../app/travel_sketch.dart';
import '../../companion/data/trip_store.dart';
import '../../companion/presentation/forms.dart';
import '../data/live_map_store.dart';
import '../data/campus_simulation.dart';
import '../domain/models.dart';
import 'live_map_forms.dart';
import 'map_adapter.dart';

class LiveMapRoute extends ConsumerWidget {
  const LiveMapRoute({super.key, required this.trip, this.initialSession});
  final TripStore trip;
  final String? initialSession;
  @override
  Widget build(BuildContext context, WidgetRef ref) => LiveMapScreen(
    store: ref.watch(
      liveMapStoreProvider((trip, '${trip.demo}:${trip.userId}')),
    ),
    initialSession: initialSession,
  );
}

/// Owns a memory-only test session while retaining the signed-in admin identity.
class CampusTestRoute extends StatefulWidget {
  const CampusTestRoute({super.key, required this.trip});
  final TripStore trip;
  @override
  State<CampusTestRoute> createState() => _CampusTestRouteState();
}

class _CampusTestRouteState extends State<CampusTestRoute> {
  late final store = LiveMapStore(
    trip: widget.trip,
    api: CampusSimulation(adminId: widget.trip.userId),
  );
  @override
  Widget build(BuildContext context) =>
      LiveMapScreen(store: store, initialSession: CampusSimulation.sessionId);
  @override
  void dispose() {
    store.dispose();
    super.dispose();
  }
}

class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key, required this.store, this.initialSession});
  final LiveMapStore store;
  final String? initialSession;
  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen>
    with WidgetsBindingObserver {
  LiveMapStore get store => widget.store;
  String? selectedMember;
  CampusSimulation? get simulation =>
      store.api is CampusSimulation ? store.api as CampusSimulation : null;
  Timer? _simulationTimer;
  final _tickClock = Stopwatch();

  void _startSimulation() {
    if (simulation == null) return;
    _simulationTimer?.cancel();
    _tickClock
      ..reset()
      ..start();
    _simulationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!store.validAccount || !store.viewing || !store.active) return;
      final elapsed = _tickClock.elapsed;
      _tickClock.reset();
      simulation!.tick(elapsed);
      unawaited(store.refresh());
    });
  }

  Future<void> _resetSimulation() async {
    await store.stop();
    simulation!.reset();
    selectedMember = null;
    await store.enter(CampusSimulation.sessionId);
    _startSimulation();
  }

  Future<void> _testControls() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            final sim = simulation!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Three phones. One screen.',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'You stay admin. These runners are simulated; your account and real trips stay unchanged.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final speed in [1.0, 5.0, 10.0])
                      ChoiceChip(
                        label: Text('${speed.toInt()}× speed'),
                        selected: sim.speed == speed,
                        onSelected: (_) {
                          sim.speed = speed;
                          unawaited(store.refresh());
                        },
                      ),
                  ],
                ),
                for (final runner in sim.runners.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          runner['display_name'] as String,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        if (runner['membership_status'] == 'removed')
                          const Text(
                            'Removed · reset the run to restore this phone',
                          )
                        else
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final mode in [
                                'running',
                                'paused',
                                'offline',
                              ])
                                ChoiceChip(
                                  label: Text(mode),
                                  selected: runner['mode'] == mode,
                                  onSelected: (_) {
                                    sim.setMode(
                                      runner['user_id'] as String,
                                      mode,
                                    );
                                    unawaited(store.refresh());
                                  },
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                const Text(
                  'Offline keeps the last fix: stale after 15 seconds, hidden after 30. Paused runners stay connected.',
                ),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.pop(context);
                    await _resetSimulation();
                  },
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset run'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Back to map'),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await store.enter();
    final id = widget.initialSession;
    if (!mounted || id == null) return;
    final invitation = store.sessions.where((s) => s['id'] == id).firstOrNull;
    if (invitation?['membership_status'] == 'joined') await store.enter(id);
    _startSimulation();
    // An invitation remains in the list until the account explicitly joins it.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(store.resume().then((_) => _startSimulation()));
    } else {
      _simulationTimer?.cancel();
      _tickClock.stop();
      unawaited(store.suspend());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _simulationTimer?.cancel();
    _tickClock.stop();
    unawaited(store.suspend());
    super.dispose();
  }

  Future<void> _create() async {
    final data = await createLiveSessionForm(context, store.trip);
    if (data == null || !mounted) return;
    final result = await store.command('create', data);
    if (result != null) await store.enter(result['session_id'] as String);
  }

  Future<void> _share() async {
    final snapshot = store.snapshot;
    if (snapshot == null) return;
    if (simulation != null) {
      final confirmed = await liveConfirm(
        context,
        'Show your test marker?',
        'Your marker stays at the campus meetup. No GPS is accessed or sent. You remain the admin of this local test.',
        label: 'Show test marker',
      );
      if (confirmed && mounted) await store.share();
      return;
    }
    final consent = await liveConfirm(
      context,
      'Share your live location?',
      'Everyone who joins “${snapshot.session['name']}” can see your latest location and accuracy, including members invited later.\n\n'
          'Sharing ends at ${DateTime.parse(snapshot.session['expires_at'] as String).toLocal()}. It runs only while this map is open in the foreground.\n\n'
          'Your recent path (up to 15 minutes) is visible to this session. Pause or Stop removes your position and path. If offline, both disappear from the map within 30 seconds. Managed backups can retain deleted rows under the deployment retention policy.\n\n'
          '${store.simulated ? 'Demo: synthetic positions only; your GPS is never accessed.' : 'Your device will ask for location permission next. You can decline and still view the group.'}',
      label: 'Agree and share',
    );
    if (consent && mounted) await store.share();
  }

  Future<void> _destination(double lat, double lon) async {
    if (!store.active || store.busy) return;
    final fields = await showFields(
      context,
      'Set regroup point',
      {'name': 'Place label'},
      initial: {'name': 'Meet here'},
    );
    if (fields == null || !mounted) return;
    if (await liveConfirm(
      context,
      'Confirm regroup point',
      'Set “${fields['name']}” at the point you tapped? Any joined member can update it. Distances are approximate straight lines.',
    )) {
      await store.command('destination', {
        'session_id': store.sessionId,
        'name': fields['name'],
        'latitude': lat,
        'longitude': lon,
      });
    }
  }

  Future<void> _invite() async {
    final linked = store.snapshot?.session['linked_trip_id'];
    final existing =
        store.snapshot?.members.map((m) => m['user_id']).toSet() ?? {};
    final candidates = store.contacts
        .where(
          (m) =>
              !existing.contains(m['user_id']) &&
              (linked == null ||
                  store.trip.snapshot
                      .members(linked as String)
                      .any((t) => t.id == m['user_id'] && t.active)),
        )
        .toList();
    final id = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Invite trip contacts'),
        children: [
          if (candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No eligible contacts. Join a current trip together first.',
              ),
            ),
          for (final m in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, m['user_id']),
              child: Text(m['display_name'] as String? ?? 'Traveler'),
            ),
        ],
      ),
    );
    if (id != null) {
      await store.command('invite', {
        'session_id': store.sessionId,
        'target_id': id,
      });
    }
  }

  Future<void> _finish(String action) async {
    if (await liveConfirm(
      context,
      action == 'leave' ? 'Leave Live Map?' : 'End Live Map?',
      action == 'leave'
          ? 'Your location will be removed. You will need a new invitation to rejoin.'
          : 'All sharing stops and the regroup point is removed for everyone.',
    )) {
      await store.stop();
      final result = await store.command(action, {
        'session_id': store.sessionId,
      });
      if (result != null) await store.enter();
    }
  }

  Future<void> _link({bool share = false}) async {
    final invitation = ['http', 'https'].contains(Uri.base.scheme)
        ? Uri.base
              .replace(
                queryParameters: {'live_session': store.sessionId!},
                fragment: '',
              )
              .toString()
        : 'Open Layover → Live Map and choose “${store.snapshot?.session['name'] ?? 'your invitation'}”. Session reference: ${store.sessionId}';
    if (share) {
      final box = context.findRenderObject() as RenderBox?;
      try {
        await SharePlus.instance.share(
          ShareParams(
            text:
                'Open this private Live Map. An account invitation is required.\n$invitation',
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
        return;
      } catch (_) {}
    }
    await Clipboard.setData(ClipboardData(text: invitation));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Session invitation copied. Only invited accounts can join.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final snapshot = store.snapshot;
      final locations = store.visibleLocations;
      final selected = locations
          .where((l) => l['user_id'] == selectedMember)
          .firstOrNull;
      return Scaffold(
        appBar: AppBar(
          title: Text(simulation == null ? 'Live Map' : 'CUSAT · test run'),
          actions: [
            IconButton(
              tooltip: 'Refresh Live Map',
              onPressed: store.refresh,
              icon: const Icon(Icons.refresh),
            ),
            if (simulation != null)
              IconButton(
                tooltip: 'Reset run',
                onPressed: _resetSimulation,
                icon: const Icon(Icons.restart_alt),
              ),
            if (store.sessionId != null && simulation == null)
              PopupMenuButton<String>(
                tooltip: 'Session actions',
                onSelected: (action) {
                  if (action == 'sessions') {
                    unawaited(store.stop().then((_) => store.enter()));
                  } else if (action == 'copy') {
                    unawaited(_link());
                  } else if (action == 'share') {
                    unawaited(_link(share: true));
                  } else {
                    unawaited(_finish(action));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'sessions',
                    child: Text('Back to sessions'),
                  ),
                  const PopupMenuItem(
                    value: 'copy',
                    child: Text('Copy session invitation'),
                  ),
                  const PopupMenuItem(
                    value: 'share',
                    child: Text('Share session invitation'),
                  ),
                  if (snapshot != null)
                    PopupMenuItem(
                      value: store.organizer
                          ? (snapshot.session['status'] == 'created'
                                ? 'cancel'
                                : 'end')
                          : 'leave',
                      child: Text(
                        store.organizer ? 'End session' : 'Leave session',
                      ),
                    ),
                ],
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (simulation != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'SIMULATION · YOU ARE ADMIN',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _testControls,
                        icon: const Icon(Icons.tune, size: 18),
                        label: const Text('Test controls'),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          simulation!.running = !simulation!.running;
                          unawaited(store.refresh());
                        },
                        icon: Icon(
                          simulation!.running ? Icons.pause : Icons.play_arrow,
                          size: 18,
                        ),
                        label: Text(
                          simulation!.running
                              ? 'Pause runners'
                              : 'Resume runners',
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (store.trip.demo)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    'DEMO · Synthetic, memory-only positions · No GPS',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              if (store.busy) const LinearProgressIndicator(minHeight: 2),
              if (store.error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    store.error!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    semanticsLabel: store.error,
                  ),
                ),
              Expanded(
                child: store.sessionId == null
                    ? _sessionList()
                    : snapshot == null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('No confirmed live session data.'),
                            TextButton(
                              onPressed: () => store.enter(),
                              child: const Text('Back to sessions'),
                            ),
                          ],
                        ),
                      )
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${snapshot.session['name']} · until ${TimeOfDay.fromDateTime(DateTime.parse(snapshot.session['expires_at'] as String).toLocal()).format(context)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                                if (store.organizer && simulation == null)
                                  IconButton(
                                    tooltip: 'Invite trip contacts',
                                    onPressed: store.busy ? null : _invite,
                                    icon: const Icon(Icons.person_add_alt),
                                  ),
                              ],
                            ),
                          ),
                          if (!store.active)
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: store.organizer
                                  ? FilledButton(
                                      onPressed: store.busy
                                          ? null
                                          : () => store.command('start', {
                                              'session_id': store.sessionId,
                                            }),
                                      child: const Text('Start session'),
                                    )
                                  : const Text(
                                      'Waiting for the organizer to start.',
                                    ),
                            ),
                          Expanded(
                            flex: 6,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: GroupMap(
                                locations: locations
                                    .map(
                                      (l) => {
                                        ...l,
                                        'stale':
                                            store.serverNow
                                                .difference(
                                                  DateTime.parse(
                                                    l['received_at'] as String,
                                                  ),
                                                )
                                                .inSeconds >=
                                            15,
                                      },
                                    )
                                    .toList(),
                                trails: snapshot.trails,
                                serverTime: store.serverNow,
                                names: {
                                  for (final m in snapshot.members)
                                    m['user_id'] as String:
                                        m['display_name'] as String? ??
                                        'Traveler',
                                },
                                destination: snapshot.destination,
                                focus: selected,
                                onPoint: _destination,
                                demo: store.simulated,
                                campus: simulation != null,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              snapshot.destination == null
                                  ? 'Tap the map to choose a regroup point.'
                                  : '${snapshot.destination!['name']} · edited by ${snapshot.name(snapshot.destination!['set_by_user_id'] as String)}\nRecent GPS trails · gaps when accuracy is low.\nDistances are straight-line; no route or ETA.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: ListView(
                              children: [
                                for (final member in snapshot.members)
                                  _member(member, snapshot, locations),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: store.sessionId == null
            ? null
            : SafeArea(
                child: Material(
                  color: store.sharing ? LayoverColors.wash : Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Text(
                          store.sharing
                              ? simulation != null
                                    ? 'Your test marker is visible'
                                    : 'Sharing live location'
                              : simulation != null
                              ? 'Your GPS stays off'
                              : 'Location sharing is off',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (store.sharing) ...[
                          TextButton(
                            onPressed: () => store.stop(pause: true),
                            child: const Text('Pause'),
                          ),
                          FilledButton.icon(
                            onPressed: store.stop,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('Stop sharing'),
                          ),
                        ] else
                          FilledButton.icon(
                            onPressed: store.busy || !store.active
                                ? null
                                : _share,
                            icon: const Icon(Icons.my_location),
                            label: Text(
                              simulation == null
                                  ? 'Share location'
                                  : 'Show my test marker',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      );
    },
  );
  Widget _sessionList() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const PageIntro(
        title: 'Find your group',
        subtitle: 'Wander your own way. Meet back here.\nShare your location only when you choose.',
      ),
      if (simulation == null)
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CampusTestRoute(trip: store.trip),
            ),
          ),
          icon: const Icon(Icons.directions_run),
          label: const Text('Try CUSAT with test runners'),
        ),
      const TravelSketch(height: 165),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: store.busy || !store.validAccount ? null : _create,
        icon: const Icon(Icons.add),
        label: const Text('Create Live Map'),
      ),
      const SizedBox(height: 16),
      if (store.sessions.isEmpty)
        const Text('No active sessions or invitations yet.'),
      for (final session in store.sessions)
        Card(
          child: ListTile(
            title: Text(session['name'] as String),
            subtitle: Text(
              session['membership_status'] == 'invited'
                  ? 'Account invitation · location stays off'
                  : '${session['status']} · sharing stays off until you opt in',
            ),
            trailing: TextButton(
              onPressed: store.busy
                  ? null
                  : () async {
                      final id = session['id'] as String;
                      if (session['membership_status'] == 'invited') {
                        final result = await store.command('join', {
                          'session_id': id,
                        });
                        if (result == null) return;
                      }
                      await store.enter(id);
                    },
              child: Text(
                session['membership_status'] == 'invited' ? 'Join' : 'View',
              ),
            ),
          ),
        ),
    ],
  );
  Widget _member(Json member, LiveSnapshot snapshot, List<Json> locations) {
    final id = member['user_id'] as String;
    final location = locations.where((l) => l['user_id'] == id).firstOrNull;
    final name = member['display_name'] as String? ?? 'Traveler';
    final distance = location != null && snapshot.destination != null
        ? distanceMetres(location, snapshot.destination!)
        : null;
    return ListTile(
      selected: selectedMember == id,
      onTap: location == null
          ? null
          : () => setState(() => selectedMember = id),
      leading: CircleAvatar(
        child: Text(name.isEmpty ? '?' : name.substring(0, 1)),
      ),
      title: Text(name),
      subtitle: Text(
        location == null
            ? '${member['membership_status']} · ${member['sharing_status'] ?? 'stopped'}'
            : '${freshness(location, store.serverNow)} · ±${(location['accuracy_m'] as num).round()} m${distance == null ? '' : '\n~${distance.round()} m to regroup'}',
      ),
      trailing: store.organizer && id != store.trip.userId
          ? IconButton(
              tooltip: member['membership_status'] == 'invited'
                  ? 'Revoke invitation'
                  : 'Remove member',
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: () async {
                if (await liveConfirm(
                  context,
                  'Remove $name?',
                  'Their session access and current position will be removed.',
                )) {
                  await store.command(
                    member['membership_status'] == 'invited'
                        ? 'revoke'
                        : 'remove',
                    {'session_id': store.sessionId, 'target_id': id},
                  );
                }
              },
            )
          : null,
    );
  }
}
