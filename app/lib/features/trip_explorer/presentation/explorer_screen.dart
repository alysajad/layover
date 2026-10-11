import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
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
  String? versionsError, locationMessage;
  String category = 'all', drawMode = 'pan';
  final areaSearch = TextEditingController();
  List<Json> searchResults = [];
  List<double>? mapFocus;
  Json? previousZone;
  List<double>? previousOrigin;
  int focusRevision = 0;
  int areaRevision = 0;
  int page = 0, selectedCandidate = 0;
  bool busy = false, dirty = true, areaChosen = false;
  bool loadingVersions = false, locating = false;
  bool locationServiceOff = false, locationPermissionBlocked = false;
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
        : <double>[78.9629, 20.5937];
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
    areaChosen = repository.demo;
    areaSearch.text = widget.trip.trip?.destination ?? '';
    if (!repository.editable) page = 3;
    widget.trip.addListener(tripChanged);
    // Saved-plan availability must never prevent the local map from opening.
    unawaited(loadVersions());
    if (!repository.demo && repository.editable) unawaited(locateArea());
  }

  Future<void> loadVersions() async {
    if (loadingVersions || !mounted) return;
    setState(() {
      loadingVersions = true;
      versionsError = null;
    });
    try {
      final result = await repository.versions();
      if (mounted && repository.accessible) setState(() => versions = result);
    } catch (e) {
      if (mounted && repository.accessible) {
        setState(() => versionsError = explorerErrorMessage(e));
      }
    } finally {
      if (mounted) setState(() => loadingVersions = false);
    }
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
    areaSearch.dispose();
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
      if (mounted) error = explorerErrorMessage(e);
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
    final selected = places
        .where((p) => p['selection_type'] != 'excluded')
        .toList();
    places = [
      ...selected,
      for (final p in result)
        if (!selected.any((r) => r['id'] == p['id'])) old[p['id']] ?? p,
    ].take(40).toList();
    changed();
    page = 1;
    if (selected.isEmpty && old.isEmpty && result.isNotEmpty) {
      final suggestions = suggestStops(settings, places, allowances);
      for (final p in places) {
        if (suggestions.contains(p['id'])) p['selection_type'] = 'optional';
      }
      message = suggestions.isEmpty
          ? null
          : 'Suggested ${suggestions.length} stops for your budget. Verify unknown prices before confirming.';
    }
    if (repository.discoveryWarning != null) {
      message = repository.discoveryWarning;
    }
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
    await loadVersions();
    message = 'Saved version ${result['version']}.';
  });
  void open(Json version) {
    final s = copyJson(Map<String, dynamic>.from(version['snapshot']));
    setState(() {
      areaRevision++;
      locationMessage = null;
      settings = Map<String, dynamic>.from(s['settings']);
      areaChosen = true;
      previousZone = null;
      mapFocus = coordinate(settings['origin']);
      focusRevision++;
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
            DropdownButtonFormField<int>(
              initialValue: int.parse(dwell.text),
              decoration: const InputDecoration(labelText: 'Visit time'),
              items:
                  ({
                        0,
                        5,
                        15,
                        30,
                        45,
                        60,
                        90,
                        120,
                        180,
                        240,
                        480,
                        int.parse(dwell.text),
                      }.toList()..sort())
                      .map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text('$v minutes'),
                        ),
                      )
                      .toList(),
              onChanged: (v) => dwell.text = '$v',
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: int.parse(priority.text),
              decoration: const InputDecoration(labelText: 'Priority'),
              items: [
                for (var v = 1; v <= 5; v++)
                  DropdownMenuItem(
                    value: v,
                    child: Text('$v${v == 5 ? ' · Highest' : ''}'),
                  ),
              ],
              onChanged: (v) => priority.text = '$v',
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
                        if (versionsError != null) ...[
                          notice(versionsError!, warning: true),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: loadingVersions ? null : loadVersions,
                              child: const Text('Retry saved plans'),
                            ),
                          ),
                        ],
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
                                onPressed: editable && dirty && areaChosen
                                    ? save
                                    : null,
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
                                          await loadVersions();
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

  void selectZone(Json zone, {List<double>? focus, String? name}) {
    setState(() {
      areaRevision++;
      previousZone = areaChosen
          ? copyJson(Map<String, dynamic>.from(settings['zone']))
          : null;
      previousOrigin = areaChosen ? coordinate(settings['origin']) : null;
      areaChosen = true;
      locationMessage = null;
      settings['zone'] = zone;
      settings['origin'] = zone['type'] == 'circle'
          ? zone['center']
          : (zone['vertices'] as List).first;
      if (focus != null) {
        mapFocus = focus;
        focusRevision++;
      }
      if (name != null) areaSearch.text = name;
      drawMode = 'pan';
      error = null;
      places = [];
      changed();
    });
  }

  Future<void> searchArea() => run(() async {
    searchResults = await repository.search(areaSearch.text.trim());
    if (searchResults.isEmpty) {
      message = 'No areas found. Try a nearby town or landmark.';
    }
  });

  Future<void> locateArea() async {
    if (locating || !mounted || !repository.editable) return;
    final revision = areaRevision;
    setState(() {
      locating = true;
      locationMessage = null;
      locationServiceOff = locationPermissionBlocked = false;
    });
    try {
      List<double> point;
      double? accuracy;
      if (repository.demo) {
        point = [73.8278, 15.4909];
      } else {
        if (!await Geolocator.isLocationServiceEnabled()) {
          locationServiceOff = true;
          throw const FormatException(
            'Location is turned off. Enable it, then tap Use my location, or choose an area on the map.',
          );
        }
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.deniedForever) {
          locationPermissionBlocked = true;
          throw const FormatException(
            'Allow location access in app settings, then tap Use my location. You can also choose an area on the map.',
          );
        }
        if (![
          LocationPermission.always,
          LocationPermission.whileInUse,
        ].contains(permission)) {
          throw const FormatException(
            'Location access was not granted. Tap Use my location to retry, or choose an area on the map.',
          );
        }
        if (!mounted || !repository.editable || revision != areaRevision) {
          return;
        }
        final fix = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 15),
          ),
        );
        point = coordinate([fix.longitude, fix.latitude]);
        accuracy = fix.accuracy;
      }
      // Do not replace a searched/drawn area or an opened plan with a late fix.
      if (!mounted || !repository.editable || revision != areaRevision) return;
      selectZone(
        {'type': 'circle', 'center': point, 'radius_m': 1500},
        focus: point,
        name: repository.demo ? 'Demo area' : 'Near me',
      );
      locationMessage = accuracy != null && accuracy > 100
          ? 'Using approximate location (±${accuracy.round()} m). Adjust the outline if needed.'
          : 'Map centered on ${repository.demo ? 'the demo area' : 'your current location'}.';
    } catch (e) {
      if (mounted && repository.accessible && revision == areaRevision) {
        locationMessage = e is FormatException
            ? e.message
            : e is TimeoutException
            ? 'Your location took too long to arrive. Tap Use my location to retry, or choose an area on the map.'
            : 'Could not get your current location. Check location access and try again, or choose an area on the map.';
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  List<Widget> area() => [
    heading('Draw your day'),
    Text(
      '${moneyText(settings['budget_minor'], settings['currency'])} group budget · ${settings['group_size']} travelers',
    ),
    Text(
      '${DateFormat('d MMM · h:mm a').format(DateTime.parse(settings['start_at']).toLocal())} → ${DateFormat('d MMM · h:mm a').format(DateTime.parse(settings['end_at']).toLocal())}',
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: editable ? configure : null,
        icon: const Icon(Icons.tune),
        label: const Text('Edit budget and time'),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: areaSearch,
      enabled: editable,
      textInputAction: TextInputAction.search,
      onChanged: (_) => areaRevision++,
      onSubmitted: (_) => searchArea(),
      decoration: InputDecoration(
        labelText: 'Search town, neighborhood or landmark',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: IconButton(
          tooltip: 'Search area',
          onPressed: editable ? searchArea : null,
          icon: const Icon(Icons.arrow_forward),
        ),
      ),
    ),
    for (final result in searchResults)
      ListTile(
        leading: const Icon(Icons.place_outlined),
        title: Text(result['name'] ?? 'Area'),
        onTap: !editable
            ? null
            : () {
                final point = coordinate(result['point']);
                selectZone(
                  {'type': 'circle', 'center': point, 'radius_m': 1500},
                  focus: point,
                  name: result['name'],
                );
                setState(searchResults.clear);
              },
      ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: editable && !locating ? locateArea : null,
        icon: const Icon(Icons.my_location),
        label: Text(locating ? 'Finding your location…' : 'Use my location'),
      ),
    ),
    if (locating) const LinearProgressIndicator(),
    if (locationMessage != null) notice(locationMessage!),
    if (locationServiceOff || locationPermissionBlocked)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () async {
            if (locationServiceOff) {
              await Geolocator.openLocationSettings();
            } else {
              await Geolocator.openAppSettings();
            }
          },
          child: Text(
            locationServiceOff ? 'Open location settings' : 'Open app settings',
          ),
        ),
      ),
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final mode in [
          ('pan', 'Move map', Icons.pan_tool_outlined),
          ('circle', 'Draw circle', Icons.circle_outlined),
          ('freehand', 'Freehand', Icons.gesture),
          ('start', 'Set start', Icons.flag_outlined),
          ('finish', 'Set finish', Icons.outlined_flag),
        ])
          ChoiceChip(
            avatar: Icon(mode.$3, size: 18),
            label: Text(mode.$2),
            selected: drawMode == mode.$1,
            onSelected: editable
                ? (_) => setState(() {
                    areaRevision++;
                    drawMode = mode.$1;
                  })
                : null,
          ),
      ],
    ),
    const SizedBox(height: 10),
    Text(switch (drawMode) {
      'circle' => 'Touch the center, then drag outwards to size your circle.',
      'freehand' => 'Trace around the area with your finger. The outline closes when you lift.',
      'start' => 'Tap where you want to start exploring.',
      'finish' => 'Tap where you want to finish your day.',
      _ => 'Move and zoom the map, then draw the area you want to explore.',
    }),
    const SizedBox(height: 10),
    SizedBox(
      height: 360,
      child: ExplorerMap(
        zone: Map<String, dynamic>.from(settings['zone']),
        places: places,
        origin: coordinate(settings['origin']),
        demo: repository.demo,
        destination: settings['destination'] == null
            ? null
            : coordinate(settings['destination']),
        focus: mapFocus,
        focusRevision: focusRevision,
        initialZoom: areaChosen ? 13 : 4,
        showSelection: areaChosen,
        drawMode: editable ? drawMode : 'pan',
        onZone: (zone) => selectZone(zone),
        onError: (value) => setState(() => error = value),
        onPoint: !editable
            ? null
            : (point) => setState(() {
                areaRevision++;
                settings[drawMode == 'finish' ? 'destination' : 'origin'] =
                    point;
                drawMode = 'pan';
                changed();
              }),
      ),
    ),
    Wrap(
      spacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          !areaChosen
              ? 'Choose an area to begin'
              : settings['zone']['type'] == 'circle'
              ? '${((settings['zone']['radius_m'] as num) / 1000).toStringAsFixed(1)} km radius'
              : 'Your drawn area · ${(settings['zone']['vertices'] as List).length} boundary points',
        ),
        TextButton(
          onPressed: editable && previousZone != null
              ? () => setState(() {
                  settings['zone'] = previousZone!;
                  settings['origin'] = previousOrigin!;
                  previousZone = null;
                  places = [];
                  changed();
                })
              : null,
          child: const Text('Undo area'),
        ),
        if (settings['destination'] != null)
          TextButton(
            onPressed: editable
                ? () => setState(() {
                    settings['destination'] = null;
                    changed();
                  })
                : null,
            child: const Text('Finish at last stop'),
          ),
      ],
    ),
    if (settings['zone']['type'] == 'circle')
      DropdownButtonFormField<int>(
        key: ValueKey(settings['zone']['radius_m']),
        isExpanded: true,
        initialValue:
            [
              500,
              1000,
              1500,
              3000,
              5000,
              10000,
            ].contains(settings['zone']['radius_m'])
            ? (settings['zone']['radius_m'] as num).toInt()
            : 0,
        decoration: const InputDecoration(labelText: 'Nearby radius'),
        items: [
          const DropdownMenuItem(value: 0, child: Text('Custom drawn circle')),
          for (final radius in [500, 1000, 1500, 3000, 5000, 10000])
            DropdownMenuItem(
              value: radius,
              child: Text(radius < 1000 ? '$radius m' : '${radius / 1000} km'),
            ),
        ],
        onChanged: editable && areaChosen
            ? (v) {
                if (v != null && v > 0) {
                  selectZone({
                    ...Map<String, dynamic>.from(settings['zone']),
                    'radius_m': v,
                  });
                }
              }
            : null,
      ),
    const SizedBox(height: 12),
    Text(
      areaChosen
          ? 'Discoveries stay inside your outline. Travel routes may go outside it.'
          : 'Search an area, use your location or draw a boundary to begin.',
    ),
    const SizedBox(height: 16),
    DropdownButtonFormField<String>(
      initialValue: category,
      decoration: const InputDecoration(labelText: 'Discover'),
      items: [
        for (final c in {
          'all': 'Everything in this area',
          'culture': 'Sights & local highlights',
          'nature': 'Parks & outdoors',
          'food': 'Food courts, cafés & restaurants',
          'transport': 'Bus stops & transport',
          'services': 'Useful services',
        }.entries)
          DropdownMenuItem(value: c.key, child: Text(c.value)),
      ],
      onChanged: editable ? (v) => setState(() => category = v!) : null,
      isExpanded: true,
    ),
    const SizedBox(height: 12),
    FilledButton.icon(
      onPressed: editable && areaChosen ? discover : null,
      icon: const Icon(Icons.travel_explore),
      label: const Text('Find places'),
    ),
    ...allowanceWidgets(),
  ];

  void suggest() {
    final ids = suggestStops(settings, places, allowances);
    setState(() {
      for (final p in places) {
        p['selection_type'] = ids.contains(p['id']) ? 'optional' : 'excluded';
      }
      changed();
      message = ids.isEmpty
          ? 'No stops fit the known costs and allowances. Adjust your budget or costs.'
          : 'Suggested ${ids.length} stops, prioritizing known low costs. Add missing prices and travel costs before confirming the budget.';
    });
  }

  Future<void> loadHighlight(Json place) => run(() async {
    final details = await repository.highlight(place['wikipedia']);
    if (!mounted || !repository.editable) return;
    place['highlight'] = details;
    changed(clearCandidates: false);
    if (details['description'] == null) {
      message = 'No summary is available for this place. Open its source for details.';
    }
  });

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
    heading('Inside your area'),
    Text(
      '${moneyText(settings['budget_minor'] ~/ settings['group_size'], settings['currency'])} per person · ${moneyText(settings['budget_minor'], settings['currency'])} for the group',
    ),
    const Text(
      'Entry fees, meals and fares are shown when available. Unknown prices still need checking.',
    ),
    if (places.isNotEmpty)
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: editable ? suggest : null,
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Suggest budget stops'),
        ),
      ),
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
            "${(p['category'] as String).split('.').last.replaceAll('_', ' ')} · ${p['dwell_minutes']} min · priority ${p['priority']}",
          ),
          if (p['description'] != null) Text(p['description']),
          if (p['cuisine'] != null) Text('On the menu · ${p['cuisine']}'),
          if (p['operator'] != null || p['network'] != null)
            Text('Service · ${p['operator'] ?? p['network']}'),
          if (p['address'] != null)
            Text(p['address'], style: Theme.of(context).textTheme.bodySmall),
          if (p['opening_hours'] != null)
            Text('Listed hours · ${p['opening_hours']}'),
          if (p['kind'] == 'transport')
            const Text(
              'Stop listed in this area. Check the operator for routes, schedules and fares.',
            ),
          if (p['highlight']?['description'] != null)
            Text(p['highlight']['description']),
          Wrap(
            spacing: 8,
            children: [
              if (p['wikipedia'] != null && p['highlight'] == null)
                TextButton(
                  onPressed: editable ? () => loadHighlight(p) : null,
                  child: const Text('What’s special here?'),
                ),
              for (final link in [
                ('Place source', p['source_url']),
                ('Website / menu', p['website']),
                ('Wikipedia · CC BY-SA', p['highlight']?['source_url']),
              ])
                if (link.$2 is String &&
                    ['https', 'http'].contains(Uri.tryParse(link.$2)?.scheme))
                  TextButton(
                    onPressed: () => launchUrl(Uri.parse(link.$2)),
                    child: Text(link.$1),
                  ),
            ],
          ),
          Text(
            '${p['source']} · checked ${DateFormat('d MMM, h:mm a').format(DateTime.parse(p['source_checked_at']).toLocal())}',
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
                child: Text(
                  p['kind'] == 'food'
                      ? 'Meal budget'
                      : p['kind'] == 'transport'
                      ? 'Fare cost'
                      : 'Admission cost',
                ),
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
      onPressed: busy || loadingVersions ? null : loadVersions,
      icon: const Icon(Icons.refresh),
      label: const Text('Refresh saved plans'),
    ),
    if (loadingVersions) const LinearProgressIndicator(),
    if (versions.isEmpty && versionsError == null && !loadingVersions)
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
