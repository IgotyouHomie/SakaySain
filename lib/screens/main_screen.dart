import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

import 'settings_screen.dart';
import 'find_jeep_flow.dart';
import 'road_persistence_service.dart';
import 'user_marker_painter.dart';
import '../services/road_intelligence_service.dart';

// ── Legazpi City, Albay bounds ──────────────────────────────────────────────
const LatLng _legazpiCenter = LatLng(13.1391, 123.7438);
const double _minZoom = 12.0;
const double _maxZoom = 19.0;

// ── Chunk size — must match developer_screen.dart exactly ──────────────────
// Roads are split into fixed ~50m geographic segments.
// Each segment = one short solid polyline with a 15% gap on each side.
// Because gaps are defined in real-world meters (not screen pixels),
// the dashes stay the same physical size at every zoom level.
const double _mainChunkLengthMeters = 50.0;

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static final LatLngBounds _legazpiBounds = LatLngBounds(
    southwest: const LatLng(13.0800, 123.6800),
    northeast: const LatLng(13.2100, 123.8100),
  );

  final Completer<GoogleMapController> _controller = Completer();
  final RoadIntelligenceService _roadIntelligence = RoadIntelligenceService();

  LatLng? _currentLatLng;
  double _currentHeading = 0.0; // degrees 0–360, 0 = north
  BitmapDescriptor? _userMarkerIcon; // arrow icon, rebuilt on heading change
  StreamSubscription<Position>? _positionStream;
  bool _followUser = true;
  bool _ghostMode = false;

  // Roads and routes from Developer Mode
  List<SakayRoad> _roads = [];
  List<SakayRoute> _routes = [];

  // Stats from Road Intelligence Service (updates every 2mins)
  late Map<String, String> _mainScreenStats;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );

    // Initialize road intelligence
    _roadIntelligence.initialize();
    _roadIntelligence.addUpdateListener(_onRoadIntelligenceUpdate);

    // Initialize main screen stats
    _mainScreenStats = {
      'activeJeepsNearby': '0',
      'lastJeepPassed': '--',
      'nearestChunk': '--',
      'avgWaitTime': '--',
      'commonJeeps': '--',
      'activity': '--',
    };

    _initLocation();
    _loadRoadsAndRoutes();
    _rebuildUserMarker(0);
  }

  void _onRoadIntelligenceUpdate() {
    if (mounted) {
      setState(() {
        _mainScreenStats = _roadIntelligence.getMainScreenStats();
      });
    }
  }

  Future<void> _rebuildUserMarker(double heading) async {
    final icon = await UserMarkerPainter.buildIcon(headingDegrees: heading);
    if (mounted) setState(() => _userMarkerIcon = icon);
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _roadIntelligence.removeUpdateListener(_onRoadIntelligenceUpdate);
    _roadIntelligence.dispose();
    super.dispose();
  }

  /// Load roads and routes saved by Developer Mode. Called on init and
  /// whenever we return from settings (in case dev made changes).
  Future<void> _loadRoadsAndRoutes() async {
    final roads = await RoadPersistenceService.loadRoads();
    final routes = await RoadPersistenceService.loadRoutes();
    if (mounted) {
      setState(() {
        _roads = roads;
        _routes = routes;
      });
    }
  }

  Future<void> _initLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final latLng = LatLng(pos.latitude, pos.longitude);

      final isWithinBounds =
          latLng.latitude >= _legazpiBounds.southwest.latitude &&
          latLng.latitude <= _legazpiBounds.northeast.latitude &&
          latLng.longitude >= _legazpiBounds.southwest.longitude &&
          latLng.longitude <= _legazpiBounds.northeast.longitude;

      if (isWithinBounds) {
        setState(() => _currentLatLng = latLng);
        if (_controller.isCompleted) {
          final ctrl = await _controller.future;
          ctrl.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(target: latLng, zoom: 16),
            ),
          );
        }
      }

       _positionStream =
           Geolocator.getPositionStream(
             locationSettings: const LocationSettings(
               accuracy: LocationAccuracy.high,
               distanceFilter: 3,
             ),
           ).listen((Position p) async {
             final newPos = LatLng(p.latitude, p.longitude);
             final newHeading = p.heading ?? 0.0;
             final headingChanged = (newHeading - _currentHeading).abs() > 5.0;
             final isWithin =
                 newPos.latitude >= _legazpiBounds.southwest.latitude &&
                 newPos.latitude <= _legazpiBounds.northeast.latitude &&
                 newPos.longitude >= _legazpiBounds.southwest.longitude &&
                 newPos.longitude <= _legazpiBounds.northeast.longitude;

             if (isWithin) {
               if (headingChanged) {
                 _currentHeading = newHeading;
                 _rebuildUserMarker(newHeading); // async, no await needed
               }
               setState(() => _currentLatLng = newPos);

               // Update road intelligence with new location
               _roadIntelligence.updateIntelligence(newPos);

               if (_followUser && _controller.isCompleted) {
                 final ctrl = await _controller.future;
                 ctrl.animateCamera(CameraUpdate.newLatLng(newPos));
               }
             }
           });
    } catch (_) {}
  }

  Future<void> _recenter() async {
    setState(() => _followUser = true);
    if (_currentLatLng != null && _controller.isCompleted) {
      final ctrl = await _controller.future;
      ctrl.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _currentLatLng!, zoom: 16),
        ),
      );
    }
  }

  Set<Marker> _buildMarkers() {
    if (_currentLatLng == null) return {};
    return {
      Marker(
        markerId: const MarkerId('user'),
        position: _currentLatLng!,
        // Arrow icon with heading — falls back while icon is being built
        icon:
            _userMarkerIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        flat: true, // lies flat on map plane, not upright pin
        anchor: const Offset(0.5, 0.5), // centre of icon = user position
        zIndex: 5,
      ),
    };
  }

  /// Splits a road into fixed ~50 m geographic chunks and returns the
  /// exact start/end LatLng for each chunk.
  /// Each chunk is rendered as a separate polyline with inset gaps so they're
  /// visually distinguishable as separate dashes (like a dashed line on paper).
  List<({LatLng start, LatLng end})> _buildChunkSegments(SakayRoad road) {
    const double insetStart = 0.1; // Skip first 10% of each chunk
    const double insetEnd = 0.9; // Skip last 10% of each chunk
    final segments = <({LatLng start, LatLng end})>[];
    if (road.points.length < 2) return segments;

    for (int i = 0; i < road.points.length - 1; i++) {
      final a = road.points[i];
      final b = road.points[i + 1];
      final distM = _haversineMeters(a, b);
      final numChunks = (distM / _mainChunkLengthMeters).ceil().clamp(1, 200);

      for (int j = 0; j < numChunks; j++) {
        final t0 = j / numChunks;
        final t1 = (j + 1) / numChunks;
        // Apply inset to each chunk to create gaps (visual dashes)
        final adjustedT0 = t0 + (t1 - t0) * insetStart;
        final adjustedT1 = t0 + (t1 - t0) * insetEnd;
        segments.add((
          start: _lerpLatLng(a, b, adjustedT0),
          end: _lerpLatLng(a, b, adjustedT1),
        ));
      }
    }
    return segments;
  }

  /// Linear interpolation between two LatLng points.
  static LatLng _lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );

  /// Haversine distance in metres between two LatLng points.
  static double _haversineMeters(LatLng a, LatLng b) {
    const R = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final s =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * R * math.asin(math.sqrt(s));
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

    // Rebuild chunks for this road (exact same logic as route_adder_screen)
    final chunks = _buildChunksForRoad(road);
    if (chunks.isEmpty) return route.points;

    final points = <LatLng>[];

    // Process each chunk path segment (typically just one for now)
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

  /// Builds all map polylines.
  ///
  /// Roads are rendered as chunk dashes identical to the developer screen —
  /// each ~50 m chunk is a separate solid polyline (no PatternItem).
  /// Routes sit on top as wide translucent colour overlays.
  Set<Polyline> _buildPolylines() {
    final polylines = <Polyline>{};
    int chunkIdx = 0;

    for (final road in _roads) {
      if (road.points.length < 2) continue;

      // Each chunk = its own short solid polyline.
      // The geographic inset creates the gap — zoom-independent.
      for (final seg in _buildChunkSegments(road)) {
        polylines.add(
          Polyline(
            polylineId: PolylineId('chunk_${road.id}_${chunkIdx++}'),
            points: [seg.start, seg.end],
            color: const Color(
              0xFF00BCD4,
            ).withOpacity(0.8), // teal with better opacity
            width: 7, // Slightly thicker for better visibility
            zIndex: 3,
          ),
        );
      }
    }

    // Route overlays (wide translucent colour on top of chunk dashes)
    // Routes now use chunk-based path reconstruction if chunkPath is available
    for (final route in _routes) {
      final points = _getRoutePoints(route);
      if (points.length < 2) continue;
      polylines.add(
        Polyline(
          polylineId: PolylineId('route_${route.id}'),
          points: points,
          color: route.color.withOpacity(
            0.5,
          ), // Slightly more opaque for clarity
          width: 16, // Slightly wider to clearly show route
          zIndex: 2, // Below chunk to show alignment
        ),
      );
    }

    return polylines;
  }

  /// Builds chunk objects for a road.
  /// Each chunk is a small ~50m segment with start/end coordinates.
  List<({LatLng start, LatLng end, int index})> _buildChunksForRoad(
    SakayRoad road,
  ) {
    final chunks = <({LatLng start, LatLng end, int index})>[];
    if (road.points.length < 2) return chunks;

    int chunkIndex = 0;
    for (int i = 0; i < road.points.length - 1; i++) {
      final a = road.points[i];
      final b = road.points[i + 1];
      final distM = _haversineMeters(a, b);
      final numChunks = (distM / _mainChunkLengthMeters).ceil().clamp(1, 200);

      for (int j = 0; j < numChunks; j++) {
        final t0 = j / numChunks;
        final t1 = (j + 1) / numChunks;
        chunks.add((
          start: _lerpLatLng(a, b, t0),
          end: _lerpLatLng(a, b, t1),
          index: chunkIndex,
        ));
        chunkIndex++;
      }
    }
    return chunks;
  }

  void _onFindJeepTapped() {
    if (_currentLatLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Waiting for your location...'),
          backgroundColor: Color(0xFF2E9E99),
        ),
      );
      return;
    }

    // Check eligibility: user must be near a road with routes
    if (!_isUserEligibleForFindJeep()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No jeep routes found near your location'),
          backgroundColor: Color(0xFF2E9E99),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            FindJeepFlowScreen(userLocation: _currentLatLng!),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  /// Find the nearest road to the user (if within range).
  /// Returns (road, distance in meters) or null if none found.
  ({SakayRoad road, double distanceMeters})? _getUserNearestRoad() {
    if (_currentLatLng == null || _roads.isEmpty) return null;

    ({SakayRoad road, double distanceMeters})? nearest;
    double minDist = double.infinity;

    for (final road in _roads) {
      if (road.points.length < 2) continue;

      // Find shortest distance from user to any segment of this road
      for (int i = 0; i < road.points.length - 1; i++) {
        final a = road.points[i];
        final b = road.points[i + 1];

        // Project user onto segment
        final dx = b.longitude - a.longitude;
        final dy = b.latitude - a.latitude;
        final len2 = dx * dx + dy * dy;
        if (len2 == 0) continue;

        final t =
            ((_currentLatLng!.latitude - a.latitude) * dy +
                (_currentLatLng!.longitude - a.longitude) * dx) /
            len2;
        final clampedT = t.clamp(0.0, 1.0);
        final nearLat = a.latitude + clampedT * dy;
        final nearLon = a.longitude + clampedT * dx;
        final segmentPoint = LatLng(nearLat, nearLon);

        final dist = _haversineMeters(_currentLatLng!, segmentPoint);
        if (dist < minDist) {
          minDist = dist;
          nearest = (road: road, distanceMeters: dist);
        }
      }
    }

    return nearest;
  }

  /// Check if user is eligible to find jeeps (must be near a road with an active route).
  bool _isUserEligibleForFindJeep() {
    final road = _getUserNearestRoad();
    if (road == null || road.distanceMeters > 30.0) return false;

    // Check if this road has any routes
    return _routes.any((r) => r.roadId == road.road.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── MAP ─────────────────────────────────────────────────────
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: _legazpiCenter,
              zoom: 15,
            ),
            markers: _buildMarkers(),
            polylines: _buildPolylines(),
            myLocationEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            minMaxZoomPreference: const MinMaxZoomPreference(
              _minZoom,
              _maxZoom,
            ),
            cameraTargetBounds: CameraTargetBounds(_legazpiBounds),
            onMapCreated: (GoogleMapController ctrl) {
              if (!_controller.isCompleted) _controller.complete(ctrl);
            },
            onCameraMoveStarted: () {
              if (_followUser) setState(() => _followUser = false);
            },
          ),

          // ── TOP HEADER ───────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xDD1E7A76), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _TopStat(
                        label: 'Active Jeeps Nearby:',
                        value: _mainScreenStats['activeJeepsNearby'] ?? '0',
                      ),
                      const Text(
                        'SAKAYSAIN',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          letterSpacing: 2,
                        ),
                      ),
                      _TopStat(
                        label: 'Last Jeep Passed:',
                        value: _mainScreenStats['lastJeepPassed'] ?? '--',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── LOCK/UNLOCK + RECENTER ───────────────────────────────────
          Positioned(
            top: 110,
            right: 16,
            child: GestureDetector(
              onTap: () => setState(() => _followUser = !_followUser),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _followUser ? const Color(0xFF2E9E99) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: Icon(
                  _followUser ? Icons.lock : Icons.lock_open,
                  color: _followUser ? Colors.white : const Color(0xFF2E9E99),
                  size: 22,
                ),
              ),
            ),
          ),
          if (!_followUser)
            Positioned(
              top: 110,
              right: 75,
              child: GestureDetector(
                onTap: _recenter,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.my_location,
                    color: Color(0xFF2E9E99),
                    size: 22,
                  ),
                ),
              ),
            ),

          // ── BOTTOM PANEL ─────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Color(0xEE1E7A76),
                    Color(0xFF1E7A76),
                  ],
                  stops: [0.0, 0.35, 1.0],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 50, 20, 30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Settings
                      GestureDetector(
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SettingsScreen(),
                            ),
                          );
                          // Reload roads/routes in case Dev Mode made changes
                          _loadRoadsAndRoutes();
                        },
                        child: Column(
                          children: const [
                            Icon(Icons.settings, color: Colors.white, size: 28),
                            SizedBox(height: 4),
                            Text(
                              'Settings',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Find Nearby Jeep
                      GestureDetector(
                        onTap: _onFindJeepTapped,
                        child: Container(
                          width: 115,
                          height: 115,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF2E9E99),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.35),
                              width: 5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFF2E9E99,
                                ).withOpacity(0.55),
                                blurRadius: 24,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.location_on,
                                color: Colors.white,
                                size: 32,
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Find Nearby\nJeep',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Ghost Mode
                      Column(
                        children: [
                          Transform.scale(
                            scale: 0.85,
                            child: Switch(
                              value: _ghostMode,
                              onChanged: (v) => setState(() => _ghostMode = v),
                              activeColor: Colors.white,
                              activeTrackColor: const Color(0xFF2E9E99),
                              inactiveThumbColor: Colors.white54,
                              inactiveTrackColor: Colors.white24,
                            ),
                          ),
                          const Text(
                            'Ghost Mode',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Stats card
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.2)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _BottomStat(
                          label: 'Nearest Road Chunk',
                          value: _mainScreenStats['nearestChunk'] ?? '--',
                        ),
                        _BottomStat(
                          label: 'Avg Wait Time',
                          value: _mainScreenStats['avgWaitTime'] ?? '--',
                        ),
                        _BottomStat(
                          label: 'Common Jeeps',
                          value: _mainScreenStats['commonJeeps'] ?? '--',
                        ),
                        _BottomStat(
                          label: 'Activity',
                          value: _mainScreenStats['activity'] ?? '--',
                        ),
                      ],
                    ),
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

class _TopStat extends StatelessWidget {
  final String label, value;
  const _TopStat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ],
    );
  }
}

class _BottomStat extends StatelessWidget {
  final String label, value;
  const _BottomStat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}
