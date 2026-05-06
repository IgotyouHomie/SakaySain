import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'road_persistence_service.dart';

/// Route Adder — Developer tool to assign jeep routes on existing roads.
/// Routes are colored translucent overlays drawn on top of Road Adder roads.
/// Each route has a jeep name and a color.
class RouteAdderScreen extends StatefulWidget {
  const RouteAdderScreen({super.key});

  @override
  State<RouteAdderScreen> createState() => _RouteAdderScreenState();
}

class _RouteAdderScreenState extends State<RouteAdderScreen> {
  static const LatLng _legazpiCenter = LatLng(13.1391, 123.7438);
  static const double _mainChunkLengthMeters = 50.0;

  final Completer<GoogleMapController> _mapController = Completer();

  List<SakayRoad> _roads = [];
  List<SakayRoute> _routes = [];

  // Current route being built
  SakayRoad? _selectedRoad;
  String _jeepName = '';
  Color _selectedColor = const Color(0xFFFF5722);
  bool _showPanel = false;
  bool _isChunkSelectionMode = false;

  // Chunk selection
  final List<int> _selectedChunkIndices = []; // Track selected chunk indices
  final Map<String, List<({LatLng start, LatLng end, int index})>>
  _roadChunksCache = {};

  final TextEditingController _nameCtrl = TextEditingController();

  // Available route colors
  static const List<Color> _routeColors = [
    Color(0xFFFF5722), // Deep Orange
    Color(0xFF9C27B0), // Purple
    Color(0xFF2196F3), // Blue
    Color(0xFFFF9800), // Orange
    Color(0xFF4CAF50), // Green
    Color(0xFFF44336), // Red
    Color(0xFF00BCD4), // Cyan
    Color(0xFFFFEB3B), // Yellow
    Color(0xFFE91E63), // Pink
    Color(0xFF795548), // Brown
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final roads = await RoadPersistenceService.loadRoads();
    final routes = await RoadPersistenceService.loadRoutes();
    setState(() {
      _roads = roads;
      _routes = routes;
    });
  }

  /// Build chunks for a road (with inset gaps for visual dashes)
  List<({LatLng start, LatLng end, int index})> _buildChunksForRoad(
    SakayRoad road,
  ) {
    if (_roadChunksCache.containsKey(road.id)) {
      return _roadChunksCache[road.id]!;
    }

    const double insetStart = 0.1;
    const double insetEnd = 0.9;
    final chunks = <({LatLng start, LatLng end, int index})>[];
    if (road.points.length < 2) return chunks;

    int globalChunkIndex = 0;
    for (int i = 0; i < road.points.length - 1; i++) {
      final a = road.points[i];
      final b = road.points[i + 1];
      final distM = _haversineMeters(a, b);
      final numChunks = (distM / _mainChunkLengthMeters).ceil().clamp(1, 200);

      for (int j = 0; j < numChunks; j++) {
        final t0 = j / numChunks;
        final t1 = (j + 1) / numChunks;
        final adjustedT0 = t0 + (t1 - t0) * insetStart;
        final adjustedT1 = t0 + (t1 - t0) * insetEnd;

        chunks.add((
          start: _lerpLatLng(a, b, adjustedT0),
          end: _lerpLatLng(a, b, adjustedT1),
          index: globalChunkIndex++,
        ));
      }
    }

    _roadChunksCache[road.id] = chunks;
    return chunks;
  }

  static LatLng _lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );

  static double _haversineMeters(LatLng a, LatLng b) {
    const R = 6371000.0;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLon = (b.longitude - a.longitude) * pi / 180;
    final s =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * R * asin(sqrt(s));
  }

  void _openAddRoutePanel() {
    if (_roads.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No roads yet. Add roads in Road Adder first.'),
          backgroundColor: Color(0xFF2E9E99),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() {
      _showPanel = true;
      _selectedRoad = null;
      _selectedChunkIndices.clear();
      _isChunkSelectionMode = false;
      _jeepName = '';
      _nameCtrl.clear();
      _selectedColor = _routeColors.first;
    });
  }

  void _selectRoadAndEnterChunkMode(SakayRoad road) {
    setState(() {
      _selectedRoad = road;
      _isChunkSelectionMode = true;
      _selectedChunkIndices.clear();
    });
    _showSnack('Tap on map to select chunks for route on ${road.name}');
  }

  void _toggleChunkSelection(int chunkIndex) {
    setState(() {
      if (_selectedChunkIndices.contains(chunkIndex)) {
        _selectedChunkIndices.remove(chunkIndex);
      } else {
        // Only allow contiguous or forked selection
        if (_selectedChunkIndices.isEmpty || _isContiguousOrFork(chunkIndex)) {
          _selectedChunkIndices.add(chunkIndex);
          _selectedChunkIndices.sort();
        } else {
          _showSnack('Select contiguous chunks or use forks to jump roads');
        }
      }
    });
  }

  bool _isContiguousOrFork(int chunkIndex) {
    if (_selectedChunkIndices.isEmpty) return true;
    final lastSelected = _selectedChunkIndices.last;
    // Allow adjacent chunks or first/last
    return (chunkIndex == lastSelected + 1 || chunkIndex == lastSelected - 1);
  }

  Future<void> _saveRoute() async {
    if (_selectedRoad == null || _selectedChunkIndices.isEmpty) {
      _showSnack('Please select at least one chunk.');
      return;
    }
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Please enter a jeep/route name.');
      return;
    }

    // Get chunks for this road
    final roadChunks = _buildChunksForRoad(_selectedRoad!);

    // Build points from selected chunks
    final points = <LatLng>[];
    for (final idx in _selectedChunkIndices) {
      if (idx >= 0 && idx < roadChunks.length) {
        if (points.isEmpty) {
          points.add(roadChunks[idx].start);
        }
        points.add(roadChunks[idx].end);
      }
    }

    if (points.length < 2) {
      _showSnack('No valid chunks selected.');
      return;
    }

    // Create chunk path metadata
    final chunkPath = [
      {
        'roadId': _selectedRoad!.id,
        'startChunkId': _selectedChunkIndices.first,
        'endChunkId': _selectedChunkIndices.last,
      },
    ];

    final route = SakayRoute(
      id: 'route_${DateTime.now().millisecondsSinceEpoch}',
      jeepName: name,
      color: _selectedColor,
      roadId: _selectedRoad!.id,
      points: points,
      chunkPath: chunkPath,
    );

    final updated = [..._routes, route];
    await RoadPersistenceService.saveRoutes(updated);
    setState(() {
      _routes = updated;
      _showPanel = false;
      _selectedChunkIndices.clear();
      _isChunkSelectionMode = false;
    });
    _showSnack(
      'Route "$name" saved with ${_selectedChunkIndices.length} chunks!',
    );
  }

  Future<void> _deleteRoute(SakayRoute route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete Route?',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Text('Delete route "${route.jeepName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final updated = _routes.where((r) => r.id != route.id).toList();
    await RoadPersistenceService.saveRoutes(updated);
    setState(() => _routes = updated);
    _showSnack('"${route.jeepName}" deleted.');
  }

  /// Reconstructs polyline points from a route's chunk path.
  /// If the route has chunkPath metadata, builds the route by connecting
  /// the selected chunks. Otherwise falls back to route.points.
  List<LatLng> _getRoutePoints(SakayRoute route) {
    if (route.chunkPath == null || route.chunkPath!.isEmpty) {
      return route.points;
    }

    // Find the road for this route
    SakayRoad? road;
    try {
      road = _roads.firstWhere((r) => r.id == route.roadId);
    } catch (e) {
      return route.points; // Road not found
    }

    // Rebuild chunks for this road
    final chunks = _buildChunksForRoad(road);
    if (chunks.isEmpty) return route.points;

    final points = <LatLng>[];

    // Process each chunk path segment
    for (final pathSegment in route.chunkPath!) {
      final startChunkId = pathSegment['startChunkId'] as int? ?? 0;
      final endChunkId = pathSegment['endChunkId'] as int? ?? 0;

      // Add chunks from startChunkId to endChunkId (inclusive)
      for (int i = startChunkId; i <= endChunkId && i < chunks.length; i++) {
        if (points.isEmpty) {
          points.add(chunks[i].start);
        }
        points.add(chunks[i].end);
      }
    }

    return points.length >= 2 ? points : route.points;
  }

  // ── Map polylines ────────────────────────────────────────────────────────

  Set<Polyline> _buildPolylines() {
    final polylines = <Polyline>{};

    // Roads — blue dashed baseline (full road, faded)
    for (final road in _roads) {
      if (road.points.length < 2) continue;
      polylines.add(
        Polyline(
          polylineId: PolylineId('road_${road.id}'),
          points: road.points,
          color: const Color(0xFF1565C0).withOpacity(0.3),
          width: 3,
          zIndex: 0,
        ),
      );
    }

    // Show individual chunks for selected road in chunk selection mode
    if (_isChunkSelectionMode && _selectedRoad != null) {
      const double insetStart = 0.1; // Skip first 10% of each chunk
      const double insetEnd = 0.9; // Skip last 10% of each chunk

      final chunks = _buildChunksForRoad(_selectedRoad!);
      for (final chunk in chunks) {
        final isSelected = _selectedChunkIndices.contains(chunk.index);

        // Apply inset to visible chunk for dash effect
        final insetStart_pt = _lerpLatLng(chunk.start, chunk.end, insetStart);
        final insetEnd_pt = _lerpLatLng(chunk.start, chunk.end, insetEnd);

        // Invisible hit target for easier tapping
        polylines.add(
          Polyline(
            polylineId: PolylineId(
              'chunk_hit_${_selectedRoad!.id}_${chunk.index}',
            ),
            points: [chunk.start, chunk.end],
            color: Colors.transparent,
            width: 20,
            zIndex: 3,
            consumeTapEvents: true,
            onTap: () => _toggleChunkSelection(chunk.index),
          ),
        );

        // Visible chunk dash
        polylines.add(
          Polyline(
            polylineId: PolylineId('chunk_${_selectedRoad!.id}_${chunk.index}'),
            points: [insetStart_pt, insetEnd_pt],
            color: isSelected
                ? Colors
                      .lime // Bright green when selected
                : const Color(0xFF00BCD4).withOpacity(0.7), // Teal normally
            width: isSelected ? 10 : 7,
            zIndex: isSelected ? 5 : 4,
          ),
        );
      }
    }

    // Routes — colored translucent thick overlay
    for (final route in _routes) {
      final points = _getRoutePoints(route);
      if (points.length < 2) continue;
      polylines.add(
        Polyline(
          polylineId: PolylineId('route_${route.id}'),
          points: points,
          color: route.color.withOpacity(0.5),
          width: 16,
          zIndex: 2,
        ),
      );
    }

    return polylines;
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF2E9E99),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── MAP ────────────────────────────────────────────────────
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: _legazpiCenter,
              zoom: 15,
            ),
            polylines: _buildPolylines(),
            onMapCreated: (ctrl) {
              if (!_mapController.isCompleted) _mapController.complete(ctrl);
            },
            myLocationEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
          ),

          // ── TOP HEADER ─────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xF01E7A76), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Route Adder',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _openAddRoutePanel,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.add,
                                color: Color(0xFF1E7A76),
                                size: 16,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Add Route',
                                style: TextStyle(
                                  color: Color(0xFF1E7A76),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── LEGEND: road colors ─────────────────────────────────────
          if (_routes.isNotEmpty && !_showPanel)
            Positioned(
              top: 110,
              left: 12,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Routes',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        color: Color(0xFF1E7A76),
                      ),
                    ),
                    const SizedBox(height: 6),
                    ..._routes.map(
                      (r) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 16,
                              height: 8,
                              decoration: BoxDecoration(
                                color: r.color.withOpacity(0.7),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              r.jeepName,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () => _deleteRoute(r),
                              child: const Icon(
                                Icons.close,
                                size: 14,
                                color: Colors.black38,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── ADD ROUTE PANEL (bottom sheet style) ───────────────────
          if (_showPanel)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 24,
                      offset: Offset(0, -4),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),

                    const Text(
                      'Add Route',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: Color(0xFF1E7A76),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Jeep name input
                    const Text(
                      'Jeep / Route Name',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _nameCtrl,
                      decoration: InputDecoration(
                        hintText: 'e.g. "Route 1", "Jeep A"',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFF2E9E99),
                            width: 2,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Show different UI based on mode
                    if (_isChunkSelectionMode && _selectedRoad != null) ...[
                      // Chunk selection mode
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E9E99).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0xFF2E9E99),
                            width: 2,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Chunks on ${_selectedRoad!.name}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Color(0xFF1E7A76),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  ..._buildChunksForRoad(_selectedRoad!).map((
                                    chunk,
                                  ) {
                                    final isSelected = _selectedChunkIndices
                                        .contains(chunk.index);
                                    return GestureDetector(
                                      onTap: () =>
                                          _toggleChunkSelection(chunk.index),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? Colors.lime.withOpacity(0.7)
                                              : Colors.grey.shade200,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: isSelected
                                                ? Colors.lime
                                                : Colors.grey.shade400,
                                            width: isSelected ? 2 : 1,
                                          ),
                                        ),
                                        child: Text(
                                          '${chunk.index + 1}',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11,
                                            color: isSelected
                                                ? Colors.black
                                                : Colors.black54,
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Selected: ${_selectedChunkIndices.isEmpty ? 'none' : _selectedChunkIndices.map((i) => '${i + 1}').join(', ')}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black54,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Show name/color inputs after chunks are selected
                      if (_selectedChunkIndices.isNotEmpty) ...[
                        const Text(
                          'Jeep / Route Name',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _nameCtrl,
                          decoration: InputDecoration(
                            hintText: 'e.g. "Route 1"',
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                color: Color(0xFF2E9E99),
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Route Color',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: _routeColors.map((c) {
                            final selected = c == _selectedColor;
                            return GestureDetector(
                              onTap: () => setState(() => _selectedColor = c),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: selected
                                        ? Colors.black87
                                        : Colors.transparent,
                                    width: 2.5,
                                  ),
                                ),
                                child: selected
                                    ? const Icon(
                                        Icons.check,
                                        color: Colors.white,
                                        size: 14,
                                      )
                                    : null,
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ] else if (!_isChunkSelectionMode) ...[
                      // Road selection mode (original UI)
                      const Text(
                        'Route Color',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: _routeColors.map((c) {
                          final selected = c == _selectedColor;
                          return GestureDetector(
                            onTap: () => setState(() => _selectedColor = c),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected
                                      ? Colors.black87
                                      : Colors.transparent,
                                  width: 2.5,
                                ),
                                boxShadow: selected
                                    ? [
                                        BoxShadow(
                                          color: c.withOpacity(0.5),
                                          blurRadius: 8,
                                          spreadRadius: 1,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: selected
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 16,
                                    )
                                  : null,
                            ),
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 16),

                      // Road selector
                      const Text(
                        'Select Road',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          children: _roads.map((road) {
                            final selected = _selectedRoad?.id == road.id;
                            return GestureDetector(
                              onTap: () => _selectRoadAndEnterChunkMode(road),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? const Color(0xFF2E9E99).withOpacity(0.1)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 14,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1565C0),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        road.name,
                                        style: TextStyle(
                                          fontWeight: selected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          color: selected
                                              ? const Color(0xFF1E7A76)
                                              : Colors.black87,
                                        ),
                                      ),
                                    ),
                                    if (selected)
                                      const Icon(
                                        Icons.check_circle,
                                        color: Color(0xFF2E9E99),
                                        size: 18,
                                      ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                      const SizedBox(height: 22),

                      // Buttons - adapt based on mode
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                if (_isChunkSelectionMode) {
                                  setState(() {
                                    _isChunkSelectionMode = false;
                                    _selectedChunkIndices.clear();
                                    _selectedRoad = null;
                                  });
                                } else {
                                  setState(() => _showPanel = false);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF4A7A72),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  _isChunkSelectionMode ? 'Back' : 'Cancel',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GestureDetector(
                              onTap:
                                  _isChunkSelectionMode &&
                                      _selectedChunkIndices.isNotEmpty
                                  ? _saveRoute
                                  : null,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      (_isChunkSelectionMode &&
                                          _selectedChunkIndices.isNotEmpty)
                                      ? const Color(0xFF2E9E99)
                                      : Colors.grey.shade400,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                alignment: Alignment.center,
                                child: const Text(
                                  'Save Route',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),

          // ── EMPTY STATE ─────────────────────────────────────────────
          if (_roads.isEmpty && !_showPanel)
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 40),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.route, color: Color(0xFF2E9E99), size: 48),
                    SizedBox(height: 10),
                    Text(
                      'No roads to route',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFF1E7A76),
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Go to Road Adder first to create roads, then assign jeep routes here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
