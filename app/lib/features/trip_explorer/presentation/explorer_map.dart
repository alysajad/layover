import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import '../../../core/env.dart';
import '../domain/explorer.dart';

class ExplorerMap extends StatefulWidget {
  const ExplorerMap({
    super.key,
    required this.zone,
    required this.places,
    required this.origin,
    required this.onPoint,
    this.geometry,
    this.demo = false,
  });
  final Json zone;
  final List<Json> places;
  final List<double> origin;
  final Json? geometry;
  final void Function(List<double>)? onPoint;
  final bool demo;
  @override
  State<ExplorerMap> createState() => _ExplorerMapState();
}

class _ExplorerMapState extends State<ExplorerMap> {
  MapboxMap? map;
  bool ready = false, failed = false, updating = false, dirty = false;
  Timer? timeout;
  @override
  void initState() {
    super.initState();
    if (Env.mapboxToken.startsWith('pk.') && !widget.demo) {
      MapboxOptions.setAccessToken(Env.mapboxToken);
      timeout = Timer(
        const Duration(seconds: 20),
        () => mounted ? setState(() => failed = true) : null,
      );
    }
  }

  Json features() {
    Json feature(Json g, Json properties) => {
      'type': 'Feature',
      'geometry': g,
      'properties': properties,
    };
    Json? boundary;
    try {
      boundary = Zone(widget.zone).geometry;
    } catch (_) {
      /* Polygon still being drawn. */
    }
    return {
      'type': 'FeatureCollection',
      'features': [
        if (boundary != null) feature(boundary, {}),
        if (widget.geometry != null) feature(widget.geometry!, {}),
        feature(
          {'type': 'Point', 'coordinates': widget.origin},
          {'label': 'Start'},
        ),
        if (widget.zone['type'] == 'polygon')
          for (final p in widget.zone['vertices'] as List)
            feature({'type': 'Point', 'coordinates': p}, {'label': ''}),
        for (final p in widget.places)
          feature(
            {'type': 'Point', 'coordinates': p['point']},
            {'label': p['name']},
          ),
      ],
    };
  }

  Future<void> loaded() async {
    try {
      await map!.addStyleSource(
        'explorer',
        jsonEncode({'type': 'geojson', 'data': features()}),
      );
      for (final layer in [
        {
          'id': 'explorer-zone',
          'type': 'fill',
          'source': 'explorer',
          'filter': [
            '==',
            ['geometry-type'],
            'Polygon',
          ],
          'paint': {'fill-color': '#7AC49B', 'fill-opacity': 0.25},
        },
        {
          'id': 'explorer-route',
          'type': 'line',
          'source': 'explorer',
          'filter': [
            '==',
            ['geometry-type'],
            'LineString',
          ],
          'paint': {'line-color': '#171717', 'line-width': 4},
        },
        {
          'id': 'explorer-points',
          'type': 'circle',
          'source': 'explorer',
          'filter': [
            '==',
            ['geometry-type'],
            'Point',
          ],
          'paint': {
            'circle-color': '#F6B63D',
            'circle-radius': 7,
            'circle-stroke-width': 2,
            'circle-stroke-color': '#171717',
          },
        },
        {
          'id': 'explorer-labels',
          'type': 'symbol',
          'source': 'explorer',
          'filter': [
            '==',
            ['geometry-type'],
            'Point',
          ],
          'layout': {
            'text-field': ['get', 'label'],
            'text-size': 12,
            'text-offset': [0, 1.5],
          },
          'paint': {
            'text-color': '#171717',
            'text-halo-color': '#FFFFFF',
            'text-halo-width': 2,
          },
        },
      ]) {
        await map!.addStyleLayer(jsonEncode(layer), null);
      }
      if (!mounted) return;
      ready = true;
      timeout?.cancel();
      await update();
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  Future<void> update() async {
    if (!ready || map == null || !mounted) return;
    if (updating) {
      dirty = true;
      return;
    }
    updating = true;
    try {
      do {
        dirty = false;
        await map!.setStyleSourceProperty(
          'explorer',
          'data',
          jsonEncode(features()),
        );
      } while (dirty && mounted);
      await map!.setCamera(
        CameraOptions(
          center: Point(
            coordinates: Position(widget.origin[0], widget.origin[1]),
          ),
          zoom: 12,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      updating = false;
    }
  }

  @override
  void didUpdateWidget(covariant ExplorerMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(update());
  }

  @override
  void dispose() {
    timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.demo) {
      return Column(
        children: [
          const Text(
            'Demo area sketch · synthetic positions, not a street map',
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, size) => GestureDetector(
                onTapUp: widget.onPoint == null
                    ? null
                    : (d) => widget.onPoint!([
                        widget.origin[0] +
                            (d.localPosition.dx / size.maxWidth - 0.5) * 0.06,
                        widget.origin[1] -
                            (d.localPosition.dy / size.maxHeight - 0.5) * 0.06,
                      ]),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _Sketch(features(), widget.origin),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (failed || !Env.mapboxToken.startsWith('pk.')) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Map unavailable. Enter the area coordinates below to continue.',
          ),
        ),
      );
    }
    return MapWidget(
      viewport: CameraViewportState(
        center: Point(
          coordinates: Position(widget.origin[0], widget.origin[1]),
        ),
        zoom: 12,
      ),
      styleUri: MapboxStyles.MAPBOX_STREETS,
      onMapCreated: (value) {
        map = value;
        value.addInteraction(
          TapInteraction.onMap((e) {
            if (mounted) {
              widget.onPoint?.call([
                e.point.coordinates.lng.toDouble(),
                e.point.coordinates.lat.toDouble(),
              ]);
            }
          }),
        );
      },
      onStyleLoadedListener: (_) => loaded(),
      onMapLoadErrorListener: (_) {
        if (mounted) setState(() => failed = true);
      },
    );
  }
}

class _Sketch extends CustomPainter {
  _Sketch(this.data, this.origin);
  final Json data;
  final List<double> origin;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFECEDE7),
    );
    Offset project(List p) => Offset(
      ((p[0] as num) - origin[0]) / 0.06 * size.width + size.width / 2,
      size.height / 2 - ((p[1] as num) - origin[1]) / 0.06 * size.height,
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final f in rows(data['features'])) {
      final g = f['geometry'] as Map, type = g['type'];
      if (type == 'Point') {
        canvas.drawCircle(
          project(g['coordinates']),
          6,
          Paint()..color = const Color(0xFF171717),
        );
        final label = TextPainter(
          text: TextSpan(
            text: f['properties']['label'],
            style: const TextStyle(color: Color(0xFF171717), fontSize: 11),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 160);
        label.paint(
          canvas,
          project(g['coordinates']) +
              (f['properties']['label'] == 'Start'
                  ? const Offset(-24, -22)
                  : const Offset(8, 6)),
        );
      } else {
        final lines = type == 'LineString'
            ? [g['coordinates']]
            : g['coordinates'] as List;
        for (final line in lines) {
          final path = Path();
          for (var i = 0; i < (line as List).length; i++) {
            final p = project(line[i]);
            if (i == 0) {
              path.moveTo(p.dx, p.dy);
            } else {
              path.lineTo(p.dx, p.dy);
            }
          }
          if (type == 'Polygon') path.close();
          canvas.drawPath(
            path,
            Paint()
              ..color = (type == 'Polygon'
                  ? const Color(0x66B8C9AE)
                  : const Color(0xFF171717))
              ..style = (type == 'Polygon'
                  ? PaintingStyle.fill
                  : PaintingStyle.stroke)
              ..strokeWidth = 3,
          );
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _Sketch oldDelegate) => true;
}
