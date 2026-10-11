import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../../core/env.dart';
import '../domain/models.dart';
import '../domain/map_features.dart';
import '../data/campus_simulation.dart';

// Only this file knows about Mapbox. Sources/layers work on both Android and web.
class GroupMap extends StatefulWidget {
  const GroupMap({
    super.key,
    required this.locations,
    required this.names,
    required this.onPoint,
    this.destination,
    this.trails = const [],
    this.serverTime,
    this.focus,
    this.demo = false,
    this.campus = false,
  });
  final List<Json> locations, trails;
  final DateTime? serverTime;
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
  Timer? _timeout, _motion;
  List<Json> _displayed = [];
  bool _refreshTrails = true, _cameraDirty = true;
  int _version = 0;
  @override
  void initState() {
    super.initState();
    _displayed = widget.locations;
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
    Json feature(Json l, String label, String color, String kind) => {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [l['longitude'], l['latitude']],
      },
      'properties': {
        'label': label,
        'color': color,
        'kind': kind,
        'user_id': l['user_id'],
        'icon': kind == 'destination' ? 'regroup-pin' : 'dot-$color',
      },
    };
    return {
      'type': 'FeatureCollection',
      'features': [
        for (final l in _displayed)
          feature(
            l,
            (widget.names[l['user_id']] ?? 'Traveler').split(' · ').first,
            l['stale'] == true ? '#F6B63D' : travelerColor(l['user_id']),
            'person',
          ),
        if (widget.destination != null)
          feature(
            widget.destination!,
            'Meet · ${widget.destination!['name']}',
            '#EC4963',
            'destination',
          ),
      ],
    };
  }

  Future<void> _addMarkers(MapboxMap map) async {
    for (final color in [
      '#EC4963',
      '#4A8DAB',
      '#9A68AE',
      '#43836B',
      '#F6B63D',
      'pin',
    ]) {
      final pin = color == 'pin';
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(2);
      final paint = Paint()
        ..color = pin
            ? const Color(0xFFEC4963)
            : Color(int.parse(color.substring(1), radix: 16) + 0xFF000000);
      if (pin) {
        final path = Path()
          ..moveTo(16, 42)
          ..cubicTo(12, 34, 2, 24, 2, 16)
          ..arcToPoint(const Offset(30, 16), radius: const Radius.circular(14))
          ..cubicTo(30, 24, 20, 34, 16, 42)
          ..close();
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
        canvas.drawPath(path, paint);
        canvas.drawCircle(
          const Offset(16, 16),
          5,
          Paint()..color = Colors.white,
        );
      } else {
        canvas.drawCircle(
          const Offset(16, 16),
          14,
          Paint()..color = paint.color.withValues(alpha: .2),
        );
        canvas.drawCircle(
          const Offset(16, 16),
          8,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(const Offset(16, 16), 6, paint);
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, pin ? 88 : 64);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await map.addImage(
        pin ? 'regroup-pin' : 'dot-$color',
        2,
        StyleImage.bytes(bytes!.buffer.asUint8List()),
      );
      image.dispose();
      picture.dispose();
    }
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
      await _addMarkers(map);
      await map.addStyleSource(
        'live-trails',
        jsonEncode({
          'type': 'geojson',
          'data': trailFeatures(
            widget.trails,
            widget.locations,
            widget.serverTime ?? DateTime.now(),
          ),
        }),
      );
      for (final layer in [
        {
          'id': 'live-trail-halo',
          'type': 'line',
          'source': 'live-trails',
          'layout': {'line-join': 'round', 'line-cap': 'round'},
          'paint': {
            'line-color': '#FFFFFF',
            'line-width': 7,
            'line-opacity': .75,
          },
        },
        {
          'id': 'live-trail',
          'type': 'line',
          'source': 'live-trails',
          'layout': {'line-join': 'round', 'line-cap': 'round'},
          'paint': {
            'line-color': ['get', 'color'],
            'line-width': 4,
            'line-opacity': .85,
          },
        },
        {
          'id': 'live-dots',
          'type': 'symbol',
          'source': 'live-group',
          'layout': {
            'icon-image': ['get', 'icon'],
            'icon-anchor': [
              'case',
              [
                '==',
                ['get', 'kind'],
                'destination',
              ],
              'bottom',
              'center',
            ],
            'icon-allow-overlap': true,
            'icon-ignore-placement': true,
            'icon-pitch-alignment': 'viewport',
          },
        },
        {
          'id': 'live-names',
          'type': 'symbol',
          'source': 'live-group',
          'layout': {
            'text-field': ['get', 'label'],
            'text-size': 12,
            'text-offset': [0, 1.7],
            'text-allow-overlap': false,
            'text-optional': true,
          },
          'paint': {
            'text-color': '#171717',
            'text-halo-color': '#FFFFFF',
            'text-halo-width': 2,
          },
        },
      ]) {
        await map.addStyleLayer(jsonEncode(layer), null);
      }
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
        if (_refreshTrails) {
          _refreshTrails = false;
          await _map!.setStyleSourceProperty(
            'live-trails',
            'data',
            jsonEncode(
              trailFeatures(
                widget.trails,
                widget.locations,
                widget.serverTime ?? DateTime.now(),
              ),
            ),
          );
        }
        await _map!.setStyleSourceProperty(
          'live-group',
          'data',
          jsonEncode(_geojson()),
        );
      } while (_dirty && mounted);
      final target =
          (_cameraDirty ? widget.focus : null) ??
          (!_centered
              ? widget.campus
                    ? CampusSimulation.center
                    : widget.locations.firstOrNull ?? widget.destination
              : null);
      if (target != null && mounted) {
        _centered = true;
        _cameraDirty = false;
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
            'fill-extrusion-color': widget.campus ? '#D4D7CC' : '#D7D8D6',
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
        LayerPosition(below: 'live-trail-halo'),
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
    _refreshTrails = true;
    _cameraDirty = oldWidget.focus != widget.focus;
    final before = {for (final l in _displayed) l['user_id']: l};
    final moved = widget.locations.any(
      (l) =>
          before[l['user_id']]?['latitude'] != l['latitude'] ||
          before[l['user_id']]?['longitude'] != l['longitude'],
    );
    _motion?.cancel();
    if (!moved || !_ready) {
      _displayed = widget.locations;
    } else {
      var frame = 0;
      void interpolate(double t) {
        _displayed = widget.locations.map((l) {
          final start = before[l['user_id']];
          if (start == null ||
              l['stale'] == true ||
              distanceMetres(start, l) > 500) {
            return l;
          }
          return <String, dynamic>{
            ...l,
            'latitude':
                (start['latitude'] as num) +
                ((l['latitude'] as num) - (start['latitude'] as num)) * t,
            'longitude':
                (start['longitude'] as num) +
                ((l['longitude'] as num) - (start['longitude'] as num)) * t,
          };
        }).toList();
      }

      interpolate(0);
      _motion = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        interpolate((++frame / 8).clamp(0, 1));
        unawaited(_update());
        if (frame >= 8) timer.cancel();
      });
    }
    unawaited(_update());
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _motion?.cancel();
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
