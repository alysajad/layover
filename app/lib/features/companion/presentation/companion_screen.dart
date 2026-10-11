import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme.dart';
import '../../../app/travel_sketch.dart';
import '../data/trip_store.dart';
import '../data/push_notifications.dart';
import '../domain/models.dart';
import 'forms.dart';
import 'payment_inbox.dart';
import '../../memories/presentation/memories_screen.dart';
import '../../live_map/presentation/live_map_screen.dart';
import '../../trip_explorer/presentation/explorer_screen.dart';
import '../../trip_planner/planner_screen.dart';

class CompanionScreen extends StatefulWidget {
  const CompanionScreen({super.key, required this.store});
  final TripStore store;
  @override
  State<CompanionScreen> createState() => _CompanionScreenState();
}

class _CompanionScreenState extends State<CompanionScreen>
    with WidgetsBindingObserver {
  TripStore get store => widget.store;
  int tab = 0;
  bool ready = false;
  String planFilter = 'All';
  String moneyView = 'Pot';
  String? startupError;
  String? inviteToken;
  String? _pushUser;
  String? _screenAccount;
  static const labels = ['Overview', 'Plan', 'Money', 'Bookings', 'Group'];
  static const icons = [
    Icons.dashboard_outlined,
    Icons.calendar_month_outlined,
    Icons.account_balance_wallet_outlined,
    Icons.confirmation_number_outlined,
    Icons.groups_outlined,
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_restorePushAfterSignIn);
    initialize();
  }

  Future<void> initialize() async {
    try {
      await store.initialize();
      _restorePushAfterSignIn();
      inviteToken = Uri.base.queryParameters['invite'];
    } catch (e) {
      startupError = friendlyError(e);
    }
    if (mounted) setState(() => ready = true);
  }

  void _restorePushAfterSignIn() {
    final account = store.client?.auth.currentUser?.id;
    if (_screenAccount != account) {
      final previous = _screenAccount;
      _screenAccount = account;
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
        });
      }
    }
    final user = store.signedIn && !store.demo ? store.userId : null;
    if (_pushUser == user) return;
    _pushUser = user;
    if (user != null) {
      unawaited(
        PushNotifications.restore(store).catchError((Object _) {
          // Optional push registration must not interrupt the shared trip view.
        }),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    store.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_restorePushAfterSignIn);
    super.dispose();
  }

  void selectTab(int index) {
    setState(() => tab = index);
    unawaited(store.refresh(silent: true));
  }

  void message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<Json?> run(String action, Json data) async {
    final result = await store.command(
      action,
      data,
      requestId: data['capture_id'] as String?,
    );
    if (result == null && store.error != null) message(store.error!);
    return result;
  }

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> openLink(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      message('This link is not valid.');
      return;
    }
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        message('Could not open the link.');
      }
    } catch (_) {
      message('Could not open the link.');
    }
  }

  Future<void> shareText(String text) async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      message('Copied to clipboard.');
    }
  }

  Future<void> createTrip({bool duplicate = false, bool edit = false}) async {
    final originalTrip = store.trip;
    final editingUser = store.userId;
    final values = await showFields(
      context,
      edit
          ? 'Edit trip'
          : duplicate
          ? 'Duplicate trip'
          : 'Create trip',
      {
        'title': 'Trip name',
        'destination': 'Destination',
        'start_date': 'Start date',
        'end_date': 'End date',
      },
      initial: edit
          ? {
              'title': originalTrip!.title,
              'destination': originalTrip.destination,
              'start_date': originalTrip.start,
              'end_date': originalTrip.end,
            }
          : duplicate
          ? {
              'title': '${originalTrip!.title} again',
              'destination': originalTrip.destination,
            }
          : {},
      optional: {'destination', 'start_date', 'end_date'},
    );
    if (values == null || store.userId != editingUser) return;
    try {
      final start = values['start_date'] as String;
      final end = values['end_date'] as String;
      if (start.isNotEmpty) DateFormat('yyyy-MM-dd').parseStrict(start);
      if (end.isNotEmpty) DateFormat('yyyy-MM-dd').parseStrict(end);
      if (start.isNotEmpty && end.isNotEmpty && end.compareTo(start) < 0) {
        throw const FormatException('End date must follow start date.');
      }
      await run(
        edit
            ? 'update_trip'
            : duplicate
            ? 'duplicate_trip'
            : 'create_trip',
        {
          ...values,
          if (duplicate) 'source_id': originalTrip!.id,
          if (edit) ...{
            'trip_id': originalTrip!.id,
            'expected_updated_at': originalTrip.data['updated_at'],
          },
        },
      );
      if (mounted) setState(() => tab = 0);
    } catch (e) {
      message(friendlyError(e));
    }
  }

  Future<void> joinTrip() async {
    final values = await showFields(
      context,
      'Join a trip',
      {'token': 'Invite code'},
      initial: {'token': inviteToken ?? ''},
    );
    if (values != null) {
      final result = await run('join_trip', values);
      if (result != null && mounted) setState(() => inviteToken = null);
    }
  }

  Future<void> addEntry(String kind, {TripEntry? entry}) async {
    final user = store.userId;
    final data = await showEntryForm(context, store, kind, entry: entry);
    if (data != null && user == store.userId) await run('save_entry', data);
  }

  Future<void> addMoney({bool pot = false, Json? initial}) async {
    final user = store.userId;
    final data = await showMoneyForm(
      context,
      store,
      pot: pot,
      initial: initial,
    );
    if (data == null || user != store.userId) return;
    if (store.offline && !pot) {
      await store.saveDraft(data);
      if (data['capture_id'] case final String id) {
        await store.payments.dismiss(id);
      }
      message('Expense draft saved on this device.');
      return;
    }
    if (!mounted) return;
    final shares = splitAmount(
      data['amount_minor'] as int,
      Map<String, int>.from(data['weights'] as Map),
      mode: SplitMode.values.byName(data['split_mode'] as String),
      remainderUser: pot
          ? store.snapshot.trips
                .firstWhere((t) => t.id == data['trip_id'])
                .organizer
          : null,
    );
    final summary = data['personal'] == true
        ? '${money(data['amount_minor'] as int)} · ${data['category']}\nOnly you can see this expense. Group balances stay the same.'
        : shares.entries
              .map(
                (e) =>
                    '${store.snapshot.name(data['trip_id'] as String, e.key)}: ${money(e.value)}',
              )
              .join('\n');
    if (await confirm(
      pot
          ? 'Propose these shares?'
          : data['personal'] == true
          ? 'Save personal expense?'
          : 'Record this expense?',
      '$summary${pot ? '\n\nEvery participant must accept these terms.' : ''}',
    )) {
      if (user != store.userId) return;
      final result = await run(
        pot
            ? 'save_pot'
            : data['personal'] == true
            ? 'add_personal_expense'
            : 'add_expense',
        data,
      );
      if (result != null &&
          user == store.userId &&
          data['capture_id'] is String) {
        await store.payments.dismiss(data['capture_id'] as String);
      }
    }
  }

  Future<void> reportTransfer({
    Json? initial,
    Json? pot,
    Transfer? correction,
  }) async {
    final user = store.userId;
    final data = await showTransferForm(
      context,
      store,
      initial: initial,
      pot: pot,
      correction: correction,
    );
    if (data != null && user == store.userId) {
      await run('report_transfer', data);
    }
  }

  Future<void> exportExpenses() async {
    final csv = expensesCsv(store.snapshot, store.selectedTrip!);
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(csv)),
              mimeType: 'text/csv',
              name: 'layover-expenses.csv',
            ),
          ],
          fileNameOverrides: ['layover-expenses.csv'],
        ),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: csv));
      message('Expense CSV copied to clipboard.');
    }
  }

  Future<void> invite() async {
    final result = await run('invite', {'trip_id': store.selectedTrip});
    if (result == null || !mounted) return;
    final token = result['token'] as String;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Invite friends'),
        content: SelectableText(token),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Done'),
          ),
          IconButton(
            tooltip: 'Copy invite code',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: token));
              message('Invite code copied.');
            },
            icon: const Icon(Icons.copy),
          ),
          FilledButton.icon(
            onPressed: () => shareText(
              'Join ${store.trip!.title} on Layover. Invite code: $token',
            ),
            icon: const Icon(Icons.share_outlined),
            label: const Text('Share'),
          ),
        ],
      ),
    );
  }

  bool get canEdit =>
      !store.offline && !store.busy && store.trip?.archived != true;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      if (!ready) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (startupError != null) {
        return Scaffold(body: Center(child: Text(startupError!)));
      }
      if (!store.signedIn) return SignInScreen(store: store);
      final wide = MediaQuery.sizeOf(context).width >= 900;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Layover'),
          titleSpacing: 24,
          actions: [
            if (store.demo)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Center(
                  child: Text(
                    'DEMO',
                    style: TextStyle(fontSize: 10, letterSpacing: 1.5),
                  ),
                ),
              ),
            IconButton(
              tooltip: store.lastSyncedAt == null
                  ? 'Sync now'
                  : 'Sync now · Updated ${DateFormat('HH:mm:ss').format(store.lastSyncedAt!)}',
              onPressed: store.loading ? null : () => store.refresh(),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Notifications',
              onPressed: notifications,
              icon: Badge(
                isLabelVisible: rows(store.snapshot.data['notifications'])
                    .any((n) => n['read_at'] == null),
                child: const Icon(Icons.notifications_none),
              ),
            ),
            IconButton(
              tooltip: 'Profile and settings',
              onPressed: settings,
              icon: const Icon(Icons.account_circle_outlined),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            if (store.busy || store.loading)
              const LinearProgressIndicator(minHeight: 2),
            if (store.offline)
              MaterialBanner(
                content: Text(
                  'Offline summary${store.snapshot.data['cached_at'] != null ? ' · ${formatDate(store.snapshot.data['cached_at'].toString())}' : ''}',
                ),
                leading: const Icon(Icons.cloud_off_outlined),
                actions: [
                  TextButton(
                    onPressed: () => store.refresh(),
                    child: const Text('Reconnect'),
                  ),
                ],
              ),
            if (store.error != null && !store.offline)
              MaterialBanner(
                content: Text(store.error!),
                actions: [
                  TextButton(
                    onPressed: store.retry,
                    child: Text(store.canRetry ? 'Retry request' : 'Retry'),
                  ),
                ],
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (wide)
                    NavigationRail(
                      selectedIndex: tab,
                      onDestinationSelected: selectTab,
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (var i = 0; i < labels.length; i++)
                          NavigationRailDestination(
                            icon: Icon(icons[i]),
                            label: Text(labels[i]),
                          ),
                      ],
                    ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () => store.refresh(),
                      child: SingleChildScrollView(
                        key: PageStorageKey(
                          '${store.userId}/${store.selectedTrip}/$tab',
                        ),
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          wide ? 36 : 22,
                          8,
                          wide ? 36 : 22,
                          32,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 960),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                tripSelector(),
                                if (inviteToken != null)
                                  TextButton.icon(
                                    onPressed: joinTrip,
                                    icon: const Icon(Icons.person_add_alt),
                                    label: const Text(
                                      'Open received invitation',
                                    ),
                                  ),
                                const SizedBox(height: 24),
                                if (store.trip == null) liveMapCard(),
                                if (store.trip == null)
                                  empty(
                                    'Your next trip starts here',
                                    icon: Icons.luggage_outlined,
                                    action: FilledButton.icon(
                                      onPressed: () => createTrip(),
                                      icon: const Icon(Icons.add),
                                      label: const Text('Create trip'),
                                    ),
                                  )
                                else ...[
                                  if (store.trip!.archived)
                                    const Padding(
                                      padding: EdgeInsets.only(bottom: 16),
                                      child: Text(
                                        'Archived trip',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  switch (tab) {
                                    0 => overview(),
                                    1 => plan(),
                                    2 => moneyPage(),
                                    3 => bookings(),
                                    _ => group(),
                                  },
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: selectTab,
                destinations: [
                  for (var i = 0; i < labels.length; i++)
                    NavigationDestination(
                      icon: Icon(icons[i]),
                      label: labels[i],
                    ),
                ],
              ),
      );
    },
  );
  Widget tripSelector() => Row(
    children: [
      Expanded(
        child: store.snapshot.trips.isEmpty
            ? const Text(
                'A little further, together.',
                style: TextStyle(color: LayoverColors.muted),
              )
            : DropdownButtonFormField<String>(
                key: ValueKey(store.selectedTrip),
                initialValue: store.selectedTrip,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Your trips',
                  prefixIcon: Icon(Icons.luggage_outlined, size: 20),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                items: [
                  for (final t in store.snapshot.trips)
                    DropdownMenuItem(
                      value: t.id,
                      child: Text(t.title, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  store.selectTrip(v);
                  setState(() => tab = 0);
                },
              ),
      ),
      const SizedBox(width: 8),
      PopupMenuButton<String>(
        tooltip: 'Trip actions',
        icon: const Icon(Icons.more_horiz),
        onSelected: (action) {
          if (action == 'create') createTrip();
          if (action == 'edit') createTrip(edit: true);
          if (action == 'join') joinTrip();
          if (action == 'memories') openMemories(context, store);
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'memories', child: Text('My memories')),
          PopupMenuItem(
            value: 'create',
            enabled: !store.offline,
            child: const Text('Create trip'),
          ),
          if (store.organizer)
            PopupMenuItem(
              value: 'edit',
              enabled: canEdit,
              child: const Text('Edit trip'),
            ),
          PopupMenuItem(
            value: 'join',
            enabled: !store.offline,
            child: const Text('Join trip'),
          ),
        ],
      ),
    ],
  );
  Widget liveMapCard() => Card(
    color: Colors.white,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      leading: const Icon(Icons.near_me_outlined, size: 28),
      title: const Text(
        'Live Map · Find your group',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: const Text('A little lost? Find each other here.'),
      trailing: const Icon(Icons.arrow_forward),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LiveMapRoute(
            trip: store,
            initialSession: Uri.base.queryParameters['live_session'],
          ),
        ),
      ),
    ),
  );
  Widget overview() {
    final t = store.trip!;
    final pot = store.snapshot.pot(t.id);
    final tasks = store.snapshot.entries(t.id, 'task');
    final upcoming = store.snapshot.entries(t.id, 'itinerary')
      ..sort(
        (a, b) => '${a.text('date')} ${a.text('time')}'.compareTo(
          '${b.text('date')} ${b.text('time')}',
        ),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'ALL TOGETHER, SOMEWHERE NEW',
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(letterSpacing: 2, color: LayoverColors.muted),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.title, style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (t.destination.isNotEmpty)
                      Text(
                        t.destination,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    Text(
                      t.start.isEmpty
                          ? 'Dates to decide'
                          : '${tripDate(t.start)} – ${tripDate(t.end)}',
                      style: const TextStyle(color: LayoverColors.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    for (final m
                        in store.members.where((m) => m.active).take(3))
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: CircleAvatar(
                          radius: 15,
                          backgroundColor: LayoverColors.ink,
                          child: Text(
                            m.name.isEmpty ? '?' : m.name[0],
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${store.members.where((m) => m.active).length} travelers',
                        style: const TextStyle(color: LayoverColors.muted),
                      ),
                    ),
                    if (store.organizer)
                      IconButton(
                        tooltip: 'Invite friends',
                        onPressed: canEdit ? invite : null,
                        icon: const Icon(Icons.person_add_alt, size: 21),
                      ),
                  ],
                ),
              ],
            );
            if (constraints.maxWidth >= 650) {
              return Row(
                children: [
                  Expanded(child: details),
                  const Expanded(child: TravelSketch(height: 220)),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [details, const TravelSketch(height: 185)],
            );
          },
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: LayoverColors.ink),
            borderRadius: BorderRadius.circular(22),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 20,
              runSpacing: 22,
              children: [
                stat(
                  'Pot target',
                  store.offline
                      ? 'Unavailable offline'
                      : pot == null
                      ? 'Not set'
                      : money(pot['target_minor_units'] as int),
                  LayoverColors.mint,
                ),
                stat(
                  'Recorded expenses',
                  store.offline
                      ? 'Unavailable offline'
                      : money(
                          store.snapshot
                              .expenses(t.id)
                              .where((e) => !e.voided)
                              .fold(0, (sum, e) => sum + e.amount),
                        ),
                  LayoverColors.coral,
                ),
                stat(
                  'Tasks completed',
                  '${tasks.where((e) => e.done).length} / ${tasks.length}',
                  LayoverColors.blue,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 14,
            ),
            leading: const Icon(Icons.portrait_outlined, size: 32),
            title: const Text('People I met'),
            subtitle: const Text(
              'A face, a name, a little story. Private by default.',
            ),
            trailing: const Icon(Icons.arrow_forward),
            onTap: () => openMemories(context, store, trip: t),
          ),
        ),
        const SizedBox(height: 12),
        liveMapCard(),
        Card(
          color: LayoverColors.wash,
          child: ListTile(
            leading: const Icon(Icons.directions_run),
            title: const Text('CUSAT · 3D test run'),
            subtitle: const Text(
              'Your phone is admin. Three test runners join you.',
            ),
            trailing: const Icon(Icons.north_east),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CampusTestRoute(trip: store),
              ),
            ),
          ),
        ),
        Card(
          color: LayoverColors.wash,
          child: ListTile(
            leading: const Icon(Icons.travel_explore),
            title: const Text('Explore within budget'),
            subtitle: const Text('Good places. A budget that fits.'),
            trailing: const Icon(Icons.arrow_forward),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ExplorerScreen(trip: store, tripId: t.id),
              ),
            ),
          ),
        ),
        PlannerCard(store: store),
        for (final a in store.snapshot.entries(t.id, 'announcement'))
          entryTile(a),
        section(
          'Coming up',
          action: IconButton(
            tooltip: 'Add itinerary item',
            onPressed: canEdit ? () => addEntry('itinerary') : null,
            icon: const Icon(Icons.add),
          ),
        ),
        if (upcoming.isEmpty)
          empty('No itinerary yet', icon: Icons.event_note_outlined)
        else
          for (final item in upcoming.take(4)) entryTile(item),
        section('Recent activity'),
        ...activity().take(6),
      ],
    );
  }

  Widget plan() {
    final entries =
        store.snapshot
            .entries(store.selectedTrip!)
            .where(
              (e) =>
                  ['poll', 'shortlist', 'itinerary'].contains(e.kind) &&
                  (planFilter == 'All' ||
                      e.kind ==
                          {
                            'Polls': 'poll',
                            'Shortlist': 'shortlist',
                            'Itinerary': 'itinerary',
                          }[planFilter]),
            )
            .toList()
          ..sort(
            (a, b) => '${a.text('date')} ${a.text('time')}'.compareTo(
              '${b.text('date')} ${b.text('time')}',
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: 'The plan',
          subtitle: 'Big ideas, little detours. Make room for both.',
          action: PopupMenuButton<String>(
            tooltip: 'Add to plan',
            enabled: canEdit,
            icon: const Icon(Icons.add),
            onSelected: (kind) => addEntry(kind),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'poll',
                child: Text('Date or budget poll'),
              ),
              const PopupMenuItem(
                value: 'shortlist',
                child: Text('Shortlist a stay or activity'),
              ),
              const PopupMenuItem(
                value: 'itinerary',
                child: Text('Itinerary item'),
              ),
            ],
          ),
        ),
        PlannerCard(store: store),
        Wrap(
          spacing: 8,
          children: [
            for (final f in ['All', 'Polls', 'Shortlist', 'Itinerary'])
              ChoiceChip(
                label: Text(f),
                selected: planFilter == f,
                onSelected: (_) => setState(() => planFilter = f),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (entries.isEmpty)
          empty('No plans here yet', icon: Icons.event_note_outlined),
        for (final e in entries) entryTile(e),
      ],
    );
  }

  Widget bookings() {
    final entries = store.snapshot.entries(store.selectedTrip!, 'booking');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: 'Bookings',
          subtitle: 'Booking plans and confirmed reservations, in one place.',
          action: IconButton(
            tooltip: 'Add booking',
            onPressed: canEdit ? () => addEntry('booking') : null,
            icon: const Icon(Icons.add),
          ),
        ),
        if (entries.isEmpty)
          empty(
            'No bookings recorded',
            icon: Icons.confirmation_number_outlined,
          ),
        for (final e in entries) entryTile(e),
      ],
    );
  }

  Widget entryTile(TripEntry e) {
    final responses = store.snapshot.responses(e.id);
    final mine =
        responses
                .where((r) => r['user_id'] == store.userId)
                .firstOrNull?['response']
            as Map?;
    final selected = e.details['selected'] == true;
    final editable = store.organizer || e.author == store.userId;
    final comments = rows(store.snapshot.data['comments'])
        .where((c) => c['entry_id'] == e.id)
        .toList();
    final subtitle = [
      e.text('date'),
      e.text('time'),
      e.text('address'),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (e.kind == 'task')
                    Checkbox(
                      value: e.done,
                      onChanged:
                          canEdit &&
                              (editable ||
                                  e.text('assigned_to') == store.userId)
                          ? (v) => run('toggle_task', {
                              'trip_id': e.tripId,
                              'id': e.id,
                              'done': v,
                            })
                          : null,
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.kind == 'poll'
                              ? e.text('poll_type').toUpperCase()
                              : e.kind.toUpperCase(),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          e.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(
                        Icons.check_circle_outline,
                        color: Color(0xFF267B58),
                      ),
                    ),
                  if (canEdit &&
                      (editable || (e.kind == 'shortlist' && store.organizer)))
                    PopupMenuButton<String>(
                      tooltip: 'Entry actions',
                      onSelected: (value) async {
                        if (value == 'edit') await addEntry(e.kind, entry: e);
                        if (value == 'delete' &&
                            await confirm('Remove entry?', e.title)) {
                          await run('delete_entry', {
                            'trip_id': e.tripId,
                            'id': e.id,
                          });
                        }
                        if (value == 'choose') {
                          await run('choose_entry', {
                            'trip_id': e.tripId,
                            'id': e.id,
                          });
                        }
                        if (value == 'pot') {
                          await addMoney(
                            pot: true,
                            initial: {
                              'title': e.title,
                              'amount': e.text('price'),
                            },
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        if (editable)
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('Edit'),
                          ),
                        if (e.kind == 'shortlist' && store.organizer) ...[
                          const PopupMenuItem(
                            value: 'choose',
                            child: Text('Select this option'),
                          ),
                          const PopupMenuItem(
                            value: 'pot',
                            child: Text('Create pot from price'),
                          ),
                        ],
                        if (editable)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Remove'),
                          ),
                      ],
                    ),
                ],
              ),
              if (subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(subtitle),
                ),
              if (e.text('notes').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(e.text('notes')),
                ),
              if (e.text('price').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'INR ${e.text('price')} total',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              if (e.kind == 'booking') ...[
                const SizedBox(height: 8),
                Text(
                  e.text('booking_status') == 'planned' &&
                          e.text('reference').isEmpty
                      ? 'To book · reservation not confirmed'
                      : e.text('reference').isNotEmpty
                      ? 'Confirmation recorded'
                      : 'Group booking record',
                ),
                for (final field in {
                  'reference': 'Reference',
                  'cancellation': 'Cancellation',
                  'payment_due': 'Payment due',
                  'remind_at': 'Reminder',
                }.entries)
                  if (e.text(field.key).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('${field.value}: ${e.text(field.key)}'),
                    ),
              ],
              if (e.text('directions_url').isNotEmpty)
                TextButton.icon(
                  onPressed: () => openLink(e.text('directions_url')),
                  icon: const Icon(Icons.directions_outlined),
                  label: const Text('Directions'),
                ),
              if (e.text('assigned_to').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Assigned: ${store.snapshot.name(e.tripId, e.text('assigned_to'))}',
                  ),
                ),
              if (e.kind == 'contact')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(e.text('phone')),
                ),
              if (e.kind == 'poll') ...[
                const SizedBox(height: 12),
                for (final option in e.details['options'] as List? ?? [])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: canEdit && !selected
                                ? () => vote(e, mine, option as String)
                                : null,
                            style: voted(mine, option)
                                ? OutlinedButton.styleFrom(
                                    backgroundColor: LayoverColors.mint
                                        .withValues(alpha: .25),
                                  )
                                : null,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '$option (${responses.where((r) => voted(r['response'] as Map, option)).length})',
                              ),
                            ),
                          ),
                        ),
                        if (store.organizer && canEdit && !selected)
                          IconButton(
                            tooltip: 'Choose $option',
                            onPressed: () => run('choose_entry', {
                              'trip_id': e.tripId,
                              'id': e.id,
                              'choice': option,
                            }),
                            icon: const Icon(Icons.check),
                          ),
                      ],
                    ),
                  ),
                if (selected)
                  Text(
                    'Chosen: ${e.text('choice')}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
              ],
              if (e.kind == 'shortlist')
                Wrap(
                  spacing: 8,
                  children: [
                    for (final vote in ['yes', 'no'])
                      TextButton.icon(
                        onPressed: canEdit && !selected
                            ? () => run('respond', {
                                'trip_id': e.tripId,
                                'id': e.id,
                                'choice': vote,
                              })
                            : null,
                        icon: Icon(
                          vote == 'yes'
                              ? Icons.thumb_up_outlined
                              : Icons.thumb_down_outlined,
                          color: mine?['choice'] == vote
                              ? const Color(0xFF267B58)
                              : null,
                        ),
                        label: Text(
                          '${responses.where((r) => (r['response'] as Map)['choice'] == vote).length}',
                        ),
                      ),
                  ],
                ),
              if (e.kind == 'meeting') ...[
                Wrap(
                  spacing: 8,
                  children: [
                    for (final status in ['on_my_way', 'arrived'])
                      OutlinedButton.icon(
                        onPressed: canEdit
                            ? () => run('respond', {
                                'trip_id': e.tripId,
                                'id': e.id,
                                'choice': status,
                              })
                            : null,
                        icon: Icon(
                          status == 'arrived'
                              ? Icons.check_circle_outline
                              : Icons.directions_walk,
                        ),
                        label: Text(
                          status == 'arrived' ? 'I have arrived' : 'On my way',
                        ),
                      ),
                  ],
                ),
                for (final r in responses)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${store.snapshot.name(e.tripId, r['user_id'] as String)}: ${(r['response'] as Map)['choice'].toString().replaceAll('_', ' ')} · ${formatDate(r['updated_at'] as String)}',
                    ),
                  ),
              ],
              Wrap(
                spacing: 8,
                children: [
                  if (e.text('url').isNotEmpty)
                    TextButton.icon(
                      onPressed: () => openLink(e.text('url')),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open link'),
                    ),
                  if (e.text('address').isNotEmpty)
                    TextButton.icon(
                      onPressed: () => openLink(
                        Uri.https('www.google.com', '/maps/search/', {
                          'api': '1',
                          'query': e.text('address'),
                        }).toString(),
                      ),
                      icon: const Icon(Icons.directions_outlined),
                      label: const Text('Directions'),
                    ),
                  if (e.text('attachment').isNotEmpty && !store.offline)
                    TextButton.icon(
                      onPressed: () async {
                        try {
                          await openLink(
                            await store.attachmentUrl(e.text('attachment')),
                          );
                        } catch (error) {
                          message(friendlyError(error));
                        }
                      },
                      icon: const Icon(Icons.attach_file),
                      label: const Text('Confirmation'),
                    ),
                  TextButton.icon(
                    onPressed: canEdit
                        ? () async {
                            final v = await showFields(context, 'Add comment', {
                              'body': 'Comment',
                            });
                            if (v != null) {
                              await run('comment', {
                                'trip_id': e.tripId,
                                'id': e.id,
                                ...v,
                              });
                            }
                          }
                        : null,
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text('${comments.length} comments'),
                  ),
                ],
              ),
              for (final c in comments)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${store.snapshot.name(e.tripId, c['user_id'] as String)}: ${c['body']}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool voted(Map? response, Object option) =>
      response?['choice'] == option ||
      (response?['choices'] as List? ?? []).contains(option);
  Future<void> vote(TripEntry entry, Map? previous, String option) async {
    final payload = <String, dynamic>{'trip_id': entry.tripId, 'id': entry.id};
    if (entry.text('poll_type') == 'Dates') {
      final choices = List<String>.from(
        previous?['choices'] as List? ??
            (previous?['choice'] == null ? [] : [previous!['choice']]),
      );
      if (choices.contains(option)) {
        choices.remove(option);
      } else {
        choices.add(option);
      }
      payload['choices'] = choices;
    } else {
      payload['choice'] = option;
    }
    await run('respond', payload);
  }

  Widget moneyPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PageIntro(
        title: 'A shared adventure.\nA shared pot.',
        subtitle: 'Keep the spending clear and the trip easy.',
        action: IconButton(
          tooltip: 'Export expenses CSV',
          onPressed: store.offline ? null : exportExpenses,
          icon: const Icon(Icons.download_outlined),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final label in ['Pot', 'Expenses', 'Transfers', 'Settle'])
            ChoiceChip(
              label: Text(label),
              selected: moneyView == label,
              onSelected: (_) => setState(() => moneyView = label),
            ),
        ],
      ),
      const SizedBox(height: 20),
      if (moneyView == 'Pot') PlannerCard(store: store),
      if (store.offline && moneyView == 'Expenses')
        PaymentInbox(
          key: ValueKey('${store.userId}:${store.selectedTrip}'),
          store: store,
          onReview: (initial) => addMoney(initial: initial),
        ),
      if (store.offline)
        empty(
          'Financial totals need a connection',
          icon: Icons.cloud_off_outlined,
          action: FilledButton.icon(
            onPressed: () => addMoney(),
            icon: const Icon(Icons.add),
            label: const Text('Save expense draft'),
          ),
        )
      else
        switch (moneyView) {
          'Pot' => potPage(),
          'Expenses' => expensesPage(),
          'Transfers' => transfersPage(),
          _ => settlePage(),
        },
      if (store.drafts
          .where((d) => d['trip_id'] == store.selectedTrip)
          .isNotEmpty) ...[
        section('Expense drafts'),
        for (final d in store.drafts.where(
          (d) => d['trip_id'] == store.selectedTrip,
        ))
          ListTile(
            title: Text(d['title'] as String),
            subtitle: Text(money(d['amount_minor'] as int)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Delete draft',
                  onPressed: () => store.removeDraft(d['draft_id'] as String),
                  icon: const Icon(Icons.delete_outline),
                ),
                IconButton(
                  tooltip: 'Submit draft',
                  onPressed: canEdit ? () => store.submitDraft(d) : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                ),
              ],
            ),
          ),
      ],
    ],
  );
  Widget potPage() {
    final pot = store.snapshot.pot(store.selectedTrip!);
    if (pot == null) {
      return empty(
        'No pot yet',
        icon: Icons.savings_outlined,
        action: store.organizer
            ? FilledButton.icon(
                onPressed: canEdit ? () => addMoney(pot: true) : null,
                icon: const Icon(Icons.add),
                label: const Text('Create pot'),
              )
            : null,
      );
    }
    final obligations = store.snapshot.obligations(pot['id'] as String);
    final mine = obligations
        .where(
          (o) =>
              o['user_id'] == store.userId &&
              o['obligation_status'] != 'cancelled',
        )
        .firstOrNull;
    final collected = store.snapshot
        .transfers(store.selectedTrip!)
        .where((t) => t.potId == pot['id'] && t.acknowledged)
        .fold(
          0,
          (sum, t) =>
              sum +
              (t.recipient == store.trip!.organizer ? t.amount : -t.amount),
        );
    final covered = pot['organizer_cover_minor'] as int? ?? 0;
    final target = pot['target_minor_units'] as int;
    final closed = ['booked', 'cancelled', 'closed'].contains(pot['status']);
    final missed = DateTime.parse(pot['deadline_at'] as String)
        .isBefore(DateTime.now());
    final status = missed && ['open', 'funding'].contains(pot['status'])
        ? 'Deadline missed'
        : {
                'target_reached': 'Coverage reached',
                'booked': 'Booking reported',
                'cancelled': 'Cancelled',
                'closed': 'Closed',
                'target_missed': 'Deadline missed',
              }[pot['status']] ??
              'Collecting commitments';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          pot['title'] as String,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(status),
        const SizedBox(height: 20),
        Text(money(target), style: Theme.of(context).textTheme.headlineMedium),
        const Text('Funding target'),
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: ((collected + covered) / target).clamp(0, 1),
          minHeight: 10,
          borderRadius: BorderRadius.circular(5),
        ),
        const SizedBox(height: 12),
        Text(
          '${money(collected)} acknowledged by recipients\n${money(covered)} organizer-covered',
        ),
        const SizedBox(height: 8),
        Text('Deadline: ${formatDate(pot['deadline_at'] as String)}'),
        section('Shares and agreement'),
        for (final o in obligations.where(
          (o) => o['obligation_status'] != 'cancelled',
        ))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              o['accepted_terms_version'] == pot['terms_version']
                  ? Icons.check_circle_outline
                  : Icons.hourglass_empty,
            ),
            title: Text(
              store.snapshot.name(store.selectedTrip!, o['user_id'] as String),
            ),
            subtitle: Text(
              o['accepted_terms_version'] == pot['terms_version']
                  ? 'Accepted version ${pot['terms_version']}'
                  : 'Acceptance pending',
            ),
            trailing: Text(money(o['amount_minor_units'] as int)),
          ),
        const SizedBox(height: 12),
        Text(pot['terms_text'] as String),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (mine != null &&
                mine['accepted_terms_version'] != pot['terms_version'])
              FilledButton.icon(
                onPressed: canEdit && !closed && !missed
                    ? () => run('accept_terms', {
                        'trip_id': store.selectedTrip,
                        'version': pot['terms_version'],
                      })
                    : null,
                icon: const Icon(Icons.check),
                label: const Text('Accept terms and share'),
              ),
            if (mine != null && !store.organizer)
              FilledButton.icon(
                onPressed:
                    canEdit &&
                        !closed &&
                        !missed &&
                        mine['accepted_terms_version'] == pot['terms_version']
                    ? () => reportTransfer(
                        pot: pot,
                        initial: {
                          'recipient_id': store.trip!.organizer,
                          'amount_minor': mine['amount_minor_units'],
                        },
                      )
                    : null,
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Report contribution'),
              ),
            if (store.organizer && !closed)
              OutlinedButton.icon(
                onPressed: canEdit
                    ? () => addMoney(
                        pot: true,
                        initial: {
                          'title': pot['title'],
                          'amount': (target / 100).toStringAsFixed(2),
                          'terms': pot['terms_text'],
                          'deadline': (pot['deadline_at'] as String).substring(
                            0,
                            10,
                          ),
                          'cover': (covered / 100).toStringAsFixed(2),
                          'shares': {
                            for (final o in obligations)
                              if (![
                                'cancelled',
                                'waived',
                              ].contains(o['obligation_status']))
                                o['user_id'] as String: o['amount_minor_units'],
                          },
                        },
                      )
                    : null,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Revise terms and shares'),
              ),
            if (store.organizer && !closed)
              OutlinedButton.icon(
                onPressed: canEdit ? dropoutPreview : null,
                icon: const Icon(Icons.person_remove_outlined),
                label: const Text('Dropout preview'),
              ),
            if (store.organizer && !closed)
              OutlinedButton.icon(
                onPressed: canEdit && pot['status'] == 'target_reached'
                    ? () => recordOutcome('booked')
                    : null,
                icon: const Icon(Icons.confirmation_number_outlined),
                label: const Text('Record booking'),
              ),
            if (store.organizer &&
                !['cancelled', 'closed'].contains(pot['status']))
              TextButton(
                onPressed: canEdit ? () => recordOutcome('cancelled') : null,
                child: const Text('Cancel pot'),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> recordOutcome(String status) async {
    final tripId = store.selectedTrip;
    final user = store.userId;
    if (await confirm(
      status == 'booked' ? 'Record booking?' : 'Cancel pot?',
      status == 'booked'
          ? 'This records your booking decision. Add the confirmation under Bookings.'
          : 'Recorded transfers stay in the ledger. Any repayments must be made externally and acknowledged by the recipient.',
    )) {
      if (user != store.userId) return;
      await run('pot_outcome', {'trip_id': tripId, 'status': status});
    }
  }

  Future<void> dropoutPreview() async {
    final pot = store.snapshot.pot(store.selectedTrip!)!;
    final members = store.members.where((m) => m.active).toList();
    String? excluded;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) {
          final shares = splitAmount(pot['target_minor_units'] as int, {
            for (final m in members)
              if (m.id != excluded) m.id: 1,
          }, remainderUser: store.trip!.organizer);
          return AlertDialog(
            title: const Text('Dropout preview'),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: excluded,
                      decoration: const InputDecoration(
                        labelText: 'Member leaving',
                      ),
                      items: [
                        for (final m in members.where(
                          (m) => m.id != store.trip!.organizer,
                        ))
                          DropdownMenuItem(value: m.id, child: Text(m.name)),
                      ],
                      onChanged: (v) => setLocal(() => excluded = v),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Equal-share preview. Current obligations remain unchanged.',
                    ),
                    for (final e in shares.entries)
                      ListTile(
                        title: Text(
                          store.snapshot.name(store.selectedTrip!, e.key),
                        ),
                        trailing: Text(money(e.value)),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget expensesPage() {
    final expenses = store.snapshot.expenses(store.selectedTrip!);
    final personal = rows(store.snapshot.data['personal_expenses'])
        .where(
          (e) =>
              e['trip_id'] == store.selectedTrip &&
              e['created_by'] == store.userId,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: canEdit ? () => addMoney() : null,
            icon: const Icon(Icons.add),
            label: const Text('Add expense'),
          ),
        ),
        const SizedBox(height: 16),
        PaymentInbox(
          key: ValueKey('${store.userId}:${store.selectedTrip}'),
          store: store,
          onReview: (initial) => addMoney(initial: initial),
        ),
        const SizedBox(height: 16),
        if (expenses.isEmpty)
          empty('No shared expenses yet', icon: Icons.receipt_long_outlined),
        for (final e in expenses)
          Card(
            child: ExpansionTile(
              key: PageStorageKey('expense:${e.id}'),
              title: Text(e.title),
              subtitle: Text(
                '${money(e.amount)} · ${e.data['category'] ?? 'Other'} · ${store.snapshot.name(store.selectedTrip!, e.payer)}${e.data['expense_date'] == null ? '' : ' · ${tripDate(e.data['expense_date'] as String)}'}${e.voided ? ' · Voided' : ''}',
              ),
              children: [
                for (final split in e.splits.entries)
                  ListTile(
                    dense: true,
                    title: Text(
                      store.snapshot.name(store.selectedTrip!, split.key),
                    ),
                    trailing: Text(money(split.value)),
                  ),
                Wrap(
                  spacing: 12,
                  children: [
                    if (e.data['receipt_path'] != null)
                      TextButton.icon(
                        onPressed: () async {
                          try {
                            await openLink(
                              await store.attachmentUrl(
                                e.data['receipt_path'] as String,
                              ),
                            );
                          } catch (error) {
                            message(friendlyError(error));
                          }
                        },
                        icon: const Icon(Icons.receipt_outlined),
                        label: const Text('Receipt'),
                      ),
                    if (!e.voided &&
                        (store.organizer ||
                            e.data['created_by'] == store.userId))
                      TextButton.icon(
                        onPressed: canEdit
                            ? () async {
                                if (await confirm(
                                  'Void expense?',
                                  'The original stays in the activity history. Add a new expense to replace it.',
                                )) {
                                  await run('void_expense', {
                                    'trip_id': store.selectedTrip,
                                    'id': e.id,
                                  });
                                }
                              }
                            : null,
                        icon: const Icon(Icons.undo),
                        label: const Text('Void expense'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        if (personal.isNotEmpty) ...[
          section('Personal expenses · only you'),
          Text(
            'Total: ${money(personal.where((e) => e['voided_at'] == null).fold<int>(0, (total, e) => total + (e['amount_minor'] as num).toInt()))}',
          ),
          for (final e in personal)
            Card(
              child: ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(e['title'] as String),
                subtitle: Text(
                  '${money((e['amount_minor'] as num).toInt())} · ${e['category']} · ${tripDate(e['expense_date'] as String)}${e['voided_at'] != null ? ' · Voided' : ''}',
                ),
                trailing: e['voided_at'] != null
                    ? null
                    : IconButton(
                        tooltip: 'Void personal expense',
                        icon: const Icon(Icons.undo),
                        onPressed: canEdit
                            ? () => run('void_personal_expense', {
                                'trip_id': store.selectedTrip,
                                'id': e['id'],
                              })
                            : null,
                      ),
              ),
            ),
        ],
      ],
    );
  }

  Widget transfersPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: canEdit && store.members.where((m) => m.active).length > 1
              ? () => reportTransfer()
              : null,
          icon: const Icon(Icons.add),
          label: const Text('Report payment'),
        ),
      ),
      const SizedBox(height: 16),
      if (store.snapshot.transfers(store.selectedTrip!).isEmpty)
        empty('No transfers reported', icon: Icons.swap_horiz),
      for (final t in store.snapshot.transfers(store.selectedTrip!))
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${store.snapshot.name(store.selectedTrip!, t.sender)} to ${store.snapshot.name(store.selectedTrip!, t.recipient)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text('${money(t.amount)} · ${t.status}'),
                if (t.potId != null)
                  Text(
                    t.sender == store.trip!.organizer
                        ? 'Pot reimbursement'
                        : 'Pot contribution',
                  ),
                if ((t.data['note'] as String? ?? '').isNotEmpty)
                  Text(t.data['note'] as String),
                if (t.acknowledged)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Manually acknowledged by recipient'),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (t.potId != null &&
                        t.acknowledged &&
                        store.organizer &&
                        t.recipient == store.userId)
                      TextButton.icon(
                        onPressed: canEdit
                            ? () => reportTransfer(
                                pot: store.snapshot.pot(store.selectedTrip!),
                                initial: {
                                  'recipient_id': t.sender,
                                  'amount_minor': t.amount,
                                },
                              )
                            : null,
                        icon: const Icon(Icons.undo),
                        label: const Text('Report reimbursement'),
                      ),
                    if (t.recipient == store.userId &&
                        t.status != 'withdrawn') ...[
                      if (!t.acknowledged)
                        TextButton.icon(
                          onPressed: canEdit
                              ? () => run('transfer_status', {
                                  'trip_id': store.selectedTrip,
                                  'id': t.id,
                                  'status': 'acknowledged',
                                })
                              : null,
                          icon: const Icon(Icons.check),
                          label: const Text('Acknowledge receipt'),
                        ),
                      if (t.status != 'disputed')
                        TextButton(
                          onPressed: canEdit
                              ? () => run('transfer_status', {
                                  'trip_id': store.selectedTrip,
                                  'id': t.id,
                                  'status': 'disputed',
                                })
                              : null,
                          child: const Text('Dispute'),
                        ),
                    ],
                    if (t.sender == store.userId &&
                        t.status != 'withdrawn') ...[
                      TextButton.icon(
                        onPressed: canEdit
                            ? () => reportTransfer(correction: t)
                            : null,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Correct'),
                      ),
                      if (!t.acknowledged)
                        TextButton(
                          onPressed: canEdit
                              ? () => run('transfer_status', {
                                  'trip_id': store.selectedTrip,
                                  'id': t.id,
                                  'status': 'withdrawn',
                                })
                              : null,
                          child: const Text('Withdraw report'),
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
  Widget settlePage() {
    final balance = balances(
      store.snapshot.expenses(store.selectedTrip!),
      store.snapshot.transfers(store.selectedTrip!),
    );
    final payments = settlements(balance);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in store.members)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text(m.name),
            subtitle: Text(
              (balance[m.id] ?? 0) > 0
                  ? 'To receive'
                  : (balance[m.id] ?? 0) < 0
                  ? 'To pay'
                  : 'Settled',
            ),
            trailing: Text(money((balance[m.id] ?? 0).abs())),
          ),
        section('Suggested repayments'),
        if (payments.isEmpty)
          empty('Everyone is settled', icon: Icons.check_circle_outline),
        for (final p in payments)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${store.snapshot.name(store.selectedTrip!, p['sender_id'] as String)} to ${store.snapshot.name(store.selectedTrip!, p['recipient_id'] as String)}',
            ),
            subtitle: Text(money(p['amount_minor'] as int)),
            trailing: p['sender_id'] == store.userId
                ? IconButton(
                    tooltip: 'Report repayment',
                    onPressed: canEdit
                        ? () => reportTransfer(initial: p)
                        : null,
                    icon: const Icon(Icons.payments_outlined),
                  )
                : null,
          ),
      ],
    );
  }

  Widget group() {
    final t = store.trip!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: 'Your kind of people.',
          subtitle: 'The travelers making this trip happen.',
          action: store.organizer
              ? IconButton(
                  tooltip: 'Invite friends',
                  onPressed: canEdit ? invite : null,
                  icon: const Icon(Icons.person_add_alt),
                )
              : null,
        ),
        for (final m in store.members)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: LayoverColors.wash,
              foregroundColor: LayoverColors.ink,
              child: Text(m.name.isEmpty ? '?' : m.name[0]),
            ),
            title: Text(m.name),
            subtitle: Text(m.id == t.organizer ? 'Organizer' : m.status),
            trailing:
                canEdit &&
                    m.id != t.organizer &&
                    m.active &&
                    (store.organizer || m.id == store.userId)
                ? IconButton(
                    tooltip: m.id == store.userId
                        ? 'Leave trip'
                        : 'Remove member',
                    onPressed: () async {
                      if (await confirm(
                        'Remove ${m.name}?',
                        'Existing expenses and transfers remain. Revise pot shares separately if needed.',
                      )) {
                        await run('remove_member', {
                          'trip_id': t.id,
                          'user_id': m.id,
                        });
                      }
                    },
                    icon: const Icon(Icons.person_remove_outlined),
                  )
                : canEdit &&
                      store.organizer &&
                      !store.demo &&
                      ['removed', 'left'].contains(m.status)
                ? IconButton(
                    tooltip: 'Allow a new invitation',
                    icon: const Icon(Icons.person_add_alt),
                    onPressed: () async {
                      if (await confirm(
                        'Invite ${m.name} again?',
                        'They can rejoin using an active invite code. Access stays closed until they join.',
                      )) {
                        await run('reinvite_member', {
                          'trip_id': t.id,
                          'user_id': m.id,
                        });
                      }
                    },
                  )
                : null,
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if ((t.data['whatsapp_url'] as String? ?? '').isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => openLink(t.data['whatsapp_url'] as String),
                icon: const Icon(Icons.forum_outlined),
                label: const Text('WhatsApp group'),
              ),
            if (store.organizer)
              TextButton(
                onPressed: canEdit
                    ? () async {
                        final v = await showFields(
                          context,
                          'WhatsApp group',
                          {'url': 'WhatsApp invite link'},
                          initial: {
                            'url': t.data['whatsapp_url'] as String? ?? '',
                          },
                          optional: {'url'},
                        );
                        if (v != null) {
                          await run('whatsapp', {'trip_id': t.id, ...v});
                        }
                      }
                    : null,
                child: const Text('Set group link'),
              ),
          ],
        ),
        section('Announcements'),
        for (final e in store.snapshot.entries(t.id, 'announcement').reversed)
          entryTile(e),
        section(
          'Packing and tasks',
          action: IconButton(
            tooltip: 'Add task',
            onPressed: canEdit ? () => addEntry('task') : null,
            icon: const Icon(Icons.add),
          ),
        ),
        for (final e in store.snapshot.entries(t.id, 'task')) entryTile(e),
        section(
          'Meeting points',
          action: IconButton(
            tooltip: 'Add meeting point',
            onPressed: canEdit ? () => addEntry('meeting') : null,
            icon: const Icon(Icons.add),
          ),
        ),
        for (final e in store.snapshot.entries(t.id, 'meeting')) entryTile(e),
        section(
          'Shared emergency contacts',
          action: IconButton(
            tooltip: 'Add contact',
            onPressed: canEdit ? () => addEntry('contact') : null,
            icon: const Icon(Icons.add),
          ),
        ),
        for (final e in store.snapshot.entries(t.id, 'contact')) entryTile(e),
        if (store.organizer)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: canEdit ? () => addEntry('announcement') : null,
              icon: const Icon(Icons.campaign_outlined),
              label: const Text('Post announcement'),
            ),
          ),
        section('Trip management'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton.icon(
              onPressed: store.offline
                  ? null
                  : () => createTrip(duplicate: true),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Duplicate as template'),
            ),
            if (store.organizer)
              OutlinedButton.icon(
                onPressed: store.offline
                    ? null
                    : () async {
                        if (await confirm(
                          t.archived ? 'Restore trip?' : 'Archive trip?',
                          t.archived ? 'Allow changes to this trip again.' : 'Keep this trip readable and pause edits and reminders.',
                        )) {
                          await run('archive_trip', {
                            'trip_id': t.id,
                            'archived': !t.archived,
                          });
                        }
                      },
                icon: Icon(
                  t.archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                label: Text(t.archived ? 'Restore' : 'Archive'),
              ),
          ],
        ),
        if (store.organizer) ...[
          section('Invitations'),
          for (final inv in rows(
            store.snapshot.data['invites'],
          ).where((i) => i['trip_id'] == t.id))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                inv['revoked_at'] == null
                    ? 'Expires ${formatDate(inv['expires_at'] as String)}'
                    : 'Revoked',
              ),
              subtitle: Text('${inv['use_count']} uses'),
              trailing: inv['revoked_at'] == null
                  ? IconButton(
                      tooltip: 'Revoke invitation',
                      onPressed: canEdit
                          ? () => run('revoke_invite', {
                              'trip_id': t.id,
                              'id': inv['id'],
                            })
                          : null,
                      icon: const Icon(Icons.link_off),
                    )
                  : null,
            ),
        ],
        section('Activity'),
        ...activity(),
      ],
    );
  }

  List<Widget> activity() => rows(store.snapshot.data['activity'])
      .where((a) => a['trip_id'] == store.selectedTrip)
      .map(
        (a) => ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.history, size: 20),
          title: Text(a['detail'] as String),
          subtitle: Text(
            '${store.snapshot.name(store.selectedTrip!, a['actor_id'] as String? ?? '')} · ${formatDate(a['created_at'] as String)}',
          ),
        ),
      )
      .toList();
  Future<void> notifications() async {
    await showDialog<void>(
      context: context,
      builder: (c) => ListenableBuilder(
        listenable: store,
        builder: (c, _) => AlertDialog(
          title: const Text('Notifications'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (rows(store.snapshot.data['notifications']).isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('You are all caught up.'),
                    ),
                  for (final n in rows(store.snapshot.data['notifications']))
                    ListTile(
                      leading: Icon(
                        n['read_at'] == null ? Icons.circle : Icons.check,
                        size: 16,
                      ),
                      title: Text(n['title'] as String),
                      subtitle: Text(formatDate(n['created_at'] as String)),
                      onTap: () async {
                        await run('read_notification', {'id': n['id']});
                        store.selectTrip(n['trip_id'] as String);
                        if (c.mounted) Navigator.pop(c);
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> settings() async {
    await showDialog<void>(
      context: context,
      builder: (c) => ListenableBuilder(
        listenable: store,
        builder: (c, _) => AlertDialog(
          title: const Text('Profile and settings'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (store.demo) ...[
                    const Text('Demo traveler'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: store.demoUser,
                      items: const [
                        DropdownMenuItem(
                          value: 'demo-asha',
                          child: Text('Asha (organizer)'),
                        ),
                        DropdownMenuItem(
                          value: 'demo-rahul',
                          child: Text('Rahul'),
                        ),
                        DropdownMenuItem(
                          value: 'demo-meera',
                          child: Text('Meera'),
                        ),
                      ],
                      onChanged: (v) => store.switchDemoUser(v!),
                    ),
                    TextButton(
                      onPressed: () => store.resetDemo(),
                      child: const Text('Reset demo trip'),
                    ),
                  ] else ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        (store.snapshot.data['profile']
                                    as Map?)?['display_name']
                                as String? ??
                            'Traveler',
                      ),
                      trailing: IconButton(
                        tooltip: 'Edit name',
                        onPressed: () async {
                          final v = await showFields(context, 'Display name', {
                            'name': 'Name',
                          });
                          if (v != null) await run('profile', v);
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Deadline reminders'),
                      value:
                          (store.snapshot.data['profile']
                              as Map?)?['reminders_enabled'] !=
                          false,
                      onChanged: store.offline
                          ? null
                          : (v) => run('profile', {'reminders_enabled': v}),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await PushNotifications.enable(store);
                          message('Push notifications enabled.');
                        } catch (e) {
                          message(friendlyError(e));
                        }
                      },
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Enable push notifications'),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          await PushNotifications.disable(store);
                          message(
                            'Push notifications disabled on this device.',
                          );
                        } catch (e) {
                          message(friendlyError(e));
                        }
                      },
                      child: const Text('Disable push on this device'),
                    ),
                    TextButton(
                      onPressed: () =>
                          shareText(jsonEncode(store.snapshot.data)),
                      child: const Text('Export account data'),
                    ),
                    TextButton(
                      onPressed: () async {
                        if (await confirm(
                          'Request account deletion?',
                          'Your request will be recorded for review. Shared financial history may need to be retained for other participants.',
                        )) {
                          final result = await run('profile', {
                            'request_deletion': true,
                          });
                          if (result != null) {
                            message('Deletion request recorded.');
                          }
                        }
                      },
                      child: const Text('Request account deletion'),
                    ),
                  ],
                  TextButton(
                    onPressed: () async {
                      if (!store.demo) {
                        await PushNotifications.unregister(store);
                      }
                      await store.signOut();
                      if (c.mounted) Navigator.pop(c);
                    },
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget section(String title, {Widget? action}) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        ?action,
      ],
    ),
  );
  Widget stat(String label, String value, Color color) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 115),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: LayoverColors.muted),
        ),
        const SizedBox(height: 7),
        Text(value, style: Theme.of(context).textTheme.titleLarge),
      ],
    ),
  );
  Widget empty(String text, {required IconData icon, Widget? action}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: const BoxDecoration(
                color: LayoverColors.wash,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: LayoverColors.ink),
            ),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      );
}

String tripDate(String value) {
  try {
    return DateFormat('d MMM').format(DateTime.parse(value));
  } catch (_) {
    return value;
  }
}

String formatDate(String value) {
  try {
    return DateFormat('d MMM, HH:mm').format(DateTime.parse(value).toLocal());
  } catch (_) {
    return value;
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.store});
  final TripStore store;
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool busy = false;
  String? error = Uri.base.queryParameters.containsKey('error')
      ? 'Sign-in could not be completed. Please try again.'
      : null;
  String? status;

  Future<void> signIn() async {
    setState(() {
      busy = true;
      error = null;
      status = null;
    });
    try {
      await widget.store.signInWithGoogle();
      if (mounted) {
        setState(
          () => status =
              'Finish signing in with Google in your browser. '
              'If you closed it, tap Continue with Google to try again.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        'Layover',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const Spacer(),
                      const Icon(Icons.north_east, size: 24),
                    ],
                  ),
                  const SizedBox(height: 44),
                  Text(
                    'Less planning.\nMore going.',
                    style:
                        Theme.of(context).textTheme.displaySmall ??
                        const TextStyle(
                          fontSize: 46,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'A good trip starts with your people.\nBring the plans, the pot and everyone together.',
                    style: TextStyle(color: LayoverColors.muted, height: 1.6),
                  ),
                  const SizedBox(height: 16),
                  const TravelSketch(height: 210),
                  const SizedBox(height: 28),
                  if (widget.store.configured) ...[
                    FilledButton(
                      onPressed: busy ? null : signIn,
                      child: Text(
                        busy ? 'Opening Google…' : 'Continue with Google',
                      ),
                    ),
                    if (error ?? widget.store.authError ?? status
                        case final message?)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            message,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color:
                                  error != null ||
                                      widget.store.authError != null
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: busy ? null : () => widget.store.startDemo(),
                    child: const Text('Explore demo trip'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
