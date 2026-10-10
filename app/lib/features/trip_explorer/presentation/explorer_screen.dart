import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme.dart';
import '../../../app/travel_sketch.dart';
import '../../companion/data/trip_store.dart';
import '../data/explorer_repository.dart';
import '../domain/explorer.dart';
import 'explorer_forms.dart';
import 'explorer_map.dart';

class ExplorerScreen extends StatefulWidget {
  const ExplorerScreen({super.key, required this.trip, required this.tripId});
  final TripStore trip;
  final String tripId;
  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen> {
  late final ExplorerRepository repository;
  late Json settings;
  List<Json> places = [], allowances = [], itineraries = [], versions = [];
  String? error, message, parentId, saveId;
  String category = 'all';
  int page = 0, selectedCandidate = 0;
  bool busy = false, dirty = true;
  final title = TextEditingController(text: 'A day to explore');
  @override
  void initState() {
    super.initState();
    repository = ExplorerRepository(widget.trip, widget.tripId);
    final date =
        DateTime.tryParse(widget.trip.trip?.start ?? '') ?? DateTime.now();
    final start = DateTime(date.year, date.month, date.day, 9);
    final origin = widget.trip.demo
        ? <double>[73.8278, 15.4909]
        : <double>[0, 20];
    settings = {
      'currency': 'INR',
      'budget_minor': 1000000,
      'group_size': widget.trip.members
          .where((m) => m.active)
          .length
          .clamp(1, 50),
      'start_at': start.toUtc().toIso8601String(),
      'end_at': start.add(const Duration(hours: 8)).toUtc().toIso8601String(),
      'origin': origin,
      'destination': null,
      'zone': {'type': 'circle', 'center': origin, 'radius_m': 5000},
      'caps': <String, dynamic>{},
      'modes': ['walk', 'drive'],
      'keep_order': false,
    };
    if (!repository.editable) page = 3;
    widget.trip.addListener(tripChanged);
    unawaited(
      run(() async {
        versions = await repository.versions();
      }),
    );
  }

  void tripChanged() {
    if (!mounted) return;
    if (!repository.accessible) {
      places = [];
      allowances = [];
      itineraries = [];
      versions = [];
    }
    setState(() {});
  }

  @override
  void dispose() {
    repository.close();
    widget.trip.removeListener(tripChanged);
    title.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) error = e is FormatException ? e.message : 'The request failed. Your saved versions are unchanged. Retry when connected.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void changed({bool clearCandidates = true}) {
    dirty = true;
    saveId = null;
    message = null;
    if (clearCandidates) {
      itineraries = [];
      selectedCandidate = 0;
    }
  }

  Future<void> configure() async {
    final value = await settingsForm(
      context,
      settings,
      currencyLocked: places.isNotEmpty || allowances.isNotEmpty,
    );
    if (value == null || !mounted || !repository.editable) return;
    setState(() {
      settings = value;
      changed();
    });
  }

  Future<void> discover() => run(() async {
    validateSettings(settings);
    final result = await repository.discover(
      Zone(Map<String, dynamic>.from(settings['zone'])),
      category,
      settings['currency'],
    );
    if (!mounted || !repository.editable) return;
    final old = {for (final p in places) p['id']: p};
    places = [
      for (final p in result) old[p['id']] ?? p,
      for (final p in places)
        if (p['selection_type'] != 'excluded' &&
            !result.any((r) => r['id'] == p['id']))
          p,
    ];
    changed();
    page = 1;
    if (result.isEmpty) {
      message = 'No places found. Try a larger area or another category.';
    }
  });
  Future<void> generate() => run(() async {
    final failures = <String>[];
    final result = await generateItineraries(
      settings,
      places,
      allowances,
      repository.routes,
      failures: failures,
    );
    if (!mounted || !repository.editable) return;
    changed();
    itineraries = result;
    page = 2;
    message = result.isEmpty
        ? 'No routes available. Check selections, time window and provider coverage.'
        : failures.isNotEmpty
        ? 'Some routes were unavailable. ${failures.first}'
        : result.length < 3
        ? '${result.length} distinct option(s) available for these stops and modes.'
        : null;
  });
  Json snapshot() {
    Json recalculate(Json c) {
      final total = totalCosts(
        rows(c['costs']),
        settings['group_size'],
        settings['currency'],
      );
      return {
        ...copyJson(c),
        'total_low_minor': total.low,
        'total_high_minor': total.high,
        'unknown_count': total.unknown,
        'budget_state': budgetState(total, settings),
        'route_alternatives': rows(c['route_alternatives'])
            .map(recalculate)
            .toList(),
      };
    }

    return {
      'schema_version': 1,
      'settings': copyJson(settings),
      'places': places.map(copyJson).toList(),
      'allowances': allowances.map(copyJson).toList(),
      'itineraries': itineraries.map(recalculate).toList(),
      'selected_candidate': selectedCandidate,
    };
  }

  Future<void> save() => run(() async {
    if (title.text.trim().isEmpty || title.text.trim().length > 120) {
      throw const FormatException('Enter a title of 1–120 characters.');
    }
    final result = await repository.save(
      saveId ??= repository.newId(),
      title.text.trim(),
      snapshot(),
      parentId,
    );
    if (!mounted || !repository.editable) return;
    final saved = Map<String, dynamic>.from(result['snapshot']);
    places = rows(saved['places']);
    allowances = rows(saved['allowances']);
    itineraries = rows(saved['itineraries']);
    parentId = result['id'];
    saveId = null;
    dirty = false;
    versions = await repository.versions();
    message = 'Saved version ${result['version']}.';
  });
  void open(Json version) {
    final s = copyJson(Map<String, dynamic>.from(version['snapshot']));
    setState(() {
      settings = Map<String, dynamic>.from(s['settings']);
      places = rows(s['places']);
      allowances = rows(s['allowances']);
      itineraries = rows(s['itineraries']);
      selectedCandidate = (s['selected_candidate'] as int? ?? 0).clamp(
        0,
        itineraries.isEmpty ? 0 : itineraries.length - 1,
      );
      title.text = version['title'];
      parentId = version['id'];
      saveId = null;
      dirty = false;
      page = itineraries.isEmpty ? 1 : 2;
      message =
          'Viewing version ${version['version']}. Edits will create another version.';
    });
  }

  Future<void> editPlace(Json p) async {
    final dwell = TextEditingController(text: '${p['dwell_minutes']}');
    final priority = TextEditingController(text: '${p['priority']}');
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(p['name']),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: dwell,
              decoration: const InputDecoration(
                labelText: 'Visit minutes (0–480)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: priority,
              decoration: const InputDecoration(labelText: 'Priority (1–5)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final d = int.tryParse(dwell.text),
                  v = int.tryParse(priority.text);
              if (d != null &&
                  d >= 0 &&
                  d <= 480 &&
                  v != null &&
                  v >= 1 &&
                  v <= 5) {
                Navigator.pop(context, (d, v));
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (result != null && mounted && repository.editable) {
      setState(() {
        p['dwell_minutes'] = result.$1;
        p['priority'] = result.$2;
        changed();
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    dwell.dispose();
    priority.dispose();
  }

  Future<void> editCost(
    Json item,
    void Function(Json) replace, {
    bool candidate = false,
  }) async {
    final value = await costForm(context, item, repository.userId);
    if (value != null && mounted && repository.editable) {
      setState(() {
        replace(value);
        changed(clearCandidates: !candidate);
      });
    }
  }

  Widget heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 10),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
  Widget notice(String text, {bool warning = false}) => Card(
    color: warning ? const Color(0xFFF8EBE7) : LayoverColors.wash,
    child: Padding(padding: const EdgeInsets.all(16), child: Text(text)),
  );
  bool get editable => repository.editable && !busy;
  @override
  Widget build(BuildContext context) {
    if (!repository.accessible) {
      return Scaffold(
        appBar: AppBar(title: const Text('Trip explorer')),
        body: const Center(
          child: Text('This trip is no longer available to this account.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore within budget'),
        actions: [
          IconButton(
            tooltip: 'Saved versions',
            onPressed: () => setState(() => page = 3),
            icon: const Icon(Icons.history),
          ),
        ],
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: AbsorbPointer(
              absorbing: busy,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const PageIntro(
                          title: 'A little further.',
                          subtitle: 'Find the places worth going. Keep your budget in view.',
                        ),
                        if (repository.demo)
                          notice(
                            'Demo · places, positions and routes are synthetic. Costs are planning assumptions.',
                          ),
                        if (!repository.editable)
                          notice(
                            'Shared plans for your trip. The organizer can edit and share versions.',
                          ),
                        if (error != null) notice(error!, warning: true),
                        if (message != null) notice(message!),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final entry in [
                              (0, 'Budget & area'),
                              (1, 'Places'),
                              (2, 'Compare'),
                              (3, 'Saved'),
                            ])
                              ChoiceChip(
                                label: Text(entry.$2),
                                selected: page == entry.$1,
                                onSelected: (_) =>
                                    setState(() => page = entry.$1),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (page != 3)
                          TextField(
                            controller: title,
                            enabled: editable,
                            decoration: const InputDecoration(
                              labelText: 'Plan title',
                            ),
                            onChanged: (_) =>
                                setState(() => changed(clearCandidates: false)),
                          ),
                        if (page == 0) ...area(),
                        if (page == 1) ...selection(),
                        if (page == 2) ...comparison(),
                        if (page == 3) ...history(),
                        if (page != 3 && repository.editable) ...[
                          const SizedBox(height: 20),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: editable && dirty ? save : null,
                                icon: const Icon(Icons.save_outlined),
                                label: const Text('Save new version'),
                              ),
                              if (parentId != null &&
                                  !dirty &&
                                  itineraries.isNotEmpty)
                                OutlinedButton.icon(
                                  onPressed: editable
                                      ? () => run(() async {
                                          await repository.share(parentId!);
                                          versions = await repository
                                              .versions();
                                          message = 'Shared with current trip members.';
                                        })
                                      : null,
                                  icon: const Icon(Icons.group_outlined),
                                  label: const Text('Share with trip'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Proposed costs only. Saving and sharing do not change Trip Pot or payments.',
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          children: [
                            TextButton(
                              onPressed: () => launchUrl(
                                Uri.parse('https://www.geoapify.com/'),
                              ),
                              child: const Text('Powered by Geoapify'),
                            ),
                            TextButton(
                              onPressed: () => launchUrl(
                                Uri.parse(
                                  'https://www.openstreetmap.org/copyright',
                                ),
                              ),
                              child: const Text('© OpenStreetMap contributors'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> area() => [
    heading('Set the boundaries for your day'),
    Text(
      '${moneyText(settings['budget_minor'], settings['currency'])} group budget · ${settings['group_size']} travelers',
    ),
    Text('${settings['start_at']} → ${settings['end_at']}'),
    const SizedBox(height: 12),
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonal(
        onPressed: editable ? configure : null,
        child: const Text('Edit budget and area'),
      ),
    ),
    const SizedBox(height: 12),
    Wrap(
      spacing: 8,
      children: [
        for (final shape in ['circle', 'polygon'])
          ChoiceChip(
            label: Text(shape == 'circle' ? 'Radius' : 'Polygon'),
            selected: settings['zone']['type'] == shape,
            onSelected: editable
                ? (_) => setState(() {
                    settings['zone'] = shape == 'circle'
                        ? {
                            'type': 'circle',
                            'center': settings['origin'],
                            'radius_m': 5000,
                          }
                        : {'type': 'polygon', 'vertices': <List<double>>[]};
                    places = [];
                    changed();
                  })
                : null,
          ),
      ],
    ),
    const SizedBox(height: 8),
    Text(
      settings['zone']['type'] == 'circle'
          ? 'Tap to set the area center and starting point.'
          : 'Tap 3–20 vertices around the area. Use Undo to correct the boundary.',
    ),
    const SizedBox(height: 8),
    SizedBox(
      height: 320,
      child: ExplorerMap(
        zone: Map<String, dynamic>.from(settings['zone']),
        places: places,
        origin: coordinate(settings['origin']),
        demo: repository.demo,
        onPoint: !editable
            ? null
            : (point) => setState(() {
                if (settings['zone']['type'] == 'circle') {
                  settings['origin'] = point;
                  settings['zone']['center'] = point;
                } else {
                  final vertices = settings['zone']['vertices'] as List;
                  if (vertices.length < 20) vertices.add(point);
                }
                places = [];
                changed();
              }),
      ),
    ),
    if (settings['zone']['type'] == 'polygon')
      Wrap(
        spacing: 12,
        children: [
          TextButton(
            onPressed: editable
                ? () => setState(() {
                    final v = settings['zone']['vertices'] as List;
                    if (v.isNotEmpty) v.removeLast();
                    places = [];
                    changed();
                  })
                : null,
            child: const Text('Undo vertex'),
          ),
          TextButton(
            onPressed: editable ? enterVertex : null,
            child: const Text('Enter vertex coordinates'),
          ),
          Text('${(settings['zone']['vertices'] as List).length} vertices'),
        ],
      ),
    const Text(
      'The zone limits place discovery. Routes may leave the zone. No live-location access is needed.',
    ),
    const SizedBox(height: 16),
    DropdownButtonFormField<String>(
      initialValue: category,
      decoration: const InputDecoration(labelText: 'Discover'),
      items: [
        'all',
        'culture',
        'nature',
        'food',
      ].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
      onChanged: editable ? (v) => setState(() => category = v!) : null,
    ),
    const SizedBox(height: 12),
    FilledButton(
      onPressed: editable ? discover : null,
      child: const Text('Find places'),
    ),
    ...allowanceWidgets(),
  ];
  Future<void> enterVertex() async {
    final lon = TextEditingController(), lat = TextEditingController();
    final p = await showDialog<List<double>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Polygon vertex'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: lon,
              decoration: const InputDecoration(labelText: 'Longitude'),
            ),
            TextField(
              controller: lat,
              decoration: const InputDecoration(labelText: 'Latitude'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              try {
                Navigator.pop(
                  context,
                  coordinate([double.parse(lon.text), double.parse(lat.text)]),
                );
              } catch (_) {
                /* Keep invalid input editable. */
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (p != null && mounted && editable) {
      setState(() {
        final v = settings['zone']['vertices'] as List;
        if (v.length < 20) v.add(p);
        places = [];
        changed();
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    lon.dispose();
    lat.dispose();
  }

  List<Widget> allowanceWidgets() => [
    heading('Allowances and contingency'),
    const Text(
      'Enter group or per-person allowances. Missing admission and driving fares remain unknown.',
    ),
    for (final item in allowances)
      costTile(
        item,
        () => editCost(item, (v) => allowances[allowances.indexOf(item)] = v),
      ),
    Wrap(
      spacing: 8,
      children: [
        for (final c in ['food', 'fees', 'contingency'])
          TextButton.icon(
            onPressed: editable
                ? () => editCost(
                    costItem(
                      repository.newId(),
                      c,
                      '$c allowance',
                      settings['currency'],
                    ),
                    allowances.add,
                  )
                : null,
            icon: const Icon(Icons.add),
            label: Text(c),
          ),
      ],
    ),
  ];
  List<Widget> selection() => [
    heading('Choose the places worth stopping for'),
    if (places.isEmpty)
      notice('Find places from Budget & area to start your shortlist.'),
    for (var i = 0; i < places.length; i++) placeCard(places[i], i),
    if (places.isNotEmpty) ...[
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Keep my stop order'),
        subtitle: const Text(
          'Use the arrows to order places before generating.',
        ),
        value: settings['keep_order'] == true,
        onChanged: editable
            ? (v) => setState(() {
                settings['keep_order'] = v;
                changed();
              })
            : null,
      ),
      FilledButton(
        onPressed: editable ? generate : null,
        child: const Text('Generate alternatives'),
      ),
    ],
  ];
  Widget placeCard(Json p, int index) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p['name'], style: Theme.of(context).textTheme.titleMedium),
          Text(
            '${p['category']} · ${p['dwell_minutes']} min · priority ${p['priority']}',
          ),
          Text(
            '${p['source']} · checked ${p['source_checked_at']}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final selection in ['must_visit', 'optional', 'excluded'])
                ChoiceChip(
                  label: Text(selection.replaceAll('_', ' ')),
                  selected: p['selection_type'] == selection,
                  onSelected: editable
                      ? (_) => setState(() {
                          p['selection_type'] = selection;
                          changed();
                        })
                      : null,
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: editable ? () => editPlace(p) : null,
                child: const Text('Visit time & priority'),
              ),
              TextButton(
                onPressed: editable
                    ? () => editCost(
                        Map<String, dynamic>.from(p['cost']),
                        (v) => p['cost'] = v,
                      )
                    : null,
                child: const Text('Admission cost'),
              ),
              IconButton(
                tooltip: 'Move earlier',
                onPressed: editable && index > 0
                    ? () => setState(() {
                        places.removeAt(index);
                        places.insert(index - 1, p);
                        changed();
                      })
                    : null,
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: 'Move later',
                onPressed: editable && index < places.length - 1
                    ? () => setState(() {
                        places.removeAt(index);
                        places.insert(index + 1, p);
                        changed();
                      })
                    : null,
                icon: const Icon(Icons.arrow_downward),
              ),
            ],
          ),
          Text(
            totalCosts(
              [Map<String, dynamic>.from(p['cost'])],
              settings['group_size'],
              settings['currency'],
            ).label(settings['currency']),
          ),
        ],
      ),
    ),
  );
  Widget costTile(Json item, VoidCallback edit) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(item['description']),
    subtitle: Text(
      '${item['estimate_status']} · ${item['cost_basis']} × ${item['quantity']}\n'
      '${item['source']} · ${item['confidence']}\nChecked ${item['checked_at']}${item['author'] == null ? '' : ' · by ${item['author']}'}',
    ),
    trailing: editable
        ? IconButton(
            tooltip: 'Edit cost',
            onPressed: edit,
            icon: const Icon(Icons.edit_outlined),
          )
        : null,
    isThreeLine: true,
  );
  List<Widget> comparison() {
    if (itineraries.isEmpty) {
      return [
        heading('Compare your options'),
        notice(
          'Select places and generate alternatives to compare routes and costs.',
        ),
      ];
    }
    final selected = itineraries[selectedCandidate];
    final costs = rows(selected['costs']);
    final total = totalCosts(
      costs,
      settings['group_size'],
      settings['currency'],
    );
    return [
      heading('A few ways to spend the day'),
      const Text(
        'Candidate recommendations, not a guaranteed optimum. Hours and availability need checking.',
      ),
      for (var i = 0; i < itineraries.length; i++)
        candidateCard(itineraries[i], i),
      const SizedBox(height: 12),
      SizedBox(
        height: 300,
        child: ExplorerMap(
          zone: Map<String, dynamic>.from(settings['zone']),
          places: rows(selected['stops']),
          origin: coordinate(settings['origin']),
          geometry: Map<String, dynamic>.from(selected['geometry']),
          demo: repository.demo,
          onPoint: null,
        ),
      ),
      heading('Stops and route legs'),
      if (selected['alternative_unavailable'] == true)
        notice(
          'The provider could not compare another path. The displayed route remains available.',
        ),
      Text(
        'Route source: ${selected['provider']} · checked ${selected['checked_at']} · ${selected['path_kind']}',
      ),
      for (var i = 0; i < rows(selected['stops']).length; i++)
        Text(
          '${i + 1}. ${rows(selected['stops'])[i]['name']} · ${rows(selected['stops'])[i]['dwell_minutes']} min',
        ),
      for (final leg in rows(selected['legs']))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.route_outlined),
          title: Text(
            'Leg ${(leg['leg_order'] as int) + 1} · ${leg['transport_mode']}',
          ),
          subtitle: Text(
            '${((leg['distance_m'] as num) / 1000).toStringAsFixed(1)} km · ${((leg['duration_seconds'] as int) / 60).ceil()} min',
          ),
        ),
      if (rows(selected['route_alternatives']).isNotEmpty) ...[
        heading('Other provider paths for the same stops'),
        for (final alt in rows(selected['route_alternatives']))
          TextButton(
            onPressed: editable
                ? () => setState(() {
                    itineraries[selectedCandidate] = {
                      ...alt,
                      'archetype': selected['archetype'],
                      'route_alternatives': [
                        {...selected, 'route_alternatives': <Json>[]},
                      ],
                    };
                    changed(clearCandidates: false);
                  })
                : null,
            child: Text(
              '${alt['path_kind']} · ${((alt['duration_seconds'] as int) / 60).ceil()} min',
            ),
          ),
      ],
      heading('Cost breakdown'),
      notice(
        '${budgetState(total, settings)}\nGroup: ${total.label(settings['currency'])}\nPer person: ${total.perPerson(settings['currency'], settings['group_size'])}',
        warning: budgetState(total, settings) != 'Within budget',
      ),
      if (selected['within_time'] != true)
        notice(
          'This itinerary exceeds the selected time window.',
          warning: true,
        ),
      const Text(
        'Per-person figures assume an equal split; rounding distributes remaining minor units. Unknown costs are additional.',
      ),
      const SizedBox(height: 12),
      for (final category in categories)
        if (costs.any((c) => c['category'] == category))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '$category: ${totalCosts(costs.where((c) => c['category'] == category).toList(), settings['group_size'], settings['currency']).label(settings['currency'])}',
            ),
          ),
      for (final item in costs) ...[
        if (costs.any(
          (c) =>
              List<String>.from(c['covers'] as List? ?? [])
                  .contains(item['id']),
        ))
          const Text('Covered by the whole-route fare; excluded from totals.'),
        costTile(
          item,
          () => editCost(item, (v) {
            costs[costs.indexOf(item)] = v;
            selected['costs'] = costs;
          }, candidate: true),
        ),
        Text(
          totalCosts(
            [
              {...item, 'covers': <String>[]},
            ],
            settings['group_size'],
            settings['currency'],
          ).label(settings['currency']),
        ),
      ],
      if (editable)
        TextButton(
          onPressed: () => editCost(
            costItem(
              'whole-route',
              'transport',
              'Whole-route fare',
              settings['currency'],
              basis: 'per_vehicle',
              covers: costs
                  .where((c) => '${c['id']}'.startsWith('leg:'))
                  .map((c) => c['id'] as String)
                  .toList(),
            ),
            (v) {
              selected['costs'] = [
                ...costs.where((c) => c['id'] != 'whole-route'),
                v,
              ];
            },
            candidate: true,
          ),
          child: const Text('Enter whole-route fare (replaces leg fares)'),
        ),
      const Text(
        'Editing stop order or visit times in Places clears these routes and generates a new comparison.',
      ),
    ];
  }

  Widget candidateCard(Json c, int i) {
    final total = totalCosts(
      rows(c['costs']),
      settings['group_size'],
      settings['currency'],
    );
    final reason = switch (c['archetype']) {
      'Budget-first' => 'Lower priced subtotal, with unknown costs shown.',
      'Time-first' => 'Less travel and visit time.',
      'Explore-more' => 'More selected places and category variety.',
      _ => 'Edited plan.',
    };
    return Card(
      color: i == selectedCandidate
          ? LayoverColors.mint.withValues(alpha: 0.25)
          : null,
      child: ListTile(
        title: Text('${c['archetype']} · ${c['mode']}'),
        subtitle: Text(
          '$reason\n'
          '${rows(c['stops']).length} stops · ${((c['duration_seconds'] as int) / 60).ceil()} min\n${total.label(settings['currency'])} · ${budgetState(total, settings)}',
        ),
        trailing: Icon(
          i == selectedCandidate ? Icons.check_circle : Icons.circle_outlined,
        ),
        onTap: () => setState(() {
          selectedCandidate = i;
          if (repository.editable) changed(clearCandidates: false);
        }),
      ),
    );
  }

  List<Widget> history() => [
    heading('Saved versions'),
    if (editable)
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          onPressed: () => setState(() {
            parentId = null;
            places = [];
            itineraries = [];
            allowances = [];
            selectedCandidate = 0;
            title.text = 'A day to explore';
            changed();
            page = 0;
          }),
          child: const Text('Start a new plan'),
        ),
      ),
    TextButton.icon(
      onPressed: busy
          ? null
          : () => run(() async {
              versions = await repository.versions();
            }),
      icon: const Icon(Icons.refresh),
      label: const Text('Refresh saved plans'),
    ),
    if (versions.isEmpty)
      notice(
        'No saved plans yet. Organizers can save a selection or generated itinerary.',
      ),
    for (final version in versions)
      Card(
        child: ListTile(
          title: Text('${version['title']} · v${version['version']}'),
          subtitle: Text(
            '${version['status']} · ${version['created_at']}\n${versionSummary(version)}',
          ),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => open(version),
        ),
      ),
  ];
  String versionSummary(Json version) {
    final s = Map<String, dynamic>.from(version['snapshot']),
        saved = rows(s['itineraries']);
    if (saved.isEmpty) {
      return '${rows(s['places']).where((p) => p['selection_type'] != 'excluded').length} selected places';
    }
    final index = (s['selected_candidate'] as int? ?? 0).clamp(
      0,
      saved.length - 1,
    );
    final config = Map<String, dynamic>.from(s['settings']);
    return totalCosts(
      rows(saved[index]['costs']),
      config['group_size'],
      config['currency'],
    ).label(config['currency']);
  }
}
