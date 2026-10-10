import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/app.dart';
import '../../companion/data/trip_store.dart';
import '../../companion/presentation/forms.dart';
import '../data/live_map_store.dart';
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
    // An invitation remains in the list until the account explicitly joins it.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(store.resume());
    } else {
      unawaited(store.suspend());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    final consent = await liveConfirm(
      context,
      'Share your live location?',
      'Everyone who joins “${snapshot.session['name']}” can see your latest location and accuracy, including members invited later.\n\n'
          'Sharing ends at ${DateTime.parse(snapshot.session['expires_at'] as String).toLocal()}. It runs only while this map is open in the foreground.\n\n'
          'Stop removes your position. If offline, others may see the last position for up to 30 seconds. No route history is kept in the app. Managed backups can retain deleted rows under the deployment retention policy.\n\n'
          '${store.trip.demo ? 'Demo: synthetic positions only; your GPS is never accessed.' : 'Your device will ask for location permission next. You can decline and still view the group.'}',
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
    if (id != null)
      await store.command('invite', {
        'session_id': store.sessionId,
        'target_id': id,
      });
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
    final uri = Uri.base
        .replace(
          queryParameters: {'live_session': store.sessionId!},
          fragment: '',
        )
        .toString();
    if (share) {
      final box = context.findRenderObject() as RenderBox?;
      try {
        await SharePlus.instance.share(
          ShareParams(
            text:
                'Open this private Live Map. An account invitation is required.\n$uri',
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
        return;
      } catch (_) {}
    }
    await Clipboard.setData(ClipboardData(text: uri));
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session link copied. Only invited accounts can join.'),
        ),
      );
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
          title: const Text('Live Map'),
          actions: [
            IconButton(
              tooltip: 'Refresh Live Map',
              onPressed: store.refresh,
              icon: const Icon(Icons.refresh),
            ),
            if (store.sessionId != null)
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
                    child: Text('Copy session link'),
                  ),
                  const PopupMenuItem(
                    value: 'share',
                    child: Text('Share session link'),
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
              if (store.trip.demo)
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
                                if (store.organizer)
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
                                names: {
                                  for (final m in snapshot.members)
                                    m['user_id'] as String:
                                        m['display_name'] as String? ??
                                        'Traveler',
                                },
                                destination: snapshot.destination,
                                focus: selected,
                                onPoint: _destination,
                                demo: store.trip.demo,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              snapshot.destination == null
                                  ? 'Tap the map to choose a regroup point.'
                                  : '${snapshot.destination!['name']} · edited by ${snapshot.name(snapshot.destination!['set_by_user_id'] as String)}\nApproximate straight-line distances; no route or ETA.',
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
                  color: store.sharing ? const Color(0xFFD5EBDD) : Colors.white,
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
                              ? 'Sharing live location'
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
                            label: const Text('Share location'),
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
      Text(
        'Find your group',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      const Text(
        'Private sessions with people from your trips. View first; share only when you choose.',
      ),
      const SizedBox(height: 16),
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
