import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../companion/data/trip_store.dart';
import '../companion/domain/models.dart';

class PlannerCard extends StatelessWidget {
  const PlannerCard({super.key, required this.store});
  final TripStore store;
  @override
  Widget build(BuildContext context) {
    if (!store.organizer || store.trip == null) return const SizedBox.shrink();
    final funded = [
      'target_reached',
      'booked',
    ].contains(store.snapshot.pot(store.trip!.id)?['status']);
    return Card(
      color: LayoverColors.wash,
      child: ListTile(
        leading: const Icon(Icons.auto_awesome_outlined),
        title: Text(
          funded ? 'Your pot. Your possible trip.' : 'Plan from the shared pot',
        ),
        subtitle: Text(
          funded
              ? 'Review stays, daily plans and booking links.'
              : 'Set preferences. Get options when the pot fills.',
        ),
        trailing: const Icon(Icons.arrow_forward),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlannerScreen(store: store, tripId: store.trip!.id),
          ),
        ),
      ),
    );
  }
}

String plannerMoney(dynamic minor) =>
    'INR ${((minor as num? ?? 0) / 100).toStringAsFixed(2)}';

class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key, required this.store, required this.tripId});
  final TripStore store;
  final String tripId;
  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends State<PlannerScreen> {
  late final String account = widget.store.userId;
  TripStore get store => widget.store;
  Trip? get trip =>
      store.snapshot.trips.where((t) => t.id == widget.tripId).firstOrNull;
  bool get accessible =>
      store.userId == account &&
      store.signedIn &&
      trip?.organizer == account &&
      store.snapshot
          .members(widget.tripId)
          .any((m) => m.id == account && m.active);
  bool get editable => accessible && trip?.archived == false && !store.offline;
  Json? plan;
  bool loading = true, busy = false, editing = false, fetching = false;
  String? error;
  Timer? timer;
  int option = 0;
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  String transport = 'transit';

  @override
  void initState() {
    super.initState();
    store.addListener(changed);
    unawaited(load());
    timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!busy && !editing) unawaited(load(silent: true));
    });
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    timer?.cancel();
    store.removeListener(changed);
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  String readableError(Object e) {
    final message = e.toString();
    if (message.contains('PGRST202') || message.contains('PGRST205')) {
      return 'Trip planning needs its database update. Apply the trip planner migration, then retry.';
    }
    return friendlyError(e);
  }

  Future<void> load({bool silent = false}) async {
    if (!accessible || fetching || store.demo) {
      if (mounted && !silent) setState(() => loading = false);
      return;
    }
    fetching = true;
    try {
      final result = await store.client!
          .rpc('planner_state', params: {'p_trip_id': widget.tripId})
          .timeout(const Duration(seconds: 20));
      if (!mounted || !accessible) return;
      setState(() {
        plan = result == null ? null : Map<String, dynamic>.from(result as Map);
        if (option >= rows(plan?['result']?['options']).length) option = 0;
        if (plan?['state'] == 'shared') {
          option = plan?['selected_option'] as int? ?? 0;
        }
        error = null;
      });
    } catch (e) {
      if (mounted && accessible) setState(() => error = readableError(e));
    } finally {
      fetching = false;
      if (mounted) setState(() => loading = false);
    }
  }

  void edit() {
    final count = store.snapshot
        .members(widget.tripId)
        .where((m) => m.active)
        .length;
    final initial = <String, dynamic>{
      'rooms': (count / 2).ceil(),
      'adults_per_room': 2,
      'food_daily_minor': 80000,
      'transport_daily_minor': 150000,
      'activity_daily_minor': 30000,
      'journey_minor': 0,
      'origin': '',
      'food_preferences': '',
      ...?plan?['settings'] as Map<String, dynamic>?,
    };
    for (final key in initial.keys.where((k) => k != 'transport_mode')) {
      final value = initial[key];
      fields
          .putIfAbsent(key, TextEditingController.new)
          .text = key.endsWith('_minor')
          ? ((value as num) / 100).toStringAsFixed(2)
          : value.toString();
    }
    transport = plan?['settings']?['transport_mode'] as String? ?? 'transit';
    setState(() => editing = true);
  }

  Future<void> save({bool reuse = false}) async {
    if (!editable ||
        busy ||
        store.demo ||
        (!reuse && !form.currentState!.validate())) {
      return;
    }
    Json settings;
    try {
      settings = reuse
          ? Map<String, dynamic>.from(plan!['settings'] as Map)
          : {
              for (final e in fields.entries)
                e.key: e.key.endsWith('_minor')
                    ? (e.value.text.trim() == '0' ||
                              double.tryParse(e.value.text) == 0
                          ? 0
                          : parseMoney(e.value.text))
                    : ['rooms', 'adults_per_room'].contains(e.key)
                    ? int.parse(e.value.text)
                    : e.value.text.trim(),
              'transport_mode': transport,
            };
    } catch (_) {
      setState(
        () => error =
            'Use whole numbers for rooms and up to two decimals for amounts.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await store.client!
          .rpc(
            'planner_configure',
            params: {
              'p_trip_id': widget.tripId,
              'p_settings': settings,
              'p_revision': plan?['revision'] ?? 0,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted || !accessible) return;
      setState(() {
        plan = Map<String, dynamic>.from(result as Map);
        editing = false;
      });
      await runWorker();
    } catch (e) {
      if (mounted && accessible) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> runWorker() async {
    if (!editable || store.demo) return;
    try {
      await store.client!.functions
          .invoke('trip-planner', body: {'trip_id': widget.tripId})
          .timeout(const Duration(seconds: 65));
      await load();
    } catch (_) {
      if (mounted && accessible) {
        setState(
          () => error = 'Your request is saved. Planning has not responded yet. Refresh to check; the app owner may need to finish planner setup.',
        );
      }
    }
  }

  Future<void> publish() async {
    if (!editable || busy || plan == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await store.client!
          .rpc(
            'planner_publish',
            params: {
              'p_trip_id': widget.tripId,
              'p_run_id': plan!['run_id'],
              'p_option': option,
            },
          )
          .timeout(const Duration(seconds: 25));
      await store.refresh(silent: true);
      await load();
      if (mounted && accessible) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Shared to Plan, Bookings and Group.${(result['preserved'] as num? ?? 0) > 0 ? ' Your edited entries were kept.' : ''}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted && accessible) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> open(String? value) async {
    final uri = Uri.tryParse(value ?? '');
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return;
    }
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('open');
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Could not open this link.');
    }
  }

  Future<void> shareDay(Json day) async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text:
              '${trip!.title} · ${day['date']}\n${rows(day['stops']).map((s) => '${s['time']} ${s['name']}\n${s['url'] ?? ''}').join('\n')}\nSuggested times; check opening hours and fares.',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not open sharing. Please try again.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = rows(plan?['result']?['options']);
    final state = plan?['state'];
    final stale = plan?['stale'] == true;
    final selected = options.isEmpty
        ? null
        : options[option.clamp(0, options.length - 1)];
    return Scaffold(
      appBar: AppBar(
        title: const Text('From pot to plan'),
        actions: [
          IconButton(
            tooltip: 'Refresh plan',
            onPressed: busy ? null : () => load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !accessible
          ? const Center(child: Text('Organizer access required.'))
          : loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView(
                  padding: const EdgeInsets.all(22),
                  children: [
                    Text(
                      trip!.destination.isEmpty
                          ? trip!.title
                          : trip!.destination,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    Text('${trip!.start} → ${trip!.end}'),
                    const SizedBox(height: 16),
                    Text(
                      plannerMoney(
                        store.snapshot.pot(
                          widget.tripId,
                        )?['target_minor_units'],
                      ),
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const Text('Shared pot · confirmed external contributions'),
                    const SizedBox(height: 20),
                    if (store.demo)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: Text(
                            'Live trip planning uses real hotel and place searches. Sign in and create a funded trip to use it. Explore within budget remains available in demo.',
                          ),
                        ),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (busy) const LinearProgressIndicator(),
                    if (!store.demo && plan == null && !editing) ...[
                      const Text(
                        'Choose room occupancy, food preferences and daily allowances. Once the pot is funded, your leader-only options will be generated automatically.',
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: editable && error == null ? edit : null,
                        icon: const Icon(Icons.tune),
                        label: const Text('Set planning preferences'),
                      ),
                    ],
                    if (!store.demo && plan != null && !editing) ...[
                      Text(switch (state) {
                        'waiting' => 'Waiting for confirmed funding',
                        'queued' => 'Plan queued',
                        'running' => 'Finding stays and places…',
                        'ready' => 'Ready for your review',
                        'shared' => 'Shared with your trip',
                        _ => 'Planning needs attention',
                      }, style: Theme.of(context).textTheme.titleLarge),
                      if (stale)
                        const Text(
                          'Trip details have changed. Request an updated plan before sharing.',
                        ),
                      if (plan?['funded'] == false)
                        const Text(
                          'The pot needs enough confirmed contributions and acceptance of its current terms.',
                        ),
                      if (plan?['error'] != null)
                        Text(plan!['error'].toString()),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: editable && !busy ? edit : null,
                            icon: const Icon(Icons.tune),
                            label: const Text('Edit preferences'),
                          ),
                          TextButton.icon(
                            onPressed: editable && !busy
                                ? () => save(reuse: true)
                                : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Request fresh options'),
                          ),
                          if (['queued', 'waiting', 'running'].contains(state))
                            TextButton(
                              onPressed: editable && !busy
                                  ? () async {
                                      setState(() => busy = true);
                                      await runWorker();
                                      if (mounted) setState(() => busy = false);
                                    }
                                  : null,
                              child: const Text('Check generation'),
                            ),
                        ],
                      ),
                    ],
                    if (editing) preferences(),
                    if (!editing && selected != null) ...[
                      Text(
                        plan!['result']['source'].toString(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        'Checked ${plan!['result']['checked_at']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(plan!['result']['occupancy_note'].toString()),
                      const SizedBox(height: 12),
                      for (final warning
                          in plan!['result']['warnings'] as List? ?? [])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('• $warning'),
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (var i = 0; i < options.length; i++)
                            ChoiceChip(
                              label: Text('Option ${i + 1}'),
                              selected: option == i,
                              onSelected: state == 'shared'
                                  ? null
                                  : (_) => setState(() => option = i),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        selected['hotel']['name'].toString(),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if (selected['hotel']['rating'] != null)
                        Text(
                          '${selected['hotel']['rating']}/5 · ${selected['hotel']['reviews']} reviews',
                        ),
                      if (selected['hotel']['quote_note'] != null)
                        Text(selected['hotel']['quote_note'].toString()),
                      if (selected['hotel']['url'] != null)
                        TextButton.icon(
                          onPressed: () =>
                              open(selected['hotel']['url'] as String),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Check stay and book'),
                        ),
                      const Divider(height: 32),
                      for (final cost in (selected['costs'] as Map).entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  {
                                        'stay': 'Stay · listed estimate',
                                        'food': 'Meals · allowance',
                                        'transport': 'Local travel · allowance',
                                        'activities': 'Activities · allowance',
                                        'journey': 'Return journey · allowance',
                                        'reserve': 'Reserve · 10%',
                                      }[cost.key] ??
                                      cost.key.toString(),
                                ),
                              ),
                              Text(plannerMoney(cost.value)),
                            ],
                          ),
                        ),
                      const Divider(),
                      Text(
                        'Planned total ${plannerMoney(selected['total_minor'])}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        '${plannerMoney(selected['remaining_minor'])} left in the pot',
                      ),
                      const SizedBox(height: 20),
                      if (state != 'shared')
                        FilledButton.icon(
                          onPressed:
                              editable &&
                                  !busy &&
                                  !stale &&
                                  plan?['funded'] == true
                              ? publish
                              : null,
                          icon: const Icon(Icons.groups_outlined),
                          label: const Text('Share full itinerary with group'),
                        ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'Sharing fills Plan, the booking checklist, packing/tasks and a group announcement. Confirm reservations through the links, then record actual payments in Expenses.',
                        ),
                      ),
                      for (final day in rows(selected['days'])) dayCard(day),
                      const SizedBox(height: 12),
                      Text(
                        'Suggested packing & tasks',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      for (final e in rows(
                        selected['entries'],
                      ).where((e) => e['kind'] == 'task'))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.check_box_outline_blank),
                          title: Text(e['title'].toString()),
                          subtitle: Text(e['details']['notes'].toString()),
                        ),
                    ],
                    if (!editing &&
                        plan?['result'] != null &&
                        options.isEmpty) ...[
                      for (final warning
                          in plan!['result']['warnings'] as List? ?? [])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(warning.toString()),
                        ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget dayCard(Json day) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  day['date'].toString(),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Share this day',
                onPressed: () => shareDay(day),
                icon: const Icon(Icons.ios_share),
              ),
            ],
          ),
          Text(
            day['weather'] == null
                ? 'Forecast not available for this date'
                : '${day['weather']['low_c']}–${day['weather']['high_c']}°C · ${day['weather']['rain_percent']}% chance of rain',
          ),
          for (final stop in rows(day['stops']))
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${stop['time']}  ${stop['name']}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (stop['rating'] != null)
                    Text('${stop['rating']}/5 · ${stop['reviews']} reviews'),
                  if (stop['cuisine'] != null) Text(stop['cuisine'].toString()),
                  if ((stop['description'] as String? ?? '').isNotEmpty)
                    Text(stop['description'].toString()),
                  if ((stop['price_label'] as String? ?? '').isNotEmpty)
                    Text(
                      'Listing price guide: ${stop['price_label']} · exact meal price unverified',
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (stop['url'] != null)
                        TextButton(
                          onPressed: () => open(stop['url'] as String),
                          child: const Text('Place & reviews'),
                        ),
                      if (stop['directions_url'] != null)
                        TextButton(
                          onPressed: () =>
                              open(stop['directions_url'] as String),
                          child: Text('${stop['mode']} directions'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
  Widget preferences() => Form(
    key: form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Amounts below are allowances for the whole trip budget. Keep room in the pot for the stay and a 10% reserve. Hotel searches use adults per room; confirm children and special needs with the seller.',
        ),
        for (final label in const {
          'rooms': 'Rooms needed',
          'adults_per_room': 'Adults per room (1–4)',
          'origin': 'Departure city (optional)',
          'food_preferences': 'Food preferences, e.g. vegetarian Kerala food',
          'food_daily_minor': 'Meals per person per day (INR)',
          'transport_daily_minor': 'Local transport for group per day (INR)',
          'activity_daily_minor': 'Activities per person per day (INR)',
          'journey_minor': 'Return journey for whole group (INR)',
        }.entries)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TextFormField(
              controller: fields[label.key],
              decoration: InputDecoration(labelText: label.value),
              maxLength: ['origin', 'food_preferences'].contains(label.key)
                  ? 160
                  : null,
              keyboardType: ['origin', 'food_preferences'].contains(label.key)
                  ? TextInputType.text
                  : const TextInputType.numberWithOptions(decimal: true),
              validator: (v) =>
                  ['origin', 'food_preferences'].contains(label.key) ||
                      RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(v?.trim() ?? '')
                  ? null
                  : 'Enter a valid amount',
            ),
          ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: transport,
          decoration: const InputDecoration(
            labelText: 'Preferred local transport',
          ),
          items: const [
            DropdownMenuItem(value: 'transit', child: Text('Public transport')),
            DropdownMenuItem(value: 'driving', child: Text('Cab or car')),
            DropdownMenuItem(value: 'walking', child: Text('Walking')),
          ],
          onChanged: (v) => transport = v!,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy ? null : save,
          child: const Text('Save & plan when funded'),
        ),
        TextButton(
          onPressed: busy ? null : () => setState(() => editing = false),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
