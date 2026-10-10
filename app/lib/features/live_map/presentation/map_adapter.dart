import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../../core/env.dart';
import '../domain/models.dart';
import '../data/campus_simulation.dart';

// Only this file knows about Mapbox. Sources/layers work on both Android and web.
class GroupMap extends StatefulWidget {
  const GroupMap({
    super.key,
    required this.locations,
    required this.names,
    required this.onPoint,
    this.destination,
    this.focus,
    this.demo = false,
    this.campus = false,
  });
  final List<Json> locations;
  final Map<String, String> names;
  final Json? destination, focus;
  final void Function(double latitude, double longitude) onPoint;
  final bool demo;
  final bool campus;
  @override
  State<GroupMap> createState() => _GroupMapState();
}

class _GroupMapState extends State<GroupMap> {
  MapboxMap? _map;
  bool _failed = false,
      _ready = false,
      _threeD = false,
      _updating = false,
      _dirty = false;
  bool _centered = false;
  late bool _startIn3D = widget.campus;
  bool _threeDFailed = false;
  Timer? _timeout;
  int _version = 0;
  @override
  void initState() {
    super.initState();
    if (Env.mapboxToken.startsWith('pk.')) {
      MapboxOptions.setAccessToken(Env.mapboxToken);
      _timeout = Timer(const Duration(seconds: 20), _fail);
    }
  }

  void _fail() {
    if (!mounted) return;
    if (_threeD) {
      unawaited(_flat());
      return;
    }
    setState(() => _failed = true);
  }

  Point _point(Json location) => Point(
    coordinates: Position(
      location['longitude'] as num,
      location['latitude'] as num,
    ),
  );
  Json _geojson() {
    // Group nearby overlapping markers; every member remains selectable in the sheet.
    final groups = <List<Json>>[];
    for (final location in widget.locations) {
      final group = widget.campus
          ? null
          : groups
                .where((g) => distanceMetres(g.first, location) < 25)
                .firstOrNull;
      if (group == null) {
        groups.add([location]);
      } else {
        group.add(location);
      }
    }
    Json feature(Json l, String label, String color) => {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [l['longitude'], l['latitude']],
      },
      'properties': {'label': label, 'color': color},
    };
    return {
      'type': 'FeatureCollection',
      'features': [
        for (final group in groups)
          feature(
            group.first,
            widget.campus
                ? (widget.names[group.first['user_id']] ?? 'Runner')
                      .split(' · ')
                      .first
                : group.length > 1
                ? '${group.length} friends · select below'
                : '${(widget.names[group.first['user_id']] ?? 'Traveler').split(' ').map((s) => s.isEmpty ? '' : s[0]).take(2).join()} · ${widget.names[group.first['user_id']] ?? 'Traveler'}',
            group.any((l) => l['stale'] == true)
                ? '#F6B63D'
                : widget.campus
                ? switch (group.first['user_id']) {
                    'sim-runner-0' => '#AFC7A0',
                    'sim-runner-1' => '#E0B779',
                    'sim-runner-2' => '#C3C8DC',
                    _ => '#FFFFFF',
                  }
                : '#7AC49B',
          ),
        if (widget.destination != null)
          feature(
            widget.destination!,
            'Regroup · ${widget.destination!['name']}',
            '#F78086',
          ),
      ],
    };
  }

  Future<void> _loaded() async {
    final map = _map;
    if (map == null || !mounted) return;
    try {
      if (widget.campus) {
        await map.addStyleSource(
          'campus-route',
          jsonEncode({
            'type': 'geojson',
            'data': {
              'type': 'Feature',
              'properties': <String, dynamic>{},
              'geometry': {
                'type': 'LineString',
                'coordinates': [
                  for (final p in CampusSimulation.route)
                    [p['longitude'], p['latitude']],
                ],
              },
            },
          }),
        );
        await map.addStyleLayer(
          jsonEncode({
            'id': 'campus-test-route',
            'type': 'line',
            'source': 'campus-route',
            'layout': {'line-join': 'round', 'line-cap': 'round'},
            'paint': {
              'line-color': '#546A48',
              'line-width': 5,
              'line-opacity': .85,
            },
          }),
          null,
        );
      }
      await map.addStyleSource(
        'live-group',
        jsonEncode({'type': 'geojson', 'data': _geojson()}),
      );
      await map.addStyleLayer(
        jsonEncode({
          'id': 'live-dots',
          'type': 'circle',
          'source': 'live-group',
          'paint': {
            'circle-radius': 18,
            'circle-color': ['get', 'color'],
            'circle-stroke-color': '#171717',
            'circle-stroke-width': 2,
          },
        }),
        null,
      );
      await map.addStyleLayer(
        jsonEncode({
          'id': 'live-names',
          'type': 'symbol',
          'source': 'live-group',
          'layout': {
            'text-field': ['get', 'label'],
            'text-size': 13,
            'text-offset': [0, 2],
            'text-allow-overlap': true,
          },
          'paint': {
            'text-color': '#171717',
            'text-halo-color': '#FFFFFF',
            'text-halo-width': 2,
          },
        }),
        null,
      );
      if (!mounted) return;
      _timeout?.cancel();
      _ready = true;
      if (_startIn3D) await _enable3D();
      await _update();
    } catch (_) {
      _fail();
    }
  }

  Future<void> _update() async {
    if (!_ready || _map == null || !mounted) return;
    if (_updating) {
      _dirty = true;
      return;
    }
    _updating = true;
    try {
      do {
        _dirty = false;
        await _map!.setStyleSourceProperty(
          'live-group',
          'data',
          jsonEncode(_geojson()),
        );
      } while (_dirty && mounted);
      final target =
          widget.focus ??
          (!_centered
              ? widget.campus
                    ? CampusSimulation.center
                    : widget.locations.firstOrNull ?? widget.destination
              : null);
      if (target != null && mounted) {
        _centered = true;
        await _map!.setCamera(
          CameraOptions(
            center: _point(target),
            zoom: widget.campus ? (widget.focus == null ? 16.6 : 17.5) : 15,
            pitch: _threeD ? 60 : 0,
            bearing: widget.campus ? -25 : 0,
          ),
        );
      }
    } catch (_) {
      _fail();
    } finally {
      _updating = false;
    }
  }

  Future<void> _flat() async {
    if (!mounted) return;
    // Recreate the map for a clean 2D fallback after provider/rendering errors.
    setState(() {
      _threeD = false;
      _startIn3D = false;
      _centered = false;
      _ready = false;
      _failed = false;
      _map = null;
      _version++;
    });
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 20), _fail);
  }

  Future<void> _enable3D() async {
    if (!_ready || _map == null) return;
    setState(() => _threeD = true);
    try {
      await _map!.addStyleLayer(
        jsonEncode({
          'id': 'live-buildings',
          'type': 'fill-extrusion',
          'source': 'composite',
          'source-layer': 'building',
          'minzoom': 14,
          if (!widget.campus) 'filter': ['==', 'extrude', 'true'],
          'paint': {
            'fill-extrusion-color': widget.campus ? '#D4D7CC' : '#b9cbc1',
            'fill-extrusion-height': widget.campus
                ? [
                    'max',
                    9,
                    [
                      'coalesce',
                      ['get', 'height'],
                      9,
                    ],
                  ]
                : ['get', 'height'],
            'fill-extrusion-base': [
              'coalesce',
              ['get', 'min_height'],
              0,
            ],
            'fill-extrusion-opacity': 0.85,
          },
        }),
        null,
      );
      if (!widget.campus) {
        await _map!.addStyleSource(
          'live-dem',
          jsonEncode({
            'type': 'raster-dem',
            'url': 'mapbox://mapbox.mapbox-terrain-dem-v1',
            'tileSize': 512,
            'maxzoom': 14,
          }),
        );
        await _map!.setStyleTerrain(
          jsonEncode({'source': 'live-dem', 'exaggeration': 1}),
        );
      }
      await _map!.setCamera(CameraOptions(pitch: 60));
    } catch (_) {
      _threeDFailed = true;
      await _flat();
    }
  }

  @override
  void didUpdateWidget(covariant GroupMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_update());
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Env.mapboxToken.startsWith('pk.') || _failed) {
      return Card(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.map_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  _failed
                      ? 'Map unavailable. Session controls and the member list still work.'
                      : 'Map not available in this build. Session controls and the member list still work.',
                  textAlign: TextAlign.center,
                ),
                if (_failed)
                  TextButton(
                    onPressed: _flat,
                    child: const Text('Retry in 2D'),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: MapWidget(
            key: ValueKey(_version),
            styleUri: MapboxStyles.MAPBOX_STREETS,
            viewport: CameraViewportState(
              center: Point(
                coordinates: widget.campus
                    ? Position(
                        CampusSimulation.center['longitude']!,
                        CampusSimulation.center['latitude']!,
                      )
                    : Position(0, 20),
              ),
              zoom: widget.campus ? 16.6 : 1,
              pitch: widget.campus && _startIn3D ? 60 : 0,
              bearing: widget.campus ? -25 : 0,
            ),
            onMapCreated: (map) {
              _map = map;
              map.addInteraction(
                TapInteraction.onMap((event) {
                  if (mounted) {
                    widget.onPoint(
                      event.point.coordinates.lat.toDouble(),
                      event.point.coordinates.lng.toDouble(),
                    );
                  }
                }),
              );
            },
            onStyleLoadedListener: (_) => _loaded(),
            onMapLoadErrorListener: (_) => _fail(),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: FilledButton.tonal(
            onPressed: () => _threeD ? _flat() : _enable3D(),
            child: Text(
              _threeD
                  ? '2D'
                  : widget.campus
                  ? '3D buildings'
                  : '3D terrain',
            ),
          ),
        ),
        if (widget.campus)
          Positioned(
            left: 8,
            top: 8,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 200),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .94),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _threeDFailed
                    ? '3D unavailable · showing 2D'
                    : 'CUSAT · Kalamassery\nTest route · heights approximate',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
        // Keep Mapbox's default attribution, logo, and telemetry opt-out controls visible.
      ],
    );
  }
}
