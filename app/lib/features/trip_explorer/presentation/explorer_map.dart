import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import '../../../core/env.dart';
import '../domain/explorer.dart';
import '../domain/area_drawing.dart';

class ExplorerMap extends StatefulWidget {
  const ExplorerMap({
    super.key,
    required this.zone,
    required this.places,
    required this.origin,
    required this.onPoint,
    this.geometry,
    this.destination,
    this.drawMode = 'pan',
    this.onZone,
    this.onError,
    this.focus,
    this.focusRevision = 0,
    this.initialZoom = 13,
    this.showSelection = true,
    this.demo = false,
  });
  final Json zone;
  final List<Json> places;
  final List<double> origin;
  final Json? geometry;
  final List<double>? destination;
  final String drawMode;
  final void Function(Json)? onZone;
  final void Function(String)? onError;
  final List<double>? focus;
  final int focusRevision;
  final double initialZoom;
  final bool showSelection;
  final void Function(List<double>)? onPoint;
  final bool demo;
  @override
  State<ExplorerMap> createState() => _ExplorerMapState();
}

class _ExplorerMapState extends State<ExplorerMap> {
  MapboxMap? map;
  bool ready = false, failed = false, updating = false, dirty = false;
  Timer? timeout;
  final List<Offset> stroke = [];
  bool converting = false;
  int appliedFocusRevision = -1;
  late List<double> viewCenter = widget.focus ?? widget.origin;
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
        if (widget.showSelection && boundary != null) feature(boundary, {}),
        if (widget.geometry != null) feature(widget.geometry!, {}),
        if (widget.showSelection)
          feature(
            {'type': 'Point', 'coordinates': widget.origin},
            {'label': 'Start'},
          ),
        if (widget.destination != null)
          feature(
            {'type': 'Point', 'coordinates': widget.destination},
            {'label': 'Finish'},
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
        // A GPS fix can arrive before the style is ready. Apply it here too.
        if (mounted && appliedFocusRevision != widget.focusRevision) {
          final revision = widget.focusRevision;
          await map!.setCamera(
            CameraOptions(
              center: Point(
                coordinates: Position(viewCenter[0], viewCenter[1]),
              ),
              zoom: revision == 0 ? widget.initialZoom : 14,
            ),
          );
          appliedFocusRevision = revision;
        }
      } while (dirty && mounted);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      updating = false;
    }
  }

  @override
  void didUpdateWidget(covariant ExplorerMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusRevision != widget.focusRevision) {
      viewCenter = widget.focus ?? widget.origin;
    }
    unawaited(update());
  }

  @override
  void dispose() {
    timeout?.cancel();
    super.dispose();
  }

  Future<void> finishStroke(Size size) async {
    if (stroke.length < 2 || converting) {
      setState(stroke.clear);
      return;
    }
    final mode = widget.drawMode;
    setState(() => converting = true);
    try {
      final pixels = mode == 'circle'
          ? [stroke.first, stroke.last]
          : List<Offset>.of(stroke);
      final points = widget.demo
          ? pixels
                .map(
                  (p) => [
                    viewCenter[0] + (p.dx / size.width - .5) * .06,
                    viewCenter[1] - (p.dy / size.height - .5) * .06,
                  ],
                )
                .toList()
          : (await map!.coordinatesForPixels(
                  pixels
                      .map((p) => ScreenCoordinate(x: p.dx, y: p.dy))
                      .toList(),
                ))
                .map(
                  (p) => [
                    p.coordinates.lng.toDouble(),
                    p.coordinates.lat.toDouble(),
                  ],
                )
                .toList();
      final zone = drawnZone(mode, points);
      if (mounted) widget.onZone?.call(zone);
    } catch (e) {
      if (mounted) {
        widget.onError?.call(
          e is FormatException
              ? e.message
              : 'The map is still loading. Try drawing again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          stroke.clear();
          converting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.demo && (failed || !Env.mapboxToken.startsWith('pk.'))) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'The map could not load. Check your connection and reopen the explorer. You can still search an area and use its nearby circle.',
          ),
        ),
      );
    }
    final drawing = ['circle', 'freehand'].contains(widget.drawMode);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              Positioned.fill(
                child: widget.demo
                    ? GestureDetector(
                        onTapUp: ['start', 'finish'].contains(widget.drawMode)
                            ? (d) => widget.onPoint?.call([
                                viewCenter[0] +
                                    (d.localPosition.dx / size.width - .5) *
                                        .06,
                                viewCenter[1] -
                                    (d.localPosition.dy / size.height - .5) *
                                        .06,
                              ])
                            : null,
                        child: CustomPaint(
                          painter: _Sketch(features(), viewCenter),
                        ),
                      )
                    : MapWidget(
                        viewport: CameraViewportState(
                          center: Point(
                            coordinates: Position(viewCenter[0], viewCenter[1]),
                          ),
                          zoom: widget.initialZoom,
                        ),
                        styleUri: MapboxStyles.MAPBOX_STREETS,
                        onMapCreated: (value) {
                          map = value;
                          value.addInteraction(
                            TapInteraction.onMap((e) {
                              if (mounted &&
                                  [
                                    'start',
                                    'finish',
                                  ].contains(widget.drawMode)) {
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
                      ),
              ),
              if (drawing)
                Positioned.fill(
                  child: Semantics(
                    label: widget.drawMode == 'circle'
                        ? 'Draw a circle on the map'
                        : 'Draw a freehand area on the map',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: converting
                          ? null
                          : (d) => setState(() {
                              stroke.clear();
                              stroke.add(d.localPosition);
                            }),
                      onPanUpdate: converting
                          ? null
                          : (d) {
                              if (stroke.isNotEmpty &&
                                  (d.localPosition - stroke.last).distance >=
                                      4 &&
                                  stroke.length < 500) {
                                setState(() => stroke.add(d.localPosition));
                              }
                            },
                      onPanEnd: converting ? null : (_) => finishStroke(size),
                      onPanCancel: () => setState(stroke.clear),
                      child: CustomPaint(
                        painter: _Stroke(stroke, widget.drawMode),
                      ),
                    ),
                  ),
                ),
              if (widget.demo)
                const Positioned(
                  top: 8,
                  left: 8,
                  child: Text('Demo sketch · synthetic places'),
                ),
              if (converting) const Center(child: CircularProgressIndicator()),
            ],
          ),
        );
      },
    );
  }
}

class _Stroke extends CustomPainter {
  _Stroke(this.points, this.mode);
  final List<Offset> points;
  final String mode;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path();
    if (mode == 'circle') {
      path.addOval(
        Rect.fromCircle(
          center: points.first,
          radius: (points.last - points.first).distance,
        ),
      );
    } else {
      path.addPolygon(points, true);
    }
    canvas.drawPath(path, Paint()..color = const Color(0x337AC49B));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF34674C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _Stroke oldDelegate) => true;
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
