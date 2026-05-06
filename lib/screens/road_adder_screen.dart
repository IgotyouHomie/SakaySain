import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'road_persistence_service.dart';

/// Road Adder — Developer tool to draw roads on Google Maps.
/// Roads are blue dashed polylines visible on the main user map.
/// Tap anywhere on the map to add a point. Points connect to form a road.
class RoadAdderScreen extends StatefulWidget {
  const RoadAdderScreen({super.key});

  @override
  State<RoadAdderScreen> createState() => _RoadAdderScreenState();
}

class _RoadAdderScreenState extends State<RoadAdderScreen> {
  static const LatLng _legazpiCenter = LatLng(13.1391, 123.7438);

  final Completer<GoogleMapController> _mapController = Completer();

  // Current drawing session
  final List<LatLng> _currentPoints = [];
  bool _isDrawing = false;

  // All saved roads (loaded on init + after each save)
  List<SakayRoad> _savedRoads = [];

  // Road name input
  final TextEditingController _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadRoads();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRoads() async {
    final roads = await RoadPersistenceService.loadRoads();
    setState(() => _savedRoads = roads);
  }

  void _onMapTap(LatLng pos) {
    if (!_isDrawing) return;
    setState(() => _currentPoints.add(pos));
  }

  void _undoLastPoint() {
    if (_currentPoints.isEmpty) return;
    setState(() => _currentPoints.removeLast());
  }

  void _clearCurrentDrawing() {
    setState(() {
      _currentPoints.clear();
      _nameCtrl.clear();
    });
  }

  Future<void> _saveRoad() async {
    if (_currentPoints.length < 2) {
      _showSnack('Draw at least 2 points to make a road.');
      return;
    }

    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _showNameDialog();
      return;
    }

    _commitSave(name);
  }

  void _showNameDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Name this Road',
          style: TextStyle(
            color: Color(0xFF1E7A76),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          controller: _nameCtrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'e.g. "Mayon Ave Road"',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF2E9E99), width: 2),
            ),
          ),
          onSubmitted: (v) {
            Navigator.pop(ctx);
            if (v.trim().isNotEmpty) _commitSave(v.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.black54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E9E99),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              final n = _nameCtrl.text.trim();
              if (n.isNotEmpty) _commitSave(n);
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _commitSave(String name) async {
    final road = SakayRoad(
      id: 'road_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      points: List.from(_currentPoints),
    );
    final updated = [..._savedRoads, road];
    await RoadPersistenceService.saveRoads(updated);
    setState(() {
      _savedRoads = updated;
      _currentPoints.clear();
      _nameCtrl.clear();
      _isDrawing = false;
    });
    _showSnack('Road "$name" saved!');
  }

  Future<void> _deleteRoad(SakayRoad road) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete Road?',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Delete "${road.name}"? This will also remove any routes on it.',
        ),
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

    final updatedRoads = _savedRoads.where((r) => r.id != road.id).toList();
    await RoadPersistenceService.saveRoads(updatedRoads);

    // Also remove routes linked to this road
    final existingRoutes = await RoadPersistenceService.loadRoutes();
    final updatedRoutes = existingRoutes
        .where((r) => r.roadId != road.id)
        .toList();
    await RoadPersistenceService.saveRoutes(updatedRoutes);

    setState(() => _savedRoads = updatedRoads);
    _showSnack('"${road.name}" deleted.');
  }

  // ── Map rendering ────────────────────────────────────────────────────────

  Set<Polyline> _buildPolylines() {
    final polylines = <Polyline>{};

    // Saved roads — blue dashed
    for (final road in _savedRoads) {
      if (road.points.length < 2) continue;
      polylines.add(
        Polyline(
          polylineId: PolylineId('saved_${road.id}'),
          points: road.points,
          color: const Color(0xFF1565C0),
          width: 4,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          zIndex: 1,
        ),
      );
    }

    // Current drawing session — lighter blue
    if (_currentPoints.length >= 2) {
      polylines.add(
        Polyline(
          polylineId: const PolylineId('current_drawing'),
          points: _currentPoints,
          color: const Color(0xFF42A5F5),
          width: 4,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          zIndex: 2,
        ),
      );
    }

    return polylines;
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};
    for (var i = 0; i < _currentPoints.length; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('pt_$i'),
          position: _currentPoints[i],
          icon: BitmapDescriptor.defaultMarkerWithHue(
            i == 0 ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueCyan,
          ),
          infoWindow: InfoWindow(title: i == 0 ? 'Start' : 'Point ${i + 1}'),
          zIndex: 3,
        ),
      );
    }
    return markers;
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
            markers: _buildMarkers(),
            onMapCreated: (ctrl) {
              if (!_mapController.isCompleted) _mapController.complete(ctrl);
            },
            onTap: _isDrawing ? _onMapTap : null,
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
                          'Road Adder',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      // Drawing mode toggle
                      GestureDetector(
                        onTap: () => setState(() => _isDrawing = !_isDrawing),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _isDrawing
                                ? Colors.white
                                : Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.6),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isDrawing ? Icons.edit : Icons.edit_off,
                                color: _isDrawing
                                    ? const Color(0xFF1E7A76)
                                    : Colors.white,
                                size: 16,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _isDrawing ? 'Drawing' : 'Draw',
                                style: TextStyle(
                                  color: _isDrawing
                                      ? const Color(0xFF1E7A76)
                                      : Colors.white,
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

          // ── DRAWING TOOLBAR (visible while drawing) ─────────────────
          if (_isDrawing)
            Positioned(
              top: 110,
              right: 12,
              child: Column(
                children: [
                  _MapBtn(
                    icon: Icons.undo,
                    tooltip: 'Undo',
                    onTap: _undoLastPoint,
                  ),
                  const SizedBox(height: 8),
                  _MapBtn(
                    icon: Icons.delete_outline,
                    tooltip: 'Clear',
                    onTap: _clearCurrentDrawing,
                  ),
                  const SizedBox(height: 8),
                  _MapBtn(
                    icon: Icons.save_alt,
                    tooltip: 'Save Road',
                    onTap: _saveRoad,
                    teal: true,
                  ),
                ],
              ),
            ),

          // ── POINT COUNTER (while drawing) ───────────────────────────
          if (_isDrawing && _currentPoints.isNotEmpty)
            Positioned(
              bottom: _savedRoads.isEmpty ? 24 : 220,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E7A76).withOpacity(0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_currentPoints.length} point${_currentPoints.length == 1 ? '' : 's'} — tap map to add more',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),

          // ── SAVED ROADS LIST ─────────────────────────────────────────
          if (_savedRoads.isNotEmpty)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.32,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xF01E7A76)],
                    stops: [0.0, 0.3],
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 28),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.layers,
                            color: Colors.white70,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_savedRoads.length} Saved Road${_savedRoads.length == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                        itemCount: _savedRoads.length,
                        itemBuilder: (ctx, i) {
                          final road = _savedRoads[i];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1565C0),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        road.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                      Text(
                                        '${road.points.length} points',
                                        style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => _deleteRoad(road),
                                  child: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.white54,
                                    size: 20,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── EMPTY STATE hint ─────────────────────────────────────────
          if (_savedRoads.isEmpty && !_isDrawing)
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
                  children: [
                    const Icon(
                      Icons.add_road,
                      color: Color(0xFF2E9E99),
                      size: 48,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'No roads yet',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFF1E7A76),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Tap "Draw" at the top to start adding a road on the map.',
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

// ── Shared map button ──────────────────────────────────────────────────────

class _MapBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool teal;

  const _MapBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.teal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: teal ? const Color(0xFF2E9E99) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 6),
            ],
          ),
          child: Icon(
            icon,
            color: teal ? Colors.white : const Color(0xFF2E9E99),
            size: 22,
          ),
        ),
      ),
    );
  }
}
