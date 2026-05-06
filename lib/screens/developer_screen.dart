import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

import '../services/road_network_engine.dart';
import '../simulation/models/road_chunk.dart';
import '../simulation/models/road_direction.dart';
import '../simulation/models/road_graph.dart';
import '../simulation/models/tracked_eta.dart';
import '../simulation/models/jeep_type.dart';
import '../simulation/models/chunk_connection.dart';
import 'road_persistence_service.dart';
import 'user_marker_painter.dart';

// ═══════════════════════════════════════════════════════════════════════════
// DEVELOPER SCREEN — Unified, Google Maps only
//
// Everything lives here on ONE Google Map:
//   • Road Adder       — tap map to draw roads (blue dashed polylines)
//   • Route Adder      — assign colored jeep routes to roads
//   • Road Chunks      — fixed-size dash marks per ~50m segment, tappable
//   • Snapzones        — translucent circles per chunk (toggleable)
//   • Mock Jeep        — place a moving mock jeep marker on a road
//   • Traffic Zone     — mark a road segment as congested
//   • ETA / Chunk Stats— tap any chunk dash to inspect statistics
//   • Flow Heatmap     — color chunks by jeep flow rate
//   • Waiting Pin      — place user waiting pin on chunk + pick direction
//
// No 2D canvas. No separate simulation screen. No nested dev modes.
// The old Road Editor (abstract canvas) is fully replaced by this screen.
// Snapzones are automatic per chunk — not manually placed.
// ═══════════════════════════════════════════════════════════════════════════

// ── Constants ────────────────────────────────────────────────────────────
const LatLng _legazpiCenter = LatLng(13.1391, 123.7438);
const double _snapzoneMeterRadius = 30.0; // per chunk, auto
const double _chunkLengthMeters = 50.0;

// ── Jeep type colors ──────────────────────────────────────────────────────
const List<Color> _routeColorPalette = [
  Color(0xFFFF5722),
  Color(0xFF9C27B0),
  Color(0xFF2196F3),
  Color(0xFFFF9800),
  Color(0xFF4CAF50),
  Color(0xFFF44336),
  Color(0xFF00BCD4),
  Color(0xFFFFEB3B),
  Color(0xFFE91E63),
  Color(0xFF795548),
];

// ── Dev mode enum ─────────────────────────────────────────────────────────
enum _DevMode {
  view, // just view, tap chunk to inspect
  drawRoad, // tap map to add road points
  drawRoute, // configure and assign a route to a road
  placeMockJeep, // tap map to place a mock moving jeep
  placeTraffic, // tap road to mark a traffic zone
  teleportUser, // tap map to move user location
}

// ── Jeep flow state enum (integrated Find Jeep in dev screen) ──────────────
enum _JeepFlowState {
  idle, // no active jeep flow
  moving, // waiting for user to place waiting pin on chunk
  pickingJeepType, // user choosing jeep type
  waiting, // waiting for jeep to arrive
  arrived, // jeep arrived
}

// ── Chunk data model (runtime only — for stats simulation) ────────────────
class _ChunkData {
  final int id;
  final String roadLabel;
  final int indexInRoad;
  final LatLng midpoint;
  final LatLng start;
  final LatLng end;
  final RoadChunk? realChunk;
  double flowRate = 0;
  int observedPassCount = 0;
  int speculativePassCount = 0;
  double avgArrivalInterval = 0;
  double avgTravelTime = 0;
  DateTime? lastJeepPassTime;
  Map<String, double> flowByType = {};
  Map<String, double> arrivalIntervalByType = {};

  _ChunkData({
    required this.id,
    required this.roadLabel,
    required this.indexInRoad,
    required this.midpoint,
    required this.start,
    required this.end,
    this.realChunk,
  });

  String get label => '$roadLabel-$indexInRoad';

  /// Direction label based on real geographic angle
  String directionLabel(bool forward) {
    final dLat = forward
        ? end.latitude - start.latitude
        : start.latitude - end.latitude;
    final dLng = forward
        ? end.longitude - start.longitude
        : start.longitude - end.longitude;
    final angle = math.atan2(dLng, dLat) * 180 / math.pi;
    if (angle >= -22.5 && angle < 22.5) return 'North ↑';
    if (angle >= 22.5 && angle < 67.5) return 'North-East ↗';
    if (angle >= 67.5 && angle < 112.5) return 'East →';
    if (angle >= 112.5 && angle < 157.5) return 'South-East ↘';
    if (angle >= 157.5 || angle < -157.5) return 'South ↓';
    if (angle >= -157.5 && angle < -112.5) return 'South-West ↙';
    if (angle >= -112.5 && angle < -67.5) return '← West';
    return 'North-West ↖';
  }
}

// ── Mock jeep (runtime) ───────────────────────────────────────────────────
class _MockJeep {
  final int id;
  final String jeepType;
  LatLng position;
  double speed; // km/h
  int currentChunkIdx; // which chunk it's on
  double chunkProgress;
  int lastStatChunkIdx;
  bool forward;
  final String roadId;

  _MockJeep({
    required this.id,
    required this.jeepType,
    required this.position,
    required this.speed,
    required this.currentChunkIdx,
    required this.forward,
    required this.roadId,
  }) : chunkProgress = 0,
       lastStatChunkIdx = currentChunkIdx;
}

// ── Traffic zone ──────────────────────────────────────────────────────────
class _TrafficZone {
  final LatLng start;
  final LatLng end;
  final double slowFactor; // 0.2 = 20% of normal speed
  _TrafficZone({
    required this.start,
    required this.end,
    this.slowFactor = 0.25,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// MAIN WIDGET
// ═══════════════════════════════════════════════════════════════════════════

class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key});

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen>
    with SingleTickerProviderStateMixin {
  // Map controller
  final Completer<GoogleMapController> _mapCtrl = Completer();

  // Persisted data
  List<SakayRoad> _roads = [];
  List<SakayRoute> _routes = [];
  List<JeepType> _jeepTypes = [];
  List<ChunkConnection> _chunkConnections = [];

  // User location (real GPS in normal mode, manually movable in dev mode)
  LatLng? _userLatLng;
  double _userHeading = 0.0; // 0–360 degrees, 0 = north
  BitmapDescriptor? _userMarkerIcon; // directional arrow icon
  StreamSubscription<Position>? _positionStream;
  bool _trackUserLocation = true; // false = manually teleported
  bool _offlineMode = false; // true = GPS disabled, emulator-friendly

  // Legazpi center used as fallback for emulators
  static const LatLng _emulatorFallback = LatLng(13.1391, 123.7438);
  static const double _mainChunkLengthMeters = 50.0;

  // Road drawing session
  final List<LatLng> _draftPoints = [];

  // Route adder
  String _routeJeepName = '';
  Color _routeColor = _routeColorPalette.first;
  SakayRoad? _routeTargetRoad;
  final TextEditingController _routeNameCtrl = TextEditingController();
  // Chunk-by-chunk route building (NEW)
  List<_ChunkData> _routeChunks = []; // Selected chunks for route
  _ChunkData? _selectedChunkForRoute; // Current chunk being added to route

  // Derived chunks per road
  final Map<String, List<_ChunkData>> _chunksByRoad = {};

  // Real RoadChunk data from buried models (via RoadNetworkEngine)
  List<RoadChunk> _realChunks = [];
  Map<String, List<RoadChunk>> _realChunksByRoadId = {};
  Map<String, RoadGraph> _roadGraphsByRoadId = {};

  // Mock jeeps
  final List<_MockJeep> _mockJeeps = [];
  int _mockJeepIdCounter = 100;
  String _mockJeepType = 'Jeep A';
  Timer? _simTimer;

  // Traffic zones
  final List<_TrafficZone> _trafficZones = [];

  // Waiting pin
  _ChunkData? _waitingPinChunk;
  LatLng? _waitingPinLatLng;
  bool? _waitingPinForward; // true = forward direction
  bool _isWaiting = false;
  DateTime? _waitStartAt;
  double _waitEta = 0;

  // Restored waiting analytics chain (V3 foundation)
  TrackedEta? _realEta;
  List<RoadChunk> _etaPathChunks = [];
  double _waitInitialEtaSeconds = 0;
  double _waitCurrentEtaSeconds = 0;
  double _waitPredictionStabilityAccumulator = 0;
  int _waitPredictionStabilitySamples = 0;
  double? _waitPreviousEtaSample;
  DateTime? _waitPredictionGeneratedAt;

  int _actualWaitSeconds = 0;
  double _accuracy = 0;
  double _predictedArrival = 0;
  double _initialPrediction = 0;

  // Find Jeep flow state (integrated, in-place on dev screen)
  _JeepFlowState _jeepFlowState = _JeepFlowState.idle;
  String? _selectedJeepType;
  RoadDirection? _selectedDirection;
  late AnimationController _jeepSheetAnimCtrl;
  late Animation<Offset> _jeepSheetSlide;

  // Toggles
  _DevMode _devMode = _DevMode.view;
  bool _showSnapzones = false;
  bool _showFlowHeat = false;
  bool _showChunkStats = true;
  bool _panelExpanded = false;

  // Bottom panel tabs
  int _panelTab = 0; // 0=roads, 1=routes, 2=simulation, 3=stats

  // Zoom level tracking (for chunk marker sizing)
  double _currentZoom = 14.0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
    _loadData();
    _initUserLocation();
    _startSimTimer();
    _rebuildUserMarker(0); // build initial arrow icon

    // Initialize Find Jeep flow animations
    _jeepSheetAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _jeepSheetSlide = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _jeepSheetAnimCtrl,
            curve: Curves.easeOutCubic,
          ),
        );
  }

  Future<void> _rebuildUserMarker(double heading) async {
    final icon = await UserMarkerPainter.buildIcon(
      headingDegrees: heading,
      isDevUser: true, // teal colour for dev user
    );
    if (mounted) setState(() => _userMarkerIcon = icon);
  }

  @override
  void dispose() {
    _jeepSheetAnimCtrl.dispose();
    _simTimer?.cancel();
    _positionStream?.cancel();
    _routeNameCtrl.dispose();
    super.dispose();
  }

  // ── Data loading ─────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    final roads = await RoadPersistenceService.loadRoads();
    final routes = await RoadPersistenceService.loadRoutes();
    final jeepTypes = await RoadPersistenceService.loadJeepTypes();
    final chunkConnections =
        await RoadPersistenceService.loadChunkConnections();

    // Load real chunks from RoadNetworkEngine
    final network = await RoadNetworkEngine.buildRoadNetwork();

    if (!mounted) return;
    setState(() {
      _roads = roads;
      _routes = routes;
      _jeepTypes = jeepTypes;
      _chunkConnections = chunkConnections;
      _realChunks = network.allChunks;
      _realChunksByRoadId = network.chunksByRoadId;
      _roadGraphsByRoadId = network.graphsByRoadId;
      _rebuildAllChunks();
    });
  }

  // ── User location initialization ──────────────────────────────────────────
  // Falls back to emulator-friendly Legazpi center if GPS is unavailable.
  // In dev mode this is fine — user can teleport manually anyway.

  Future<void> _initUserLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Emulator / no GPS: start at Legazpi center
      _setOfflineFallback();
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _setOfflineFallback();
      return;
    }

    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 6));
      final latLng = LatLng(pos.latitude, pos.longitude);
      if (mounted) {
        setState(() {
          _userLatLng = latLng;
          _offlineMode = false;
        });
      }

      _positionStream =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 3,
            ),
          ).listen((Position p) async {
            if (!_trackUserLocation || !mounted) return;
            final newHeading = p.heading ?? 0.0;
            final headingChanged = (newHeading - _userHeading).abs() > 5.0;
            if (headingChanged) {
              _userHeading = newHeading;
              _rebuildUserMarker(newHeading);
            }
            setState(() => _userLatLng = LatLng(p.latitude, p.longitude));
          });
    } catch (_) {
      // GPS timeout or error — fall back to emulator position
      _setOfflineFallback();
    }
  }

  void _setOfflineFallback() {
    if (!mounted) return;
    setState(() {
      _userLatLng = _emulatorFallback;
      _offlineMode = true;
      _trackUserLocation = false; // allow free teleport
    });
  }

  /// Teleport the dev user to [pos] and stop GPS tracking.
  void _teleportUser(LatLng pos) {
    setState(() {
      _userLatLng = pos;
      _trackUserLocation = false;
      _offlineMode = false; // clear flag once manually placed
    });
  }

  // ── Chunk building ────────────────────────────────────────────────────────
  // Splits each road into ~50m segments. Each segment = one chunk with a
  // tappable midpoint marker and a snapzone circle.

  void _rebuildAllChunks() {
    _chunksByRoad.clear();
    int globalId = 0;
    for (final road in _roads) {
      final chunks = <_ChunkData>[];
      final realChunks = _realChunksByRoadId[road.id] ?? const <RoadChunk>[];
      var roadChunkIndex = 0;
      if (road.points.length < 2) continue;
      for (int i = 0; i < road.points.length - 1; i++) {
        final a = road.points[i];
        final b = road.points[i + 1];
        final distM = _latLngDistanceMeters(a, b);
        final numChunks = (distM / _chunkLengthMeters).ceil().clamp(1, 99);
        for (int j = 0; j < numChunks; j++) {
          final t0 = j / numChunks;
          final t1 = (j + 1) / numChunks;
          final tMid = (t0 + t1) / 2;
          final cStart = _lerpLatLng(a, b, t0);
          final cEnd = _lerpLatLng(a, b, t1);
          final cMid = _lerpLatLng(a, b, tMid);
          chunks.add(
            _ChunkData(
              id: globalId++,
              roadLabel: road.name,
              indexInRoad: roadChunkIndex + 1,
              midpoint: cMid,
              start: cStart,
              end: cEnd,
              realChunk: roadChunkIndex < realChunks.length
                  ? realChunks[roadChunkIndex]
                  : null,
            ),
          );
          roadChunkIndex++;
        }
      }
      _chunksByRoad[road.id] = chunks;
    }
  }

  List<_ChunkData> get _allChunks =>
      _chunksByRoad.values.expand((c) => c).toList();

  String _chunkDisplayLabelById(int id) {
    for (final chunk in _allChunks) {
      if (chunk.id == id) {
        return chunk.label;
      }
    }
    return 'Chunk ${id + 1}';
  }

  // ── Simulation timer ──────────────────────────────────────────────────────

  void _startSimTimer() {
    _simTimer?.cancel();
    _simTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) _tickSimulation();
    });
  }

  void _tickSimulation() {
    setState(() {
      if (_mockJeeps.isNotEmpty) {
        for (final jeep in _mockJeeps) {
          _moveJeep(jeep);
          _updateChunkStats(jeep);
        }
      }
      if (_isWaiting) _updateWaitEta();
    });
  }

  void _moveJeep(_MockJeep jeep) {
    final roadChunks = _chunksByRoad[jeep.roadId];
    if (roadChunks == null || roadChunks.isEmpty) return;

    // Check for traffic zone slowdown.
    double effectiveSpeed = jeep.speed;
    for (final zone in _trafficZones) {
      if (_pointNearSegment(jeep.position, zone.start, zone.end, 0.0005)) {
        effectiveSpeed *= zone.slowFactor;
        break;
      }
    }

    var metersToMove = (effectiveSpeed * 1000 / 3600) * 0.2; // meters in 200ms

    while (metersToMove > 0.0) {
      final idx = jeep.currentChunkIdx.clamp(0, roadChunks.length - 1);
      final chunk = roadChunks[idx];
      final from = jeep.forward ? chunk.start : chunk.end;
      final to = jeep.forward ? chunk.end : chunk.start;
      final chunkLen = _latLngDistanceMeters(chunk.start, chunk.end);
      if (chunkLen < 1) return;

      final remainingOnChunkMeters = (1 - jeep.chunkProgress) * chunkLen;

      if (metersToMove < remainingOnChunkMeters) {
        jeep.chunkProgress += metersToMove / chunkLen;
        jeep.position = _lerpLatLng(from, to, jeep.chunkProgress);
        metersToMove = 0;
      } else {
        jeep.position = to;
        metersToMove -= remainingOnChunkMeters;
        jeep.chunkProgress = 0;

        if (jeep.forward) {
          if (idx < roadChunks.length - 1) {
            jeep.currentChunkIdx = idx + 1;
          } else {
            jeep.forward = false;
          }
        } else {
          if (idx > 0) {
            jeep.currentChunkIdx = idx - 1;
          } else {
            jeep.forward = true;
          }
        }
      }
    }
  }

  void _updateChunkStats(_MockJeep jeep) {
    final roadChunks = _chunksByRoad[jeep.roadId];
    if (roadChunks == null) return;
    final idx = jeep.currentChunkIdx.clamp(0, roadChunks.length - 1);
    if (jeep.lastStatChunkIdx == idx) return;
    jeep.lastStatChunkIdx = idx;
    final chunk = roadChunks[idx];
    chunk.observedPassCount++;
    chunk.lastJeepPassTime = DateTime.now();
    chunk.flowRate = (chunk.flowRate * 0.95) + 0.05;
    chunk.flowByType[jeep.jeepType] =
        (chunk.flowByType[jeep.jeepType] ?? 0) * 0.9 + 0.1;
  }

  void _removeMockJeep(int jeepId) {
    setState(() {
      _mockJeeps.removeWhere((jeep) => jeep.id == jeepId);
    });
  }

  void _updateWaitEta() {
    if (_waitingPinChunk == null || !_isWaiting || _waitStartAt == null) return;

    final elapsed = DateTime.now().difference(_waitStartAt!).inSeconds;
    _waitCurrentEtaSeconds = (_waitInitialEtaSeconds - elapsed)
        .clamp(0, double.infinity)
        .toDouble();

    if (_waitPreviousEtaSample != null) {
      _waitPredictionStabilityAccumulator +=
          (_waitCurrentEtaSeconds - _waitPreviousEtaSample!).abs();
      _waitPredictionStabilitySamples++;
    }
    _waitPreviousEtaSample = _waitCurrentEtaSeconds;
    _waitEta = _waitCurrentEtaSeconds;
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

    // Rebuild chunks for this road using same logic as main screen
    final chunks = <({LatLng start, LatLng end, int index})>[];
    if (road.points.length >= 2) {
      int chunkIndex = 0;
      for (int i = 0; i < road.points.length - 1; i++) {
        final a = road.points[i];
        final b = road.points[i + 1];
        final distM = _latLngDistanceMeters(a, b);
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
    }

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

  // ── Map overlay builders ──────────────────────────────────────────────────

  Set<Polyline> _buildPolylines() {
    final polylines = <Polyline>{};

    // Saved roads — blue dashed
    for (final road in _roads) {
      if (road.points.length < 2) continue;
      polylines.add(
        Polyline(
          polylineId: PolylineId('road_${road.id}'),
          points: road.points,
          color: const Color(0xFF1565C0).withOpacity(0.5),
          width: 3,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          zIndex: 1,
        ),
      );
    }

    // Saved routes — colored translucent overlay
    for (final route in _routes) {
      final points = _getRoutePoints(route);
      if (points.length < 2) continue;
      polylines.add(
        Polyline(
          polylineId: PolylineId('route_${route.id}'),
          points: points,
          color: route.color.withOpacity(0.5), // Improved visibility
          width: 14, // Wider for better visibility
          zIndex: 2,
        ),
      );
    }

    // Road chunks — fixed-size teal dashes (each chunk = separate polyline)
    // The key: each chunk gets a visible line plus a wider transparent hit target.
    // Apply inset (0.1-0.9) to create visual gaps for dash effect
    const double insetStart = 0.1; // Skip first 10% of each chunk
    const double insetEnd = 0.9; // Skip last 10% of each chunk

    for (final chunk in _allChunks) {
      // Apply inset to create dash gaps
      final insetStart_pt = _lerpLatLng(chunk.start, chunk.end, insetStart);
      final insetEnd_pt = _lerpLatLng(chunk.start, chunk.end, insetEnd);

      final maxFlow = _allChunks.isEmpty
          ? 1.0
          : _allChunks
                .map((c) => c.flowRate)
                .fold(0.0, (a, b) => a > b ? a : b)
                .clamp(0.01, double.infinity);
      final normalizedFlow = (chunk.flowRate / maxFlow).clamp(0.0, 1.0);
      final chunkColor = _showFlowHeat
          ? Color.lerp(
              const Color(0xFF1E88E5),
              Colors.redAccent,
              normalizedFlow,
            )!
          : const Color(0xFF00BCD4).withOpacity(0.8); // Better visibility

      polylines.add(
        Polyline(
          polylineId: PolylineId('chunk_hit_${chunk.id}'),
          points: [chunk.start, chunk.end],
          color: Colors.transparent,
          width: 20,
          zIndex: 4,
          consumeTapEvents: true,
          onTap: _showChunkStats ? () => _onChunkTapped(chunk) : null,
        ),
      );

      polylines.add(
        Polyline(
          polylineId: PolylineId('chunk_${chunk.id}'),
          points: [insetStart_pt, insetEnd_pt],
          color: chunkColor,
          width: 7, // Slightly thicker
          zIndex: 5,
        ),
      );
    }

    // Draft road being drawn
    if (_draftPoints.length >= 2) {
      polylines.add(
        Polyline(
          polylineId: const PolylineId('draft'),
          points: _draftPoints,
          color: Colors.orangeAccent,
          width: 4,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          zIndex: 10,
        ),
      );
    }

    // Traffic zones — purple thick lines
    for (int i = 0; i < _trafficZones.length; i++) {
      final z = _trafficZones[i];
      polylines.add(
        Polyline(
          polylineId: PolylineId('traffic_$i'),
          points: [z.start, z.end],
          color: Colors.purpleAccent.withOpacity(0.85),
          width: 8,
          zIndex: 4,
        ),
      );
    }

    // Highlighted route target road
    if (_devMode == _DevMode.drawRoute && _routeTargetRoad != null) {
      polylines.add(
        Polyline(
          polylineId: const PolylineId('route_target_highlight'),
          points: _routeTargetRoad!.points,
          color: Colors.yellow.withOpacity(0.7),
          width: 10,
          zIndex: 9,
        ),
      );
    }

    return polylines;
  }

  Set<Circle> _buildCircles() {
    final circles = <Circle>{};

    // Snapzones — translucent circles per chunk (toggleable)
    if (_showSnapzones) {
      for (final chunk in _allChunks) {
        circles.add(
          Circle(
            circleId: CircleId('snapzone_${chunk.id}'),
            center: chunk.midpoint,
            radius: _snapzoneMeterRadius,
            fillColor: const Color(0xFF2E9E99).withOpacity(0.12),
            strokeColor: const Color(0xFF2E9E99).withOpacity(0.35),
            strokeWidth: 1,
            zIndex: 1,
          ),
        );
      }
    }

    // Waiting pin snapzone highlight
    if (_waitingPinChunk != null) {
      circles.add(
        Circle(
          circleId: const CircleId('waiting_pin_zone'),
          center: _waitingPinLatLng ?? _waitingPinChunk!.midpoint,
          radius: _snapzoneMeterRadius * 1.5,
          fillColor: Colors.yellow.withOpacity(0.2),
          strokeColor: Colors.yellow.withOpacity(0.8),
          strokeWidth: 2,
          zIndex: 5,
        ),
      );
    }

    return circles;
  }

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{};

    // User location marker — directional arrow (teal for dev)
    if (_userLatLng != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('user'),
          position: _userLatLng!,
          icon:
              _userMarkerIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          flat: true,
          anchor: const Offset(0.5, 0.5),
          infoWindow: InfoWindow(
            title: _offlineMode
                ? 'Dev User (Offline / Emulator)'
                : _trackUserLocation
                ? 'Dev User (GPS)'
                : 'Dev User (Teleported)',
          ),
          zIndex: 8,
        ),
      );
    }

    // Draft road points
    for (int i = 0; i < _draftPoints.length; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('draft_pt_$i'),
          position: _draftPoints[i],
          icon: BitmapDescriptor.defaultMarkerWithHue(
            i == 0 ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueOrange,
          ),
          zIndex: 10,
        ),
      );
    }

    // Mock jeeps
    for (final jeep in _mockJeeps) {
      markers.add(
        Marker(
          markerId: MarkerId('jeep_${jeep.id}'),
          position: jeep.position,
          onTap: () => _removeMockJeep(jeep.id),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            jeep.jeepType == 'Jeep A'
                ? BitmapDescriptor.hueGreen
                : jeep.jeepType == 'Jeep B'
                ? BitmapDescriptor.hueBlue
                : BitmapDescriptor.hueViolet,
          ),
          infoWindow: InfoWindow(
            title: jeep.jeepType,
            snippet: 'Speed: ${jeep.speed.toStringAsFixed(0)} km/h',
          ),
          zIndex: 6,
        ),
      );
    }

    // Waiting pin
    if (_waitingPinChunk != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('waiting_pin'),
          position: _waitingPinLatLng ?? _waitingPinChunk!.midpoint,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueYellow,
          ),
          infoWindow: InfoWindow(
            title: 'Waiting Pin',
            snippet: _waitingPinForward == null
                ? 'Tap to set direction'
                : 'Direction: ${_waitingPinChunk!.directionLabel(_waitingPinForward!)}',
          ),
          zIndex: 7,
        ),
      );
    }

    return markers;
  }

  // ── Interaction ───────────────────────────────────────────────────────────

  void _onMapTap(LatLng pos) {
    switch (_devMode) {
      case _DevMode.drawRoad:
        setState(() => _draftPoints.add(pos));
        break;
      case _DevMode.placeMockJeep:
        _placeMockJeep(pos);
        setState(() => _devMode = _DevMode.view);
        break;
      case _DevMode.placeTraffic:
        _placeTrafficZone(pos);
        setState(() => _devMode = _DevMode.view);
        break;
      case _DevMode.teleportUser:
        _teleportUser(pos);
        setState(() => _devMode = _DevMode.view);
        break;
      default:
        break;
    }
  }

  void _onChunkTapped(_ChunkData chunk) {
    if (_jeepFlowState == _JeepFlowState.moving) {
      _onWaitingPinChunkChosen(chunk);
      return;
    }

    final realChunk = chunk.realChunk;
    if (realChunk != null) {
      _showRealChunkStatsSheet(realChunk);
    } else {
      _showChunkStatsSheet(chunk); // Fallback to old UI
    }
  }

  void _onWaitingPinChunkChosen(_ChunkData chunk) {
    final userPos = _userLatLng;
    final realChunk = chunk.realChunk;
    if (userPos == null) {
      _showSnack('Waiting for your location before placing a pin.');
      return;
    }
    if (realChunk == null) {
      _showSnack('Selected chunk has no road intelligence data yet.');
      return;
    }

    final snapped = RoadNetworkEngine.snapWaitingPinToRoad(userPos, realChunk);
    setState(() {
      _waitingPinChunk = chunk;
      _waitingPinLatLng = snapped;
      _waitingPinForward = null;
      _selectedDirection = null;
    });
    _showDirectionSelectorForJeepFlow();
  }

  void _placeWaitingPin(LatLng pos) {
    // Find nearest chunk to tap position
    _ChunkData? nearest;
    double minDist = double.infinity;
    for (final chunk in _allChunks) {
      final d = _latLngDistanceMeters(pos, chunk.midpoint);
      if (d < minDist) {
        minDist = d;
        nearest = chunk;
      }
    }
    if (nearest == null || minDist > 100) {
      _showSnack('Tap closer to a road chunk to place waiting pin.');
      return;
    }
    setState(() {
      _waitingPinChunk = nearest;
      _waitingPinForward = null;
      _devMode = _DevMode.view;
    });
    _openDirectionSheet(nearest);
  }

  void _placeMockJeep(LatLng pos) {
    if (_roads.isEmpty) {
      _showSnack('Add roads first before placing mock jeeps.');
      return;
    }
    // Find nearest road
    SakayRoad? nearestRoad;
    _ChunkData? nearestChunk;
    double minDist = double.infinity;
    for (final road in _roads) {
      final chunks = _chunksByRoad[road.id] ?? [];
      for (final chunk in chunks) {
        final d = _latLngDistanceMeters(pos, chunk.midpoint);
        if (d < minDist) {
          minDist = d;
          nearestRoad = road;
          nearestChunk = chunk;
        }
      }
    }
    if (nearestRoad == null || nearestChunk == null) return;
    final roadChunks = _chunksByRoad[nearestRoad.id]!;
    final jeep = _MockJeep(
      id: _mockJeepIdCounter++,
      jeepType: _mockJeepType,
      position: nearestChunk.midpoint,
      speed: 35 + math.Random().nextDouble() * 20,
      currentChunkIdx: roadChunks.indexOf(nearestChunk),
      forward: true,
      roadId: nearestRoad.id,
    );
    jeep.chunkProgress = 0.5;
    jeep.lastStatChunkIdx = jeep.currentChunkIdx;
    setState(() => _mockJeeps.add(jeep));
    _showSnack('Mock ${jeep.jeepType} placed on ${nearestRoad.name}');
  }

  void _placeTrafficZone(LatLng pos) {
    // Find nearest road segment to place traffic
    for (final road in _roads) {
      if (road.points.length < 2) continue;
      for (int i = 0; i < road.points.length - 1; i++) {
        final a = road.points[i];
        final b = road.points[i + 1];
        if (_pointNearSegment(pos, a, b, 0.001)) {
          setState(() => _trafficZones.add(_TrafficZone(start: a, end: b)));
          _showSnack('Traffic zone added');
          return;
        }
      }
    }
    _showSnack('Tap closer to a road to place traffic zone.');
  }

  Future<void> _saveRoad(String name) async {
    if (_draftPoints.length < 2) return;
    final road = SakayRoad(
      id: 'road_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      points: List.from(_draftPoints),
    );
    final updated = [..._roads, road];
    await RoadPersistenceService.saveRoads(updated);
    setState(() {
      _roads = updated;
      _draftPoints.clear();
      _devMode = _DevMode.view;
      _rebuildAllChunks();
    });
    _showSnack(
      'Road "$name" saved! ${_chunksByRoad[road.id]?.length ?? 0} chunks created.',
    );
  }

  /// Validate that chunks are properly forked if connecting across roads
  bool _validateCrossRoadConnections() {
    if (_routeChunks.length < 2) return true; // Single chunk is always valid

    for (int i = 0; i < _routeChunks.length - 1; i++) {
      final currentChunk = _routeChunks[i];
      final nextChunk = _routeChunks[i + 1];

      // If chunks are on different roads, verify they're connected via fork
      if (currentChunk.roadLabel != nextChunk.roadLabel) {
        final hasConnection = _chunkConnections.any(
          (conn) =>
              conn.fromChunkId == currentChunk.id &&
              conn.toChunkId == nextChunk.id,
        );

        if (!hasConnection) {
          _showSnack(
            'Cannot connect ${currentChunk.label} to ${nextChunk.label} — they must be forked first!',
          );
          return false;
        }
      }
    }
    return true;
  }

  /// Add chunk to route path (for chunk-by-chunk route building)
  void _addChunkToRoute(_ChunkData chunk) {
    setState(() {
      _routeChunks.add(chunk);
      _selectedChunkForRoute = chunk;
    });
    _showSnack('Added ${chunk.label} to route (${_routeChunks.length} total)');
  }

  /// Remove last chunk from route
  void _removeChunkFromRoute() {
    if (_routeChunks.isNotEmpty) {
      final removed = _routeChunks.removeLast();
      setState(() {
        _selectedChunkForRoute = _routeChunks.isNotEmpty
            ? _routeChunks.last
            : null;
      });
      _showSnack('Removed ${removed.label} from route');
    }
  }

  /// Clear all chunks from route
  void _clearRouteChunks() {
    setState(() {
      _routeChunks.clear();
      _selectedChunkForRoute = null;
    });
    _showSnack('Route chunks cleared');
  }

  Future<void> _saveRoute() async {
    if (_routeChunks.isEmpty || _routeNameCtrl.text.trim().isEmpty) {
      _showSnack('Select at least 1 chunk and enter a route name.');
      return;
    }

    // Validate cross-road connections
    if (!_validateCrossRoadConnections()) {
      return;
    }

    // Build points from chunk path
    final points = <LatLng>[];
    for (final chunk in _routeChunks) {
      // Use _ChunkData's LatLng points directly
      if (points.isEmpty) {
        points.add(chunk.start);
      }
      if (!points.contains(chunk.end)) {
        points.add(chunk.end);
      }
    }

    // Use first chunk's road ID
    final firstChunkRoadId =
        _realChunksByRoadId.entries
            .firstWhere(
              (e) => e.value.any((c) => c.id == _routeChunks.first.id),
              orElse: () => MapEntry('', []),
            )
            .key ??
        '';

    final route = SakayRoute(
      id: 'route_${DateTime.now().millisecondsSinceEpoch}',
      jeepName: _routeNameCtrl.text.trim(),
      color: _routeColor,
      roadId: firstChunkRoadId,
      points: points,
    );

    final updated = [..._routes, route];
    await RoadPersistenceService.saveRoutes(updated);
    final savedChunkCount = _routeChunks.length;
    setState(() {
      _routes = updated;
      _routeChunks.clear();
      _selectedChunkForRoute = null;
      _routeNameCtrl.clear();
      _devMode = _DevMode.view;
    });
    _showSnack('Route "${route.jeepName}" saved with $savedChunkCount chunks!');
  }

  Future<void> _deleteRoad(SakayRoad road) async {
    final updatedRoads = _roads.where((r) => r.id != road.id).toList();
    final existingRoutes = await RoadPersistenceService.loadRoutes();
    final updatedRoutes = existingRoutes
        .where((r) => r.roadId != road.id)
        .toList();
    await RoadPersistenceService.saveRoads(updatedRoads);
    await RoadPersistenceService.saveRoutes(updatedRoutes);
    setState(() {
      _roads = updatedRoads;
      _routes = updatedRoutes;
      _rebuildAllChunks();
    });
    _showSnack('"${road.name}" deleted.');
  }

  Future<void> _deleteRoute(SakayRoute route) async {
    final updated = _routes.where((r) => r.id != route.id).toList();
    await RoadPersistenceService.saveRoutes(updated);
    setState(() => _routes = updated);
    _showSnack('"${route.jeepName}" deleted.');
  }

  // ── Jeep Type operations ───────────────────────────────────────────────────

  Future<void> _saveJeepType(JeepType jeepType) async {
    final updated = [..._jeepTypes, jeepType];
    await RoadPersistenceService.saveJeepTypes(updated);
    setState(() => _jeepTypes = updated);
    _showSnack('Jeep Type "${jeepType.name}" created!');
  }

  Future<void> _deleteJeepType(JeepType jeepType) async {
    final updated = _jeepTypes.where((j) => j.id != jeepType.id).toList();
    await RoadPersistenceService.saveJeepTypes(updated);
    setState(() => _jeepTypes = updated);
    _showSnack('Jeep Type "${jeepType.name}" deleted.');
  }

  // ── Fork/Connection operations ─────────────────────────────────────────────

  Future<void> _saveForkConnection(ChunkConnection connection) async {
    final updated = [..._chunkConnections, connection];
    await RoadPersistenceService.saveChunkConnections(updated);
    setState(() => _chunkConnections = updated);
    _showSnack(
      'Fork created: ${_chunkDisplayLabelById(connection.fromChunkId)} → ${_chunkDisplayLabelById(connection.toChunkId)}',
    );
  }

  Future<void> _deleteForkConnection(ChunkConnection connection) async {
    final updated = _chunkConnections
        .where((c) => c.id != connection.id)
        .toList();
    await RoadPersistenceService.saveChunkConnections(updated);
    setState(() => _chunkConnections = updated);
    _showSnack(
      'Fork deleted: ${_chunkDisplayLabelById(connection.fromChunkId)} → ${_chunkDisplayLabelById(connection.toChunkId)}',
    );
  }

  // ── Real chunk stats sheet (powered by RoadNetworkEngine) ───────────────

  void _showRealChunkStatsSheet(RoadChunk chunk) {
    final stats = RoadNetworkEngine.getChunkStats(chunk);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E7A76),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(child: _dragHandle()),
              const SizedBox(height: 16),
              Text(
                'Chunk ${stats.label}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Forward: ${chunk.forwardDirectionLabel}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Text(
                'Backward: ${chunk.reverseDirectionLabel}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 16),
              // ── TRAFFIC & STATISTICS
              _statRow('Observed passes', '${stats.observedPassCount}'),
              _statRow('Speculative passes', '${stats.speculativePassCount}'),
              _statRow(
                'Avg arrival interval',
                stats.avgArrivalIntervalSeconds > 0
                    ? '${stats.avgArrivalIntervalSeconds.toStringAsFixed(1)}s'
                    : 'N/A',
              ),
              _statRow(
                'Flow rate',
                '${stats.flowRatePerMinute.toStringAsFixed(2)} jeeps/min',
              ),
              _statRow(
                'Forward avg travel time',
                stats.forwardAvgTravelTimeSeconds > 0
                    ? '${stats.forwardAvgTravelTimeSeconds.toStringAsFixed(1)}s'
                    : 'N/A',
              ),
              _statRow(
                'Backward avg travel time',
                stats.backwardAvgTravelTimeSeconds > 0
                    ? '${stats.backwardAvgTravelTimeSeconds.toStringAsFixed(1)}s'
                    : 'N/A',
              ),
              _statRow(
                'Last jeep passed',
                stats.lastJeepPassTime == null
                    ? 'N/A'
                    : _formatTime(stats.lastJeepPassTime!),
              ),
              // ── PER-JEEP-TYPE BREAKDOWN
              if (stats.jeepTypeStats.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  'By Jeep Type',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                ...stats.jeepTypeStats.entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.key,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        _statRow('  Pass count', '${e.value.passCount}'),
                        _statRow(
                          '  Avg arrival interval',
                          '${e.value.avgArrivalIntervalSeconds.toStringAsFixed(1)}s',
                        ),
                        _statRow(
                          '  Avg travel time',
                          '${e.value.avgTravelTimeSeconds.toStringAsFixed(1)}s',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // Close button
              GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E9E99),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'Close',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Chunk stats sheet ─────────────────────────────────────────────────────

  void _showChunkStatsSheet(_ChunkData chunk) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E7A76),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(child: _dragHandle()),
              const SizedBox(height: 16),
              Text(
                chunk.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Forward: ${chunk.directionLabel(true)}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Text(
                'Backward: ${chunk.directionLabel(false)}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 16),
              _statRow('Observed passes', '${chunk.observedPassCount}'),
              _statRow('Speculative passes', '${chunk.speculativePassCount}'),
              _statRow(
                'Avg arrival interval',
                chunk.avgArrivalInterval > 0
                    ? '${chunk.avgArrivalInterval.toStringAsFixed(1)}s'
                    : 'N/A',
              ),
              _statRow(
                'Avg travel time',
                chunk.avgTravelTime > 0
                    ? '${chunk.avgTravelTime.toStringAsFixed(1)}s'
                    : 'N/A',
              ),
              _statRow(
                'Flow rate',
                '${chunk.flowRate.toStringAsFixed(2)} jeeps/min',
              ),
              _statRow(
                'Last jeep passed',
                chunk.lastJeepPassTime == null
                    ? 'N/A'
                    : _formatTime(chunk.lastJeepPassTime!),
              ),
              if (chunk.flowByType.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  'By Jeep Type',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                ...chunk.flowByType.entries.map(
                  (e) => _statRow(
                    e.key,
                    '${e.value.toStringAsFixed(2)} jeeps/min',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // (Removed) "Place Waiting Pin Here" — developer flow uses Find Jeep
            ],
          ),
        ),
      ),
    );
  }

  // ── Direction selection sheet ─────────────────────────────────────────────

  void _openDirectionSheet(_ChunkData chunk) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E7A76),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: _dragHandle()),
            const SizedBox(height: 18),
            const Text(
              'Which direction are you waiting for jeeps from?',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Based on road chunk angle',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 20),
            _dirBtn(ctx, chunk.directionLabel(false), false),
            const SizedBox(height: 10),
            _dirBtn(ctx, chunk.directionLabel(true), true),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => Navigator.pop(ctx, null),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white60, fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _waitingPinForward = result;
        _isWaiting = true;
        _waitStartAt = DateTime.now();
        _waitEta = 0;
      });
      _showSnack('Waiting for jeep from ${chunk.directionLabel(result)}');
    }
  }

  Widget _dirBtn(BuildContext ctx, String label, bool forward) {
    return GestureDetector(
      onTap: () => Navigator.pop(ctx, forward),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: forward
              ? const Color(0xFF2E9E99)
              : Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.3)),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  // ── Save road dialog ──────────────────────────────────────────────────────

  void _showSaveRoadDialog() {
    if (_draftPoints.length < 2) {
      _showSnack('Draw at least 2 points first.');
      return;
    }
    final ctrl = TextEditingController();
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
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'e.g. "Mayon Ave"',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF2E9E99), width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E9E99),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(ctx);
                _saveRoad(name);
              }
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── GOOGLE MAP ─────────────────────────────────────────────────
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: _legazpiCenter,
              zoom: 14,
            ),
            polylines: _buildPolylines(),
            circles: _buildCircles(),
            markers: _buildMarkers(),
            onMapCreated: (ctrl) {
              if (!_mapCtrl.isCompleted) _mapCtrl.complete(ctrl);
            },
            onTap: _onMapTap,
            myLocationEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            minMaxZoomPreference: const MinMaxZoomPreference(12, 19),
            onCameraMove: (pos) {
              _currentZoom = pos.zoom;
            },
          ),

          // ── TOP HEADER ─────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xEE1E7A76), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'SAKAYSAIN',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 17,
                                letterSpacing: 1.5,
                              ),
                            ),
                            Text(
                              'Developer Mode',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Quick stats
                      _HeaderChip('R:${_roads.length}', 'Roads'),
                      const SizedBox(width: 6),
                      _HeaderChip('C:${_allChunks.length}', 'Chunks'),
                      const SizedBox(width: 6),
                      _HeaderChip('J:${_mockJeeps.length}', 'Mock jeeps'),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── MODE BADGE (top-left, below header) ───────────────────────
          if (_devMode != _DevMode.view)
            Positioned(
              top: 100,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xEE2E9E99),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _modeHint,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

          // ── MAP TOGGLES (right side) ────────────────────────────────────
          Positioned(
            top: 100,
            right: 12,
            child: Column(
              children: [
                _MapToggle(
                  icon: Icons.radar,
                  label: 'Snap',
                  active: _showSnapzones,
                  onTap: () => setState(() => _showSnapzones = !_showSnapzones),
                ),
                const SizedBox(height: 8),
                _MapToggle(
                  icon: Icons.whatshot,
                  label: 'Heat',
                  active: _showFlowHeat,
                  onTap: () => setState(() => _showFlowHeat = !_showFlowHeat),
                ),
                const SizedBox(height: 8),
                _MapToggle(
                  icon: Icons.info_outline,
                  label: 'Chunks',
                  active: _showChunkStats,
                  onTap: () =>
                      setState(() => _showChunkStats = !_showChunkStats),
                ),
              ],
            ),
          ),

          // ── WAITING STATUS BAR ─────────────────────────────────────────
          if (_isWaiting &&
              _waitingPinChunk != null &&
              _jeepFlowState == _JeepFlowState.idle)
            Positioned(
              top: 100,
              left: 12,
              right: 80,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xEE1E7A76),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.timer, color: Colors.white70, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _waitEta > 0
                            ? 'ETA: ${_waitEta.toStringAsFixed(1)}s | Waiting: ${DateTime.now().difference(_waitStartAt!).inSeconds}s'
                            : 'Waiting... (no ETA yet — no jeep data for chunk)',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() {
                        _isWaiting = false;
                        _waitingPinChunk = null;
                        _waitingPinForward = null;
                        _waitStartAt = null;
                      }),
                      child: const Icon(
                        Icons.close,
                        color: Colors.white70,
                        size: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── BOTTOM PANEL ────────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AbsorbPointer(
              absorbing: _jeepFlowState != _JeepFlowState.idle,
              child: Opacity(
                opacity: _jeepFlowState != _JeepFlowState.idle ? 0.7 : 1.0,
                child: _BottomDevPanel(
                  panelTab: _panelTab,
                  expanded: _panelExpanded,
                  roads: _roads,
                  routes: _routes,
                  jeepTypes: _jeepTypes,
                  chunkConnections: _chunkConnections,
                  devMode: _devMode,
                  draftPoints: _draftPoints,
                  mockJeeps: _mockJeeps,
                  trafficZones: _trafficZones,
                  allChunks: _allChunks,
                  routeChunks: _routeChunks,
                  // Road tab
                  onStartDrawRoad: () =>
                      setState(() => _devMode = _DevMode.drawRoad),
                  onUndoPoint: _draftPoints.isNotEmpty
                      ? () => setState(() => _draftPoints.removeLast())
                      : null,
                  onClearDraft: _draftPoints.isNotEmpty
                      ? () => setState(() => _draftPoints.clear())
                      : null,
                  onSaveDraft: _draftPoints.length >= 2
                      ? _showSaveRoadDialog
                      : null,
                  onCancelDraw: _devMode == _DevMode.drawRoad
                      ? () => setState(() {
                          _devMode = _DevMode.view;
                          _draftPoints.clear();
                        })
                      : null,
                  onDeleteRoad: _deleteRoad,
                  // Route tab
                  routeNameCtrl: _routeNameCtrl,
                  routeColor: _routeColor,
                  routeTargetRoad: _routeTargetRoad,
                  onRouteColorChanged: (c) => setState(() => _routeColor = c),
                  onRouteRoadSelected: (r) =>
                      setState(() => _routeTargetRoad = r),
                  onSaveRoute: _saveRoute,
                  onDeleteRoute: _deleteRoute,
                  // Jeep Type tab
                  onSaveJeepType: _saveJeepType,
                  onDeleteJeepType: _deleteJeepType,
                  // Fork Editor tab
                  onSaveForkConnection: _saveForkConnection,
                  onDeleteForkConnection: _deleteForkConnection,
                  // Simulation tab
                  mockJeepType: _mockJeepType,
                  onMockJeepTypeChanged: (t) =>
                      setState(() => _mockJeepType = t),
                  onPlaceMockJeep: () =>
                      setState(() => _devMode = _DevMode.placeMockJeep),
                  onPlaceTraffic: () =>
                      setState(() => _devMode = _DevMode.placeTraffic),
                  onClearTraffic: () => setState(() => _trafficZones.clear()),
                  onClearMockJeeps: () => setState(() => _mockJeeps.clear()),
                  onFindJeep: _openFindJeepFlowFromDev,
                  // User controls
                  onTeleportUser: () =>
                      setState(() => _devMode = _DevMode.teleportUser),
                  onResumeGps: _offlineMode || !_trackUserLocation
                      ? () async {
                          setState(() => _trackUserLocation = true);
                          await _initUserLocation();
                        }
                      : null,
                  isOfflineMode: _offlineMode,
                  isTeleporting: _devMode == _DevMode.teleportUser,
                  onCancelWait: _isWaiting
                      ? () => setState(() {
                          _isWaiting = false;
                          _waitingPinChunk = null;
                          _waitingPinForward = null;
                        })
                      : null,
                  isWaiting: _isWaiting,
                  // Tab + expand
                  onTabChanged: (t) => setState(() {
                    _panelTab = t;
                    _panelExpanded = true;
                  }),
                  onToggleExpand: () =>
                      setState(() => _panelExpanded = !_panelExpanded),
                ),
              ),
            ),
          ),

          // Jeep flow sheets (picking / waiting / arrived) — always on top
          if (_jeepFlowState != _JeepFlowState.idle)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SlideTransition(
                position: _jeepSheetSlide,
                child: _buildJeepSheet(),
              ),
            ),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String get _modeHint {
    switch (_devMode) {
      case _DevMode.drawRoad:
        return '✏️ Tap map to add road points';
      case _DevMode.placeMockJeep:
        return '🚌 Tap near a road to place jeep';
      case _DevMode.placeTraffic:
        return '🚧 Tap near a road segment';
      case _DevMode.drawRoute:
        return '🎨 Select a road below';
      case _DevMode.teleportUser:
        return '🚀 Tap anywhere to teleport user';
      default:
        return '';
    }
  }

  Widget _dragHandle() => Container(
    width: 44,
    height: 4,
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.35),
      borderRadius: BorderRadius.circular(2),
    ),
  );

  Widget _statRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

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

  // ── Geo helpers ───────────────────────────────────────────────────────────

  static LatLng _lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );

  static double _latLngDistanceMeters(LatLng a, LatLng b) {
    const R = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLon = math.sin(dLon / 2);
    final h =
        sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLon * sinLon;
    return 2 * R * math.asin(math.sqrt(h));
  }

  static bool _pointNearSegment(
    LatLng p,
    LatLng a,
    LatLng b,
    double threshold,
  ) {
    final dx = b.latitude - a.latitude;
    final dy = b.longitude - a.longitude;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) {
      return (p.latitude - a.latitude).abs() < threshold &&
          (p.longitude - a.longitude).abs() < threshold;
    }
    final t =
        ((p.latitude - a.latitude) * dx + (p.longitude - a.longitude) * dy) /
        len2;
    final clampedT = t.clamp(0.0, 1.0);
    final nearLat = a.latitude + clampedT * dx;
    final nearLon = a.longitude + clampedT * dy;
    return (p.latitude - nearLat).abs() < threshold &&
        (p.longitude - nearLon).abs() < threshold;
  }

  // ── Snapzone detection (user in chunk radius) ─────────────────────────────

  /// Find which chunk the user is closest to (if within snapzone radius).
  /// Returns the chunk if within ~30m, null otherwise.
  _ChunkData? _getUserSnapzoneChunk() {
    if (_userLatLng == null) return null;

    _ChunkData? closest;
    double closestDist = double.infinity;

    for (final chunk in _allChunks) {
      final dist = _latLngDistanceMeters(_userLatLng!, chunk.midpoint);
      if (dist < _snapzoneMeterRadius && dist < closestDist) {
        closest = chunk;
        closestDist = dist;
      }
    }

    return closest;
  }

  /// Find the nearest road to the user (if within range).
  /// Returns (road, distance in meters) or null if none found.
  ({SakayRoad road, double distanceMeters})? _getUserNearestRoad() {
    if (_userLatLng == null || _roads.isEmpty) return null;

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
            ((_userLatLng!.latitude - a.latitude) * dy +
                (_userLatLng!.longitude - a.longitude) * dx) /
            len2;
        final clampedT = t.clamp(0.0, 1.0);
        final nearLat = a.latitude + clampedT * dy;
        final nearLon = a.longitude + clampedT * dx;
        final segmentPoint = LatLng(nearLat, nearLon);

        final dist = _latLngDistanceMeters(_userLatLng!, segmentPoint);
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

  void _startFindJeepFlowInPlace() {
    if (_userLatLng == null) {
      _showSnack('Waiting for user location...');
      return;
    }

    setState(() {
      _jeepFlowState = _JeepFlowState.moving;
      _selectedJeepType = null;
      _selectedDirection = null;
      _waitingPinChunk = null;
      _waitingPinLatLng = null;
      _isWaiting = false;
      _realEta = null;
      _etaPathChunks = [];
      _waitInitialEtaSeconds = 0;
      _waitCurrentEtaSeconds = 0;
      _waitPredictionStabilityAccumulator = 0;
      _waitPredictionStabilitySamples = 0;
      _waitPreviousEtaSample = null;
      _waitPredictionGeneratedAt = null;
    });

    _showSnack('Tap a road chunk to place your waiting pin.');
    _jeepSheetAnimCtrl.forward(from: 0);
  }

  void _onJeepTypeSelected(String type) {
    setState(() => _selectedJeepType = type);
  }

  void _showDirectionSelectorForJeepFlow() {
    if (_waitingPinChunk == null) {
      _showSnack('Place a waiting pin first by tapping a road chunk.');
      return;
    }

    showDialog<RoadDirection>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Direction'),
        content: Text('Direction from ${_waitingPinChunk!.label}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, RoadDirection.backward),
            child: const Text('Backward'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, RoadDirection.forward),
            child: const Text('Forward'),
          ),
        ],
      ),
    ).then((result) {
      if (result != null) {
        setState(() {
          _selectedDirection = result;
          _waitingPinForward = result == RoadDirection.forward;
          _jeepFlowState = _JeepFlowState.pickingJeepType;
        });
        _jeepSheetAnimCtrl.forward(from: 0);
      }
    });
  }

  List<RoadChunk> _buildEtaPath(RoadChunk fromChunk, RoadChunk toChunk) {
    if (fromChunk.id == toChunk.id) return [fromChunk];

    // Attempt graph-based path construction first (preferred)
    try {
      // Find roadId for both chunks (they must be on the same road for graph walk)
      String? fromRoadId;
      String? toRoadId;
      _realChunksByRoadId.forEach((roadId, chunks) {
        if (fromRoadId == null && chunks.any((c) => c.id == fromChunk.id)) {
          fromRoadId = roadId;
        }
        if (toRoadId == null && chunks.any((c) => c.id == toChunk.id)) {
          toRoadId = roadId;
        }
      });

      if (fromRoadId != null && fromRoadId == toRoadId) {
        final graph = _roadGraphsByRoadId[fromRoadId!];
        if (graph != null) {
          // Infer traversal direction by index ordering (best-effort)
          final direction = fromChunk.indexInRoad <= toChunk.indexInRoad
              ? RoadDirection.forward
              : RoadDirection.backward;

          final List<RoadChunk> path = [];
          final visited = <int>{};
          var currentId = fromChunk.id;
          // Safety cap to avoid infinite loops
          const maxSteps = 2000;
          var steps = 0;

          while (steps < maxSteps) {
            steps++;
            if (visited.contains(currentId)) break;
            visited.add(currentId);
            final chunkObj = _realChunks.cast<RoadChunk?>().firstWhere(
              (c) => c?.id == currentId,
              orElse: () => null,
            );
            if (chunkObj != null) path.add(chunkObj as RoadChunk);
            if (currentId == toChunk.id) break;

            final nextId = graph.nextChunkId(
              currentChunkId: currentId,
              direction: direction,
            );
            if (nextId == null) break;
            currentId = nextId;
          }

          if (path.isNotEmpty && path.last.id == toChunk.id) {
            return path;
          }
        }
      }
    } catch (_) {
      // Fall through to id-range fallback below
    }

    // Fallback: contiguous id-range based on global ordering
    final sorted = [..._realChunks]..sort((a, b) => a.id.compareTo(b.id));
    final path = <RoadChunk>[];
    final start = fromChunk.id;
    final end = toChunk.id;

    if (start < end) {
      for (final chunk in sorted) {
        if (chunk.id >= start && chunk.id <= end) path.add(chunk);
      }
    } else {
      for (final chunk in sorted.reversed) {
        if (chunk.id <= start && chunk.id >= end) path.add(chunk);
      }
    }

    return path.isEmpty ? [fromChunk] : path;
  }

  String get _routeRelevanceLabel {
    if (_waitingPinChunk == null || _etaPathChunks.isEmpty) {
      return 'Route relevance unavailable';
    }
    final from = _etaPathChunks.first.label;
    final to = _etaPathChunks.last.label;
    final count = _etaPathChunks.length;
    return 'Route relevance: $count chunk${count == 1 ? '' : 's'} from $from to $to';
  }

  double get _waitPredictionStabilityPercent {
    if (_waitPredictionStabilitySamples == 0) return 100;
    final avgDiff =
        _waitPredictionStabilityAccumulator / _waitPredictionStabilitySamples;
    return (100 - (avgDiff * 10)).clamp(0, 100).toDouble();
  }

  void _proceedToWaitingState() {
    if (_selectedJeepType == null ||
        _selectedDirection == null ||
        _waitingPinChunk?.realChunk == null ||
        _userLatLng == null) {
      _showSnack('Complete pin, direction, and jeep type first.');
      return;
    }

    final snap = RoadNetworkEngine.findUserSnapzoneChunk(
      _userLatLng!,
      _realChunks,
    );

    // If current snapzone detection fails, use the waiting pin chunk as fallback.
    // User has already proven they're in a valid location by successfully tapping the chunk.
    final userChunk = snap?.chunk ?? _waitingPinChunk!.realChunk!;

    final destinationChunk = _waitingPinChunk!.realChunk!;
    final pathChunks = _buildEtaPath(userChunk, destinationChunk);
    final eta = RoadNetworkEngine.predictEta(
      fromChunk: userChunk,
      toChunk: destinationChunk,
      pathChunks: pathChunks,
      jeepType: _selectedJeepType!,
      trafficSlowdownFactor: _trafficZones.isEmpty ? 1.0 : 1.2,
      direction: _selectedDirection!,
    );

    setState(() {
      _jeepFlowState = _JeepFlowState.waiting;
      _isWaiting = true;
      _waitStartAt = DateTime.now();
      _realEta = eta;
      _etaPathChunks = pathChunks;
      _waitInitialEtaSeconds = eta.etaSeconds;
      _waitCurrentEtaSeconds = eta.etaSeconds;
      _waitPredictionStabilityAccumulator = 0;
      _waitPredictionStabilitySamples = 0;
      _waitPreviousEtaSample = eta.etaSeconds;
      _waitPredictionGeneratedAt = DateTime.now();
      _waitEta = eta.etaSeconds;
    });
    _jeepSheetAnimCtrl.forward(from: 0);
  }

  void _cancelJeepFlow() {
    setState(() {
      _jeepFlowState = _JeepFlowState.idle;
      _selectedJeepType = null;
      _selectedDirection = null;
      _isWaiting = false;
      _waitingPinChunk = null;
      _waitingPinLatLng = null;
      _waitingPinForward = null;
      _waitStartAt = null;
      _waitEta = 0;
      _realEta = null;
      _etaPathChunks = [];
      _waitInitialEtaSeconds = 0;
      _waitCurrentEtaSeconds = 0;
      _waitPredictionStabilityAccumulator = 0;
      _waitPredictionStabilitySamples = 0;
      _waitPreviousEtaSample = null;
      _waitPredictionGeneratedAt = null;
    });
    _jeepSheetAnimCtrl.reverse();
  }

  void _onJeepArrivedInDev() {
    final waited = _waitStartAt == null
        ? 0
        : DateTime.now().difference(_waitStartAt!).inSeconds;
    setState(() {
      _jeepFlowState = _JeepFlowState.arrived;
      _isWaiting = false;
      _actualWaitSeconds = waited;
      _predictedArrival = _waitCurrentEtaSeconds;
      _initialPrediction = _waitInitialEtaSeconds;
      _accuracy = _waitInitialEtaSeconds <= 0
          ? 0
          : (100 -
                    (((waited - _waitInitialEtaSeconds).abs() /
                            _waitInitialEtaSeconds) *
                        100))
                .clamp(0, 100)
                .toDouble();
    });
    _jeepSheetAnimCtrl.forward(from: 0);
  }

  // Legacy method for compatibility
  Future<void> _openFindJeepFlowFromDev() async {
    _startFindJeepFlowInPlace();
  }

  Widget _buildJeepSheet() {
    final waitingSeconds = _waitStartAt == null
        ? 0
        : DateTime.now().difference(_waitStartAt!).inSeconds;

    switch (_jeepFlowState) {
      case _JeepFlowState.moving:
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF205A57), Color(0xFF1E7A76)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 24)],
          ),
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: _dragHandle()),
              const SizedBox(height: 14),
              const Text(
                'Find Jeep • Place Waiting Pin',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Tap a road chunk on the map. Pin will snap to nearest valid road segment.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _waitingPinChunk == null
                      ? 'Waiting pin: not placed yet'
                      : 'Waiting pin: ${_waitingPinChunk!.label}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _cancelJeepFlow,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.25),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      case _JeepFlowState.pickingJeepType:
        final directionLabel = _selectedDirection == null
            ? 'N/A'
            : _selectedDirection == RoadDirection.forward
            ? 'Forward'
            : 'Backward';
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 24)],
          ),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: _dragHandle()),
              const SizedBox(height: 18),
              const Text(
                'Type of Jeep',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F7F7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Pin: ${_waitingPinChunk?.label ?? 'N/A'}  •  Direction: $directionLabel',
                  style: const TextStyle(
                    color: Color(0xFF1E7A76),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2E9E99), Color(0xFF1E7A76)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedJeepType,
                    hint: const Text(
                      'Type of Jeep',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.white,
                    ),
                    dropdownColor: const Color(0xFF2E9E99),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                    onChanged: (v) {
                      if (v != null) _onJeepTypeSelected(v);
                    },
                    items: const ['All Types', 'Type A', 'Type B', 'Type C']
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _jeepFlowState = _JeepFlowState.moving);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4A7A72),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Back',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: _proceedToWaitingState,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E9E99),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Start Waiting',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      case _JeepFlowState.waiting:
        final confidence = _realEta?.confidencePercent ?? 0;
        final predictionSource = _realEta?.predictionSource ?? 'Unknown';
        final predictionMethod = _realEta?.predictionMethod ?? 'Unknown';
        final predictionAgeSeconds = _waitPredictionGeneratedAt == null
            ? 0
            : DateTime.now().difference(_waitPredictionGeneratedAt!).inSeconds;
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF37B09E), Color(0xFF1A6B62)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 24)],
          ),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dragHandle(),
              const SizedBox(height: 18),
              const Text(
                'WAITING SESSION',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${waitingSeconds}s',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 14),
              _analyticsCard([
                _metric(
                  'Initial ETA',
                  '${_waitInitialEtaSeconds.toStringAsFixed(1)}s',
                ),
                _metric(
                  'Current ETA',
                  '${_waitCurrentEtaSeconds.toStringAsFixed(1)}s',
                ),
                _metric(
                  'Stability',
                  '${_waitPredictionStabilityPercent.toStringAsFixed(0)}%',
                ),
                _metric('Source', predictionSource),
                _metric('Method', predictionMethod),
                _metric('Confidence', '${confidence.toStringAsFixed(0)}%'),
                _metric('Prediction Age', '${predictionAgeSeconds}s'),
                _metric('Route/Chunk', _routeRelevanceLabel),
              ]),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _cancelJeepFlow,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.35),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: _onJeepArrivedInDev,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E9E99),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Jeep Arrived',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      case _JeepFlowState.arrived:
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF37B09E), Color(0xFF1A6B62)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 24)],
          ),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dragHandle(),
              const SizedBox(height: 18),
              const Text(
                'JEEP ARRIVED!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Predicted: ${_predictedArrival.toStringAsFixed(1)}s • Actual: ${_actualWaitSeconds}s',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                'Accuracy: ${_accuracy.toStringAsFixed(0)}% • Initial prediction: ${_initialPrediction.toStringAsFixed(1)}s',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: GestureDetector(
                  onTap: _cancelJeepFlow,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E9E99),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'Close',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

      case _JeepFlowState.idle:
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _analyticsCard(List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BOTTOM DEV PANEL WIDGET
// ═══════════════════════════════════════════════════════════════════════════

class _BottomDevPanel extends StatelessWidget {
  final int panelTab;
  final bool expanded;
  final List<SakayRoad> roads;
  final List<SakayRoute> routes;
  final List<JeepType> jeepTypes;
  final List<ChunkConnection> chunkConnections;
  final _DevMode devMode;
  final List<LatLng> draftPoints;
  final List<_MockJeep> mockJeeps;
  final List<_TrafficZone> trafficZones;
  final List<_ChunkData> allChunks;
  final List<_ChunkData> routeChunks;

  // Road tab
  final VoidCallback onStartDrawRoad;
  final VoidCallback? onUndoPoint;
  final VoidCallback? onClearDraft;
  final VoidCallback? onSaveDraft;
  final VoidCallback? onCancelDraw;
  final Function(SakayRoad) onDeleteRoad;

  // Route tab
  final TextEditingController routeNameCtrl;
  final Color routeColor;
  final SakayRoad? routeTargetRoad;
  final Function(Color) onRouteColorChanged;
  final Function(SakayRoad) onRouteRoadSelected;
  final VoidCallback onSaveRoute;
  final Function(SakayRoute) onDeleteRoute;

  // Jeep Type tab
  final Function(JeepType) onSaveJeepType;
  final Function(JeepType) onDeleteJeepType;

  // Fork Editor tab
  final Function(ChunkConnection) onSaveForkConnection;
  final Function(ChunkConnection) onDeleteForkConnection;

  // Simulation tab
  final String mockJeepType;
  final Function(String) onMockJeepTypeChanged;
  final VoidCallback onPlaceMockJeep;
  final VoidCallback onPlaceTraffic;
  final VoidCallback onClearTraffic;
  final VoidCallback onClearMockJeeps;
  final VoidCallback onFindJeep;
  final VoidCallback? onCancelWait;
  final bool isWaiting;
  // User controls
  final VoidCallback onTeleportUser;
  final VoidCallback? onResumeGps;
  final bool isOfflineMode;
  final bool isTeleporting;

  // Navigation
  final Function(int) onTabChanged;
  final VoidCallback onToggleExpand;

  const _BottomDevPanel({
    required this.panelTab,
    required this.expanded,
    required this.roads,
    required this.routes,
    required this.jeepTypes,
    required this.chunkConnections,
    required this.devMode,
    required this.draftPoints,
    required this.mockJeeps,
    required this.trafficZones,
    required this.allChunks,
    required this.routeChunks,
    required this.onStartDrawRoad,
    required this.onUndoPoint,
    required this.onClearDraft,
    required this.onSaveDraft,
    required this.onCancelDraw,
    required this.onDeleteRoad,
    required this.routeNameCtrl,
    required this.routeColor,
    required this.routeTargetRoad,
    required this.onRouteColorChanged,
    required this.onRouteRoadSelected,
    required this.onSaveRoute,
    required this.onDeleteRoute,
    required this.onSaveJeepType,
    required this.onDeleteJeepType,
    required this.onSaveForkConnection,
    required this.onDeleteForkConnection,
    required this.mockJeepType,
    required this.onMockJeepTypeChanged,
    required this.onPlaceMockJeep,
    required this.onPlaceTraffic,
    required this.onClearTraffic,
    required this.onClearMockJeeps,
    required this.onFindJeep,
    required this.onCancelWait,
    required this.isWaiting,
    required this.onTeleportUser,
    required this.onResumeGps,
    required this.isOfflineMode,
    required this.isTeleporting,
    required this.onTabChanged,
    required this.onToggleExpand,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E7A76),
        boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 12)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── TAB BAR ────────────────────────────────────────────────
            GestureDetector(
              onTap: onToggleExpand,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _Tab('Roads', 0, panelTab, onTabChanged),
                            _Tab('Routes', 1, panelTab, onTabChanged),
                            _Tab('Simulation', 2, panelTab, onTabChanged),
                            _Tab('Jeep Types', 3, panelTab, onTabChanged),
                            _Tab('Forks', 4, panelTab, onTabChanged),
                          ],
                        ),
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_up,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),

            // ── PANEL CONTENT ──────────────────────────────────────────
            if (expanded)
              Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFF164E4A),
                  border: Border(top: BorderSide(color: Colors.white12)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: panelTab == 0
                      ? _RoadTab(
                          roads: roads,
                          devMode: devMode,
                          draftCount: draftPoints.length,
                          onStartDraw: onStartDrawRoad,
                          onUndo: onUndoPoint,
                          onClear: onClearDraft,
                          onSave: onSaveDraft,
                          onCancel: onCancelDraw,
                          onDelete: onDeleteRoad,
                        )
                      : panelTab == 1
                      ? _RouteTab(
                          roads: roads,
                          routes: routes,
                          allChunks: allChunks,
                          nameCtrl: routeNameCtrl,
                          selectedColor: routeColor,
                          targetRoad: routeTargetRoad,
                          onColorChanged: onRouteColorChanged,
                          onRoadSelected: onRouteRoadSelected,
                          onSave: onSaveRoute,
                          onDelete: onDeleteRoute,
                          onChunksSelected: (chunks) {},
                          selectedChunks: routeChunks,
                        )
                      : panelTab == 2
                      ? _SimTab(
                          mockJeeps: mockJeeps,
                          trafficZones: trafficZones,
                          allChunks: allChunks,
                          jeepType: mockJeepType,
                          onJeepTypeChanged: onMockJeepTypeChanged,
                          onPlaceJeep: onPlaceMockJeep,
                          onPlaceTraffic: onPlaceTraffic,
                          onClearTraffic: onClearTraffic,
                          onClearJeeps: onClearMockJeeps,
                          onFindJeep: onFindJeep,
                          onCancelWait: onCancelWait,
                          isWaiting: isWaiting,
                          onTeleportUser: onTeleportUser,
                          onResumeGps: onResumeGps,
                          isOfflineMode: isOfflineMode,
                          isTeleporting: isTeleporting,
                        )
                      : panelTab == 3
                      ? _JeepTypeTab(
                          jeepTypes: jeepTypes,
                          routes: routes,
                          onSave: onSaveJeepType,
                          onDelete: onDeleteJeepType,
                        )
                      : _ForkEditorTab(
                          chunkConnections: chunkConnections,
                          allChunks: allChunks,
                          roads: roads,
                          onSave: onSaveForkConnection,
                          onDelete: onDeleteForkConnection,
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Tab widgets ────────────────────────────────────────────────────────────

class _Tab extends StatelessWidget {
  final String label;
  final int index;
  final int current;
  final Function(int) onTap;
  const _Tab(this.label, this.index, this.current, this.onTap);

  @override
  Widget build(BuildContext context) {
    final active = index == current;
    return GestureDetector(
      onTap: () => onTap(index),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? Colors.white : Colors.white.withOpacity(0.3),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? const Color(0xFF1E7A76) : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ── Road Tab ───────────────────────────────────────────────────────────────

class _RoadTab extends StatelessWidget {
  final List<SakayRoad> roads;
  final _DevMode devMode;
  final int draftCount;
  final VoidCallback onStartDraw;
  final VoidCallback? onUndo;
  final VoidCallback? onClear;
  final VoidCallback? onSave;
  final VoidCallback? onCancel;
  final Function(SakayRoad) onDelete;

  const _RoadTab({
    required this.roads,
    required this.devMode,
    required this.draftCount,
    required this.onStartDraw,
    required this.onUndo,
    required this.onClear,
    required this.onSave,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Draw controls
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Btn(
              label: devMode == _DevMode.drawRoad
                  ? '✏️ Drawing...'
                  : '+ Add Road',
              onTap: onStartDraw,
              active: devMode == _DevMode.drawRoad,
            ),
            if (devMode == _DevMode.drawRoad) ...[
              _Btn(label: 'Undo', onTap: onUndo, enabled: draftCount > 0),
              _Btn(label: 'Clear', onTap: onClear, enabled: draftCount > 0),
              _Btn(
                label: 'Save Road',
                onTap: onSave,
                enabled: draftCount >= 2,
                highlight: true,
              ),
              _Btn(label: 'Cancel', onTap: onCancel),
            ],
          ],
        ),
        if (draftCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '$draftCount points drawn',
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ),
        if (roads.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text(
              'No roads yet.\nTap "+ Add Road" then tap the map.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          )
        else ...[
          const SizedBox(height: 12),
          const Text(
            'Saved Roads',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          ...roads.map((r) => _RoadRow(road: r, onDelete: () => onDelete(r))),
        ],
      ],
    );
  }
}

class _RoadRow extends StatelessWidget {
  final SakayRoad road;
  final VoidCallback onDelete;
  const _RoadRow({required this.road, required this.onDelete});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 3,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1565C0),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onDelete,
            child: const Icon(
              Icons.delete_outline,
              color: Colors.white38,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Route Tab ──────────────────────────────────────────────────────────────

class _RouteTab extends StatefulWidget {
  final List<SakayRoad> roads;
  final List<SakayRoute> routes;
  final List<_ChunkData> allChunks;
  final TextEditingController nameCtrl;
  final Color selectedColor;
  final SakayRoad? targetRoad;
  final Function(Color) onColorChanged;
  final Function(SakayRoad) onRoadSelected;
  final VoidCallback onSave;
  final Function(SakayRoute) onDelete;
  final Function(List<_ChunkData>) onChunksSelected;
  final List<_ChunkData> selectedChunks;

  const _RouteTab({
    required this.roads,
    required this.routes,
    required this.allChunks,
    required this.nameCtrl,
    required this.selectedColor,
    required this.targetRoad,
    required this.onColorChanged,
    required this.onRoadSelected,
    required this.onSave,
    required this.onDelete,
    required this.onChunksSelected,
    required this.selectedChunks,
  });

  @override
  State<_RouteTab> createState() => _RouteTabState();
}

class _RouteTabState extends State<_RouteTab> {
  void _toggleChunkSelection(_ChunkData chunk) {
    setState(() {
      if (widget.selectedChunks.contains(chunk)) {
        widget.selectedChunks.remove(chunk);
      } else {
        widget.selectedChunks.add(chunk);
      }
    });
    widget.onChunksSelected(widget.selectedChunks);
  }

  void _clearSelectedChunks() {
    setState(() => widget.selectedChunks.clear());
    widget.onChunksSelected(widget.selectedChunks);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.allChunks.isEmpty) {
      return const Text(
        'No road chunks yet. Add roads and they will be divided into chunks.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.nameCtrl,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Route name (e.g. "Route A")',
            hintStyle: const TextStyle(color: Colors.white38),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF2E9E99), width: 2),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Color',
          style: TextStyle(color: Colors.white60, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: _routeColorPalette.map((c) {
            final sel = c == widget.selectedColor;
            return GestureDetector(
              onTap: () => widget.onColorChanged(c),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: sel ? Colors.white : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: sel
                    ? const Icon(Icons.check, color: Colors.white, size: 14)
                    : null,
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        const Text(
          'Select Chunks (Chunk-by-Chunk Route)',
          style: TextStyle(
            color: Colors.white60,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 200),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
          ),
          child: SingleChildScrollView(
            child: Column(
              children: widget.allChunks.map((chunk) {
                final isSelected = widget.selectedChunks.contains(chunk);
                return GestureDetector(
                  onTap: () => _toggleChunkSelection(chunk),
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF2E9E99).withOpacity(0.3)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF2E9E99)
                            : Colors.white.withOpacity(0.2),
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isSelected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: isSelected
                              ? const Color(0xFF2E9E99)
                              : Colors.white54,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            chunk.label,
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        if (isSelected)
                          Text(
                            'Step ${widget.selectedChunks.indexOf(chunk) + 1}',
                            style: const TextStyle(
                              color: Color(0xFF2E9E99),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        if (widget.selectedChunks.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Selected Route Path (${widget.selectedChunks.length} chunks)',
                  style: const TextStyle(
                    color: Colors.green,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.selectedChunks
                      .asMap()
                      .entries
                      .map((e) => '${e.key + 1}. ${e.value.label}')
                      .join(' → '),
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            if (widget.selectedChunks.isNotEmpty)
              Expanded(
                child: _Btn(
                  label: 'Clear',
                  onTap: _clearSelectedChunks,
                  enabled: true,
                ),
              ),
            if (widget.selectedChunks.isNotEmpty) const SizedBox(width: 6),
            Expanded(
              child: _Btn(
                label: 'Save Route',
                onTap:
                    widget.selectedChunks.isNotEmpty &&
                        widget.nameCtrl.text.isNotEmpty
                    ? widget.onSave
                    : null,
                highlight: true,
                enabled:
                    widget.selectedChunks.isNotEmpty &&
                    widget.nameCtrl.text.isNotEmpty,
              ),
            ),
          ],
        ),
        if (widget.routes.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Saved Routes',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          ...widget.routes.map(
            (r) => Container(
              margin: const EdgeInsets.only(bottom: 5),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: r.color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: r.color.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: r.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.jeepName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${r.points.length} chunks',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => widget.onDelete(r),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white38,
                      size: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Simulation Tab ─────────────────────────────────────────────────────────

class _SimTab extends StatelessWidget {
  final List<_MockJeep> mockJeeps;
  final List<_TrafficZone> trafficZones;
  final List<_ChunkData> allChunks;
  final String jeepType;
  final Function(String) onJeepTypeChanged;
  final VoidCallback onPlaceJeep;
  final VoidCallback onPlaceTraffic;
  final VoidCallback onClearTraffic;
  final VoidCallback onClearJeeps;
  final VoidCallback onFindJeep;
  final VoidCallback? onCancelWait;
  final bool isWaiting;
  final VoidCallback onTeleportUser;
  final VoidCallback? onResumeGps;
  final bool isOfflineMode;
  final bool isTeleporting;

  const _SimTab({
    required this.mockJeeps,
    required this.trafficZones,
    required this.allChunks,
    required this.jeepType,
    required this.onJeepTypeChanged,
    required this.onPlaceJeep,
    required this.onPlaceTraffic,
    required this.onClearTraffic,
    required this.onClearJeeps,
    required this.onFindJeep,
    required this.onCancelWait,
    required this.isWaiting,
    required this.onTeleportUser,
    required this.onResumeGps,
    required this.isOfflineMode,
    required this.isTeleporting,
  });

  @override
  Widget build(BuildContext context) {
    final activeChunks = allChunks.where((c) => c.flowRate > 0).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Stats overview
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _SimStat('Chunks', '${allChunks.length}'),
              _vLine(),
              _SimStat('Active', '$activeChunks'),
              _vLine(),
              _SimStat('Mock Jeeps', '${mockJeeps.length}'),
              _vLine(),
              _SimStat('Traffic', '${trafficZones.length}'),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Jeep type selector
        const Text(
          'Mock Jeep Type',
          style: TextStyle(color: Colors.white60, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Row(
          children: ['Jeep A', 'Jeep B', 'Jeep C']
              .map(
                (t) => GestureDetector(
                  onTap: () => onJeepTypeChanged(t),
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: jeepType == t
                          ? const Color(0xFF2E9E99)
                          : Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: jeepType == t
                            ? const Color(0xFF2E9E99)
                            : Colors.white.withOpacity(0.2),
                      ),
                    ),
                    child: Text(
                      t,
                      style: TextStyle(
                        color: jeepType == t ? Colors.white : Colors.white60,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 10),

        // ── User location section ────────────────────────────────
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.person_pin_circle,
                    color: Colors.white70,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isOfflineMode
                        ? '📡 Offline / Emulator mode'
                        : isTeleporting
                        ? '✋ Tap map to teleport user'
                        : '🎯 User location active',
                    style: TextStyle(
                      color: isOfflineMode
                          ? Colors.orangeAccent
                          : isTeleporting
                          ? Colors.yellowAccent
                          : Colors.greenAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _Btn(
                    label: isTeleporting ? '✋ Tap map...' : '🚀 Teleport User',
                    onTap: onTeleportUser,
                    active: isTeleporting,
                  ),
                  if (onResumeGps != null)
                    _Btn(label: '📡 Resume GPS', onTap: onResumeGps),
                ],
              ),
            ],
          ),
        ),

        // Action buttons
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Btn(label: '🧭 Find Jeep', onTap: onFindJeep),
            _Btn(label: '🚌 Place Mock Jeep', onTap: onPlaceJeep),
            _Btn(label: '🚧 Add Traffic Zone', onTap: onPlaceTraffic),

            if (isWaiting && onCancelWait != null)
              _Btn(label: 'Cancel Wait', onTap: onCancelWait, highlight: false),
            if (mockJeeps.isNotEmpty)
              _Btn(
                label: 'Clear Jeeps ${mockJeeps.length}',
                onTap: onClearJeeps,
              ),
            if (trafficZones.isNotEmpty)
              _Btn(
                label: 'Clear Traffic ${trafficZones.length}',
                onTap: onClearTraffic,
              ),
          ],
        ),

        if (allChunks.isEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'Add roads first to generate road chunks.\n'
            'Chunks appear as teal dashes on the map.\n'
            'Tap any chunk to see its statistics.',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ],
    );
  }

  static Widget _vLine() =>
      Container(height: 24, width: 1, color: Colors.white.withOpacity(0.15));
}

class _SimStat extends StatelessWidget {
  final String label, value;
  const _SimStat(this.label, this.value);
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9)),
      ],
    );
  }
}

// ── Jeep Type Tab ──────────────────────────────────────────────────────────

class _JeepTypeTab extends StatefulWidget {
  final List<JeepType> jeepTypes;
  final List<SakayRoute> routes;
  final Function(JeepType) onSave;
  final Function(JeepType) onDelete;

  const _JeepTypeTab({
    required this.jeepTypes,
    required this.routes,
    required this.onSave,
    required this.onDelete,
  });

  @override
  State<_JeepTypeTab> createState() => _JeepTypeTabState();
}

class _JeepTypeTabState extends State<_JeepTypeTab> {
  final _nameCtrl = TextEditingController();
  String? _selectedRouteId;
  Color _selectedColor = Colors.blue;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _createNewJeepType() {
    if (_nameCtrl.text.isEmpty || _selectedRouteId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
      return;
    }

    final newJeepType = JeepType(
      id: 'jeep_${DateTime.now().millisecondsSinceEpoch}',
      name: _nameCtrl.text,
      assignedRouteId: _selectedRouteId!,
      color: _selectedColor,
    );

    // Call the parent callback to save
    widget.onSave(newJeepType);
    _nameCtrl.clear();
    _selectedRouteId = null;
    setState(() => _selectedColor = Colors.blue);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Jeep Types',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        // Create new jeep type
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            hintText: 'Jeep Type Name',
            hintStyle: TextStyle(color: Colors.white54),
            filled: true,
            fillColor: Color(0xFF0D3D3B),
            border: OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white12),
            ),
          ),
          style: const TextStyle(color: Colors.white),
        ),
        const SizedBox(height: 8),
        // Route selector
        DropdownButton<String>(
          value: _selectedRouteId,
          onChanged: (value) => setState(() => _selectedRouteId = value),
          items: [
            const DropdownMenuItem(
              value: null,
              child: Text(
                'Select Route',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            ...widget.routes.map((route) {
              return DropdownMenuItem(
                value: route.id,
                child: Text(
                  route.jeepName,
                  style: const TextStyle(color: Colors.black),
                ),
              );
            }),
          ],
          style: const TextStyle(color: Colors.white),
          dropdownColor: const Color(0xFF0D3D3B),
        ),
        const SizedBox(height: 8),
        // Color selector (placeholder)
        Container(
          width: 60,
          height: 40,
          decoration: BoxDecoration(
            color: _selectedColor,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white12),
          ),
          child: Center(
            child: Text(
              'Color',
              style: TextStyle(
                color: _selectedColor.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
                fontSize: 10,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _createNewJeepType,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
          child: const Text('Create Jeep Type'),
        ),
        const SizedBox(height: 16),
        // List existing jeep types
        if (widget.jeepTypes.isNotEmpty) ...[
          const Text(
            'Existing Jeep Types',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 8),
          ...widget.jeepTypes.map((jt) {
            final route = widget.routes.firstWhere(
              (r) => r.id == jt.assignedRouteId,
              orElse: () => SakayRoute(
                id: 'unknown',
                jeepName: 'Unknown Route',
                color: Colors.grey,
                roadId: '',
                points: [],
              ),
            );
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: jt.color.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: jt.color),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: jt.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            jt.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            'Route: ${route.jeepName}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => widget.onDelete(jt),
                      child: Icon(
                        Icons.delete,
                        color: Colors.redAccent,
                        size: 16,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ] else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No jeep types yet',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

// ── Fork Editor Tab ────────────────────────────────────────────────────────

class _ForkEditorTab extends StatefulWidget {
  final List<ChunkConnection> chunkConnections;
  final List<_ChunkData> allChunks;
  final List<SakayRoad> roads;
  final Function(ChunkConnection) onSave;
  final Function(ChunkConnection) onDelete;

  const _ForkEditorTab({
    required this.chunkConnections,
    required this.allChunks,
    required this.roads,
    required this.onSave,
    required this.onDelete,
  });

  @override
  State<_ForkEditorTab> createState() => _ForkEditorTabState();
}

class _ForkEditorTabState extends State<_ForkEditorTab> {
  int? _selectedFromChunkId;
  int? _selectedToChunkId;

  String _chunkLabel(int id) {
    for (final chunk in widget.allChunks) {
      if (chunk.id == id) {
        return chunk.label;
      }
    }
    return 'Chunk ${id + 1}';
  }

  void _createConnection() {
    if (_selectedFromChunkId == null || _selectedToChunkId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select both chunks')),
      );
      return;
    }

    // Prevent self-connections
    if (_selectedFromChunkId == _selectedToChunkId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot connect chunk to itself')),
      );
      return;
    }

    final newConnection = ChunkConnection(
      id: 'conn_${DateTime.now().millisecondsSinceEpoch}',
      fromChunkId: _selectedFromChunkId!,
      toChunkId: _selectedToChunkId!,
      roadId: widget.roads.isNotEmpty ? widget.roads.first.id : 'road_1',
    );

    // Call the parent callback to save
    widget.onSave(newConnection);
    setState(() {
      _selectedFromChunkId = null;
      _selectedToChunkId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Road Forks/Splits',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Create road chunk connections for forks and intersections',
          style: TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 12),
        // From chunk selector
        DropdownButton<int>(
          value: _selectedFromChunkId,
          onChanged: (value) => setState(() => _selectedFromChunkId = value),
          items: [
            const DropdownMenuItem(
              value: null,
              child: Text(
                'Select FROM chunk',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            ...widget.allChunks.map((chunk) {
              return DropdownMenuItem(
                value: chunk.id,
                child: Text(
                  chunk.label,
                  style: const TextStyle(color: Colors.black),
                ),
              );
            }),
          ],
          style: const TextStyle(color: Colors.white),
          dropdownColor: const Color(0xFF0D3D3B),
        ),
        const SizedBox(height: 8),
        // To chunk selector
        DropdownButton<int>(
          value: _selectedToChunkId,
          onChanged: (value) => setState(() => _selectedToChunkId = value),
          items: [
            const DropdownMenuItem(
              value: null,
              child: Text(
                'Select TO chunk',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            ...widget.allChunks.map((chunk) {
              return DropdownMenuItem(
                value: chunk.id,
                child: Text(
                  chunk.label,
                  style: const TextStyle(color: Colors.black),
                ),
              );
            }),
          ],
          style: const TextStyle(color: Colors.white),
          dropdownColor: const Color(0xFF0D3D3B),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _createConnection,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
          child: const Text('Create Fork Connection'),
        ),
        const SizedBox(height: 16),
        // List existing connections
        if (widget.chunkConnections.isNotEmpty) ...[
          const Text(
            'Existing Connections',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 8),
          ...widget.chunkConnections.map((conn) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.blueAccent),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_chunkLabel(conn.fromChunkId)} → ${_chunkLabel(conn.toChunkId)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            'Road: ${conn.roadId}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onTap: () => widget.onDelete(conn),
                      child: Icon(
                        Icons.delete,
                        color: Colors.redAccent,
                        size: 16,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ] else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No fork connections yet',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

// ── Shared button ──────────────────────────────────────────────────────────

class _Btn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool highlight;
  final bool enabled;

  const _Btn({
    required this.label,
    required this.onTap,
    this.active = false,
    this.highlight = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final canTap = enabled && onTap != null;
    return GestureDetector(
      onTap: canTap ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: canTap ? 1.0 : 0.35,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? Colors.white
                : highlight
                ? const Color(0xFF2E9E99)
                : Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.25)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? const Color(0xFF1E7A76) : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Header chip ────────────────────────────────────────────────────────────

class _HeaderChip extends StatelessWidget {
  final String label;
  final String tooltip;
  const _HeaderChip(this.label, this.tooltip);
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ── Map toggle button ──────────────────────────────────────────────────────

class _MapToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _MapToggle({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 4),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: active ? const Color(0xFF1E7A76) : Colors.white,
              size: 16,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: active ? const Color(0xFF1E7A76) : Colors.white70,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
