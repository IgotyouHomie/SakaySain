import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' hide Cluster;

import 'models/cluster_info.dart';
import 'models/chunk_traversal_state.dart';
import 'models/eta_test_record.dart';
import 'models/ghost_jeep.dart';
import 'models/kalman_motion_state.dart';
import 'models/local_activity_entry.dart';
import 'models/moving_state.dart';
import 'models/nearest_road_point.dart';
import 'models/projection_result.dart';
import 'models/jeep_type.dart';
import 'models/road_chunk.dart';
import 'models/road_chunk_event.dart';
import 'models/road_direction.dart';
import 'models/road_graph.dart';
import 'models/tracked_eta.dart';
import 'models/traffic_zone.dart';
import 'models/user.dart';
import 'models/route_profile.dart';
import 'models/route_profile_system.dart';
import 'painters/simulation_painter.dart';
import 'widgets/map_legend.dart';
import 'map_route_editor_screen.dart';
import 'route_persistence_service.dart';
import '../screens/road_persistence_service.dart';

part 'simulation_screen_chunk_eta_part.dart';
part 'simulation_screen_interaction_part.dart';
part 'simulation_screen_geometry_part.dart';
part 'simulation_screen_verification_part.dart';

enum CommunityVoteTargetType { jeepSighting, routeAccuracy }

enum CommunityVoteRole { passenger, pedestrian }

enum CommunityVoteChoice { confirm, reject, accurate, inaccurate }

enum _LoadingPreset { light, normal, congested }

class CommunityVote {
  CommunityVote({
    required this.id,
    required this.voterUserId,
    required this.targetType,
    required this.targetId,
    required this.choice,
    required this.role,
    required this.weight,
    required this.createdAt,
    this.jeepType,
  });

  final String id;
  final int voterUserId;
  final CommunityVoteTargetType targetType;
  final String targetId;
  final CommunityVoteChoice choice;
  final CommunityVoteRole role;
  final double weight;
  final DateTime createdAt;
  final String? jeepType;
}

class TrustProfile {
  TrustProfile({
    required this.userId,
    this.score = 0.65,
    this.totalVotes = 0,
    this.correctVotes = 0,
  });

  final int userId;
  double score;
  int totalVotes;
  int correctVotes;

  double get reliabilityPercent => (score * 100).clamp(0, 100);
}

class VerificationSummary {
  VerificationSummary({
    required this.targetId,
    required this.confirmWeight,
    required this.rejectWeight,
    required this.totalVotes,
  });

  final String targetId;
  final double confirmWeight;
  final double rejectWeight;
  final int totalVotes;

  double get netScore => confirmWeight - rejectWeight;

  double get confidencePercent {
    final total = confirmWeight + rejectWeight;
    if (total <= 0) return 0;
    return ((confirmWeight / total) * 100).clamp(0, 100);
  }

  String get statusLabel {
    if (totalVotes == 0) return 'No votes';
    if (netScore >= 1.5) return 'Verified';
    if (netScore <= -1.5) return 'Disputed';
    return 'Pending';
  }
}

class SimulationScreen extends StatefulWidget {
  const SimulationScreen({super.key});

  @override
  State<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends State<SimulationScreen>
    with SingleTickerProviderStateMixin {
  static const int _phoneUserId = 1;
  static const double _frameDtSeconds = 1 / 60;
  static const double _canvasSize = 1400;
  static const double _roadSnapThreshold = 18;
  static const double _clusterDistanceThresholdPx = 40;
  static const double _clusterSpeedDiffThreshold = 12;
  static const double _clusterDirectionSimilarityThreshold = 0.9;
  static const double _selectionTapThreshold = 12;
  static const int _trailMaxPointsPassenger = 80;
  static const int _trailMaxPointsMock = 45;
  static const double _trailPointMinDistance = 2.0;

  static const double worldRadius = 1500;

  static const List<Offset> initialRoutePath = [
    Offset(-300, -300),
    Offset(-300, -120),
    Offset(-80, -120),
    Offset(-80, 100),
    Offset(180, 100),
  ];

  static const double _chunkLengthMeters = 50;
  static const int _maxChunkSamples = 30;
  static const int _maxPinArrivalSamples = 20;
  static const int _maxPassEventSamples = 40;

  static const double _ghostConfidenceStart = 1.0;
  static const double _ghostConfidenceDecayDefault = 0.12;
  static const double _ghostConfidenceDecayLoop = 0.05;
  static const double _ghostConfidenceDecayTerminal = 0.20;
  static const double _ghostConfidenceMin = 0.30;

  static const double _etaWeightRealTime = 0.5;
  static const double _etaWeightHistorical = 0.3;
  static const double _etaWeightTraffic = 0.2;
  static const double _defaultKalmanGain = 0.5;

  static const double _speedStep = 5;
  static const double _visibilityStep = 15;
  static const double _maxVisibilityRadius = 320;
  static const double _minVisibilityRadius = 45;
  static const double _defaultJeepSpeed = 45;
  static const Duration _minStopCooldown = Duration(seconds: 12);
  static const Duration _maxStopCooldown = Duration(seconds: 36);
  static const Duration _minPassengerSessionDuration = Duration(seconds: 15);
  static const Duration _falseJeepDetectionWindow = Duration(seconds: 30);
  static const double _autoPassengerSpeedThreshold = 20;
  static const Duration _manualRepositionCooldown = Duration(seconds: 5);
  static const Duration _waitPredictionSampleInterval = Duration(seconds: 3);
  static const Duration _minAutoDetectWaitTime = Duration(seconds: 3);
  static const double _minimumPredictionDistanceMeters = 80;
  static const int _upstreamScanMaxChunks = 5;
  static const double _upstreamScanMaxMeters = 800;

  late final TransformationController _transformationController;
  late final AnimationController _simulationTicker;
  late final List<User> _users;
  late final Map<int, MovingState> _movingStates;

  late List<Offset> _routePath;
  late List<List<Offset>> _roadNetwork;
  late List<RoadChunk> _routeChunks;
  late RoadGraph _roadGraph;
  late List<double> _routeCumulativeLengths;

  Timer? _trackResetTimer;

  int _frame = 0;
  double _zoom = 1;
  int _controlUserId = _phoneUserId;
  bool _isDeveloperMode = true;
  bool _isPlacingMockUser = false;

  bool _isRoadEditorMode = false;
  bool _isAddingRoadPoints = false;
  final List<Offset> _draftRoutePoints = <Offset>[];

  bool _showTrails = true;

  bool _isPlacingTrafficZone = false;
  bool _trafficEnabled = true; // ENABLED BY DEFAULT for realistic simulation
  bool _showFlowHeatOverlay = false;
  int _maxTrafficLines = 8; // Increased for more realistic traffic
  final List<TrafficZone> _trafficZones = [];
  DateTime?
  _lastTrafficGenerationTime; // Auto-generate traffic zones periodically

  bool _loadingEnabled = false;
  double _stopProbability = 0.1;
  _LoadingPreset _loadingPreset = _LoadingPreset.normal;
  int _minStopCooldownSeconds = 12;
  int _maxStopCooldownSeconds = 36;
  int _shortStopMinSeconds = 2;
  int _shortStopMaxSeconds = 5;
  int _longStopMinSeconds = 6;
  int _longStopMaxSeconds = 11;
  bool _kalmanEnabled = true;
  double _kalmanGain = _defaultKalmanGain;
  bool _randomGhostToggleEnabled = false;
  double _randomGhostToggleLikelihood = 0.12;
  List<JeepType> _availableJeepTypes = <JeepType>[];
  List<SakayRoute> _availableRoutes = <SakayRoute>[];
  final Map<String, SakayRoute> _availableRoutesById = <String, SakayRoute>{};
  final Map<int, DateTime> _pauseUntil = {};
  final Map<int, DateTime> _nextStopEligibleAt = {};
  final math.Random _random = math.Random(42);

  bool _trackScanActive = false;
  bool _isPlacingRoadWaiterPin = false;
  static const Duration _trackDuration = Duration(seconds: 6);
  Set<String> _selectedJeepTypes = {'Jeep A', 'Jeep B', 'Jeep C'};
  bool _devAutoStopWhenJeepReachesPin = true;
  bool _devAutoStopIncludeGhostJeeps = true;
  bool _devShowEtaPredictionData = true;
  bool _devShowChunkStats = true;

  bool _isWaitingForJeep = false;
  DateTime? _waitStartAt;
  double? _waitPredictedEtaSeconds;
  double _waitPredictedTrafficFactor = 1;
  bool _waitUsedGhostCandidate = false;
  bool _pendingFoundJeepVerification = false;
  DateTime? _pendingFoundJeepAt;
  double _pendingFoundJeepMaxSpeed = 0;
  bool _isPassengerUser = false;
  DateTime? _lastManualPhoneRepositionAt;
  Offset? _lastPhonePositionSample;
  DateTime? _lastPhonePositionSampleAt;
  double _latestPhoneInferredSpeed = 0;
  DateTime? _lastWaitPredictionSampleAt;
  final List<double> _waitPredictedEtaSamples = <double>[];
  double _waitPredictionStabilityAccumulator = 0;
  int _waitPredictionStabilitySamples = 0;
  double? _waitPreviousPredictionSample;
  String _waitPredictionSource = 'Unknown';
  String _waitPredictionMethod = 'Unknown';
  String _waitConfidenceLabel = 'LOW';
  double _waitPredictionDistanceMeters = 0;
  double _waitPredictionWindowMinSeconds = 0;
  double _waitPredictionWindowMaxSeconds = 0;
  DateTime? _waitPredictionGeneratedAt;
  EtaTestRecord? _latestEtaTestRecord;
  final List<EtaTestRecord> _etaTestRecords = <EtaTestRecord>[];
  final Map<int, double> _chunkAccuracyMeanByChunk = <int, double>{};
  final Map<int, int> _chunkAccuracySamplesByChunk = <int, int>{};

  NearestRoadPoint? _roadWaiterPin;
  RoadDirection? _selectedPinDirection;
  TrackedEta? _trackedEta;
  final List<RoadChunkEvent> _chunkEventQueue = <RoadChunkEvent>[];
  final Map<int, ChunkTraversalState> _chunkTraversalByUser = {};
  final Map<int, KalmanMotionState> _kalmanStateByUser = {};
  final Map<int, List<DateTime>> _pinArrivalLogsByChunk = {};
  final Map<int, GhostJeep> _ghostJeepsBySourceUser = {};
  DateTime? _lastTrackPressedAt;

  final List<CommunityVote> _communityVotes = <CommunityVote>[];
  final Map<int, TrustProfile> _trustProfilesByUser = <int, TrustProfile>{};
  final Map<int, double> _routeAccuracyScoreByChunk = <int, double>{};
  int? _selectedVerificationChunkId;

  bool _isLoadingSavedRoute = true;
  List<LatLng> _savedMapRoutePoints = <LatLng>[];
  String _routeDataSource = 'Default';

  // ==============================
  // 🚗 ROUTE PROFILE STORAGE (NEW)
  // ==============================
  final Map<String, JeepRouteProfile> _routeProfilesByJeepType = {};

  // ==============================
  // 🔍 GET ROUTE PER USER (NEW)
  // ==============================
  JeepRouteProfile? _getRouteForUser(User user) {
    return _routeProfilesByJeepType[user.jeepType];
  }

  @override
  void initState() {
    super.initState();

    _routePath = List<Offset>.from(initialRoutePath);
    _roadNetwork = <List<Offset>>[_routePath];
    _loadJeepCatalog();

    _users = [
      User(
        id: _phoneUserId,
        position: const Offset(-260, -220),
        speed: 0,
        direction: const Offset(0, 0),
        visibilityRadius: 160,
        jeepType: 'None',
        isPhoneUser: true,
        isMockUser: false,
      ),
      User(
        id: 2,
        position: const Offset(-120, -240),
        speed: 38,
        direction: const Offset(1, 0),
        visibilityRadius: 120,
        jeepType: 'Jeep A',
        isMockUser: true,
      ),
      User(
        id: 3,
        position: const Offset(80, -40),
        speed: 50,
        direction: const Offset(1, 0),
        visibilityRadius: 130,
        jeepType: 'Jeep B',
        isMockUser: true,
      ),
      User(
        id: 4,
        position: const Offset(280, 160),
        speed: 34,
        direction: const Offset(0, 1),
        visibilityRadius: 110,
        jeepType: 'Jeep C',
        isMockUser: true,
      ),
      User(
        id: 5,
        position: const Offset(-40, 260),
        speed: 0,
        direction: const Offset(0, 0),
        visibilityRadius: 90,
        jeepType: 'Jeep A',
        isMockUser: true,
      ),
    ];

    for (final user in _users) {
      _trustProfilesByUser[user.id] = TrustProfile(userId: user.id);
    }

    _movingStates = <int, MovingState>{};
    _routeCumulativeLengths = _buildRouteCumulativeLengths(_routePath);
    _routeChunks = _buildRoadChunksFromPath(_routePath);
    _roadGraph = RoadGraph.fromRouteChunks(
      chunks: _routeChunks,
      isLoop: _isPathLoop(_routePath),
    );

    for (final user in _users.where((u) => u.isMoving && !u.isPhoneUser)) {
      _snapUserToRoadAndInitState(user);
      _recordTrailPoint(user, user.position);
      _initializeChunkTraversalFor(user);
      _initializeKalmanStateFor(user, DateTime.now());
    }

    _lastPhonePositionSample = _phoneUser.position;
    _lastPhonePositionSampleAt = DateTime.now();

    _transformationController = TransformationController(Matrix4.identity())
      ..addListener(_onTransformChanged);

    _simulationTicker = AnimationController.unbounded(vsync: this)
      ..addListener(_advanceSimulation)
      ..repeat(min: 0, max: 1, period: const Duration(milliseconds: 16));

    Future<void> _loadJeepCatalog() async {
      final jeepTypes = await RoadPersistenceService.loadJeepTypes();
      final routes = await RoadPersistenceService.loadRoutes();

      if (!mounted) return;

      final routesById = <String, SakayRoute>{};
      for (final route in routes) {
        routesById[route.id] = route;
      }

      final routeProfilesByJeepType = <String, JeepRouteProfile>{};
      for (final jeepType in jeepTypes) {
        final route = routesById[jeepType.assignedRouteId];
        if (route == null || route.points.length < 2) continue;
        routeProfilesByJeepType[jeepType.name] = JeepRouteProfile(
          id: route.id,
          name: route.jeepName,
          jeepType: jeepType.name,
          worldPath: _convertLatLngRouteToWorldOffsets(route.points),
        );
      }

      setState(() {
        _availableJeepTypes = jeepTypes;
        _availableRoutes = routes;
        _availableRoutesById
          ..clear()
          ..addAll(routesById);
        _routeProfilesByJeepType
          ..clear()
          ..addAll(routeProfilesByJeepType);
      });
    }

    _loadPersistedRoutes();
  }

  @override
  void dispose() {
    _trackResetTimer?.cancel();

    _simulationTicker
      ..removeListener(_advanceSimulation)
      ..dispose();

    _transformationController
      ..removeListener(_onTransformChanged)
      ..dispose();

    super.dispose();
  }

  void _applyState(VoidCallback updater) {
    if (!mounted) return;
    setState(updater);
  }

  void _rebuildRoadSystemFromPath(List<Offset> path) {
    if (path.length < 2) {
      return;
    }

    _routePath = List<Offset>.from(path);
    _roadNetwork = <List<Offset>>[_routePath];
    _routeCumulativeLengths = _buildRouteCumulativeLengths(_routePath);
    _routeChunks = _buildRoadChunksFromPath(_routePath);
    _roadGraph = RoadGraph.fromRouteChunks(
      chunks: _routeChunks,
      isLoop: _isPathLoop(_routePath),
    );

    _chunkEventQueue.clear();
    _chunkTraversalByUser.clear();
    _kalmanStateByUser.clear();
    _ghostJeepsBySourceUser.clear();
    _pinArrivalLogsByChunk.clear();

    for (final user in _users.where((u) => !u.isPhoneUser && u.isMoving)) {
      _snapUserToRoadAndInitState(user);
      _recordTrailPoint(user, user.position);
      _initializeChunkTraversalFor(user);
      _initializeKalmanStateFor(user, DateTime.now());
    }

    _roadWaiterPin = null;
    _selectedPinDirection = null;
    _trackedEta = null;
    _cancelRoadWaitMeasurementState();
  }

  void _startRoadEditor() {
    setState(() {
      _isRoadEditorMode = true;
      _isAddingRoadPoints = true;
      _draftRoutePoints.clear();
      _isPlacingMockUser = false;
      _isPlacingTrafficZone = false;
      _isPlacingRoadWaiterPin = false;
    });
  }

  void _clearDraftRoad() {
    setState(() {
      _draftRoutePoints.clear();
    });
  }

  void _cancelRoadEditor() {
    setState(() {
      _isRoadEditorMode = false;
      _isAddingRoadPoints = false;
      _draftRoutePoints.clear();
    });
  }

  Future<String?> _askJeepTypeDialog() async {
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Select Jeep Type for this Route"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text("Jeep A"),
                onTap: () => Navigator.pop(context, "Jeep A"),
              ),
              ListTile(
                title: const Text("Jeep B"),
                onTap: () => Navigator.pop(context, "Jeep B"),
              ),
              ListTile(
                title: const Text("Jeep C"),
                onTap: () => Navigator.pop(context, "Jeep C"),
              ),
            ],
          ),
        );
      },
    );
  }

  void _saveDraftRoad() async {
    if (_draftRoutePoints.length < 2) return;

    final jeepType = await _askJeepTypeDialog();
    if (jeepType == null) return;

    final profile = JeepRouteProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: jeepType,
      jeepType: jeepType,
      worldPath: List<Offset>.from(_draftRoutePoints),
    );

    setState(() {
      _routeProfilesByJeepType[jeepType] = profile;

      // keep existing behavior (DO NOT REMOVE)
      _rebuildRoadSystemFromPath(_draftRoutePoints);

      _draftRoutePoints.clear();
      _isRoadEditorMode = false;
      _isAddingRoadPoints = false;

      _routeDataSource = 'Route for $jeepType';
    });

    await _persistWorldRoute(profile.worldPath);
  }

  void _showSaveProfileDialog(List<Offset> path) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text("Save Route Profile"),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: "Enter route name (e.g. Legazpi Route 1)",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) return;

                final profile = RouteProfile(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: name,
                  worldPoints: path,
                  mapPoints: _savedMapRoutePoints,
                );

                await RoutePersistenceService.saveRouteProfile(profile);

                if (!mounted) return;

                setState(() {
                  _rebuildRoadSystemFromPath(path);
                  _draftRoutePoints.clear();
                  _isRoadEditorMode = false;
                  _isAddingRoadPoints = false;
                  _routeDataSource = name;
                });

                Navigator.pop(context);
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  void _openRouteProfiles() async {
    final profiles = await RoutePersistenceService.loadProfiles();

    showModalBottomSheet(
      context: context,
      builder: (_) {
        return ListView(
          children: profiles.map((p) {
            return ListTile(
              title: Text(p.name),
              onTap: () {
                Navigator.pop(context);

                setState(() {
                  _savedMapRoutePoints = p.mapPoints;
                  _routeDataSource = p.name;
                  _rebuildRoadSystemFromPath(p.worldPoints);
                });
              },
            );
          }).toList(),
        );
      },
    );
  }

  List<LocalActivityEntry> _buildLocalActivityEntries() {
    final entries = _routeChunks.map((chunk) {
      final jeepTypes = <String>{
        ...chunk.jeepTypePassEvents.keys,
        ...chunk.speculativeJeepTypePassEvents.keys,
      };

      return LocalActivityEntry(
        chunkId: chunk.id,
        label: chunk.forwardDirectionLabel.replaceAll(' -> ', '-'),
        flowRate: chunk.flowRateJeepsPerMinute,
        lastActivity: chunk.lastJeepPassTime,
        jeepTypes: jeepTypes,
        observedPassCount: chunk.observedPassCount,
        speculativePassCount: chunk.speculativePassCount,
        avgArrivalInterval: chunk.avgArrivalIntervalAll,
        avgTravelTime: chunk.avgTravelTimeAll,
        accuracyPercent: _chunkAccuracyMeanByChunk[chunk.id] ?? 0,
      );
    }).toList();

    entries.sort((a, b) => b.flowRate.compareTo(a.flowRate));
    return entries;
  }

  void _openLocalActivityInsights() {
    final entries = _buildLocalActivityEntries();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Local Activity Insights',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text('Total Chunks: ${entries.length}'),
                Text(
                  'Active Chunks: ${entries.where((e) => e.flowRate > 0).length}',
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: entries.isEmpty
                      ? const Text('No local activity data yet.')
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final e = entries[index];
                            final jeepTypesText = e.jeepTypes.isEmpty
                                ? 'None'
                                : e.jeepTypes.join(', ');
                            final lastSeen = e.lastActivity == null
                                ? 'N/A'
                                : '${e.lastActivity!.hour.toString().padLeft(2, '0')}:${e.lastActivity!.minute.toString().padLeft(2, '0')}:${e.lastActivity!.second.toString().padLeft(2, '0')}';

                            return Card(
                              child: ListTile(
                                title: Text('Chunk ${e.label}'),
                                subtitle: Text(
                                  'Flow: ${e.flowRate.toStringAsFixed(2)} j/min\n'
                                  'Last Activity: $lastSeen\n'
                                  'Jeep Types: $jeepTypesText\n'
                                  'Observed: ${e.observedPassCount} | Speculative: ${e.speculativePassCount}\n'
                                  'Avg Arrival: ${e.avgArrivalInterval.toStringAsFixed(1)}s | Avg Travel: ${e.avgTravelTime.toStringAsFixed(1)}s\n'
                                  'Accuracy: ${e.accuracyPercent.toStringAsFixed(1)}%',
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadPersistedRoutes() async {
    final savedMapRoute = await RoutePersistenceService.loadMapRoute();
    final savedWorldRoute = await RoutePersistenceService.loadWorldRoute();

    if (!mounted) return;

    if (savedMapRoute.length >= 2) {
      final worldPath = _convertLatLngRouteToWorldOffsets(savedMapRoute);
      setState(() {
        _savedMapRoutePoints = savedMapRoute;
        _routeDataSource = 'Google Map Route';
        _rebuildRoadSystemFromPath(worldPath);
        _isLoadingSavedRoute = false;
      });
      return;
    }

    if (savedWorldRoute.length >= 2) {
      setState(() {
        _routeDataSource = 'Saved Local Route';
        _rebuildRoadSystemFromPath(savedWorldRoute);
        _isLoadingSavedRoute = false;
      });
      return;
    }

    setState(() {
      _isLoadingSavedRoute = false;
    });
  }

  List<Offset> _convertLatLngRouteToWorldOffsets(List<LatLng> points) {
    if (points.isEmpty) return <Offset>[];
    final anchor = points.first;
    const metersPerDegreeLat = 111320.0;
    final cosLat = math.cos(anchor.latitude * math.pi / 180.0);
    final metersPerDegreeLng = metersPerDegreeLat * cosLat;

    return points.map((point) {
      final dx = (point.longitude - anchor.longitude) * metersPerDegreeLng;
      final dy = -((point.latitude - anchor.latitude) * metersPerDegreeLat);
      return Offset(dx, dy);
    }).toList();
  }

  Future<void> _persistWorldRoute(List<Offset> points) async {
    await RoutePersistenceService.saveWorldRoute(points);
  }

  Future<void> _openMapRouteEditor() async {
    final initialPoints = _savedMapRoutePoints;
    final result = await Navigator.of(context).push<List<LatLng>>(
      MaterialPageRoute(
        builder: (_) => MapRouteEditorScreen(initialPoints: initialPoints),
      ),
    );

    if (result == null) return;

    if (result.length < 2) {
      await RoutePersistenceService.clearAllRoutes();
      if (!mounted) return;
      setState(() {
        _savedMapRoutePoints = <LatLng>[];
        _routeDataSource = 'Default';
        _rebuildRoadSystemFromPath(List<Offset>.from(initialRoutePath));
      });
      return;
    }

    final worldPath = _convertLatLngRouteToWorldOffsets(result);
    await RoutePersistenceService.saveMapRoute(result);
    await RoutePersistenceService.saveWorldRoute(worldPath);

    if (!mounted) return;
    setState(() {
      _savedMapRoutePoints = result;
      _routeDataSource = 'Google Map Route';
      _rebuildRoadSystemFromPath(worldPath);
      _frame++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final phoneUser = _phoneUser;
    final visibilityByUser = _buildVisibilityByUser(_users);
    final baseVisibleToPhone = visibilityByUser[_phoneUserId] ?? <int>{};
    final effectiveVisibleToPhone = _buildTrackVisibleIds(baseVisibleToPhone);
    final clusterInfos = _buildVisibleMovingClusters(effectiveVisibleToPhone);
    final topFlowChunkBadgesList =
        _routeChunks.where((chunk) => chunk.flowRateJeepsPerMinute > 0).toList()
          ..sort(
            (a, b) =>
                b.flowRateJeepsPerMinute.compareTo(a.flowRateJeepsPerMinute),
          );
    final top3FlowChunkBadges = topFlowChunkBadgesList.take(3).map((chunk) {
      final center = Offset(
        (chunk.startPoint.dx + chunk.endPoint.dx) / 2,
        (chunk.startPoint.dy + chunk.endPoint.dy) / 2,
      );
      return (
        position: center,
        label: chunk.forwardDirectionLabel.replaceAll(' -> ', '-'),
        flowRate: chunk.flowRateJeepsPerMinute,
      );
    }).toList();
    final controlUser = _controlUser;
    final rollingSummary = _buildRollingAccuracySummary();
    final mediaHeight = MediaQuery.of(context).size.height;
    final topPanelMaxHeight =
        (_isDeveloperMode ? mediaHeight * 0.38 : mediaHeight * 0.20)
            .clamp(120.0, 300.0)
            .toDouble();

    _trackedEta = _computeNearestIncomingEta(
      roadWaiterPin: _roadWaiterPin,
      selectedDirection: _selectedPinDirection,
      candidateUserIds: _trackScanActive
          ? _users.where((u) => !u.isPhoneUser).map((u) => u.id).toSet()
          : effectiveVisibleToPhone,
    );

    // ── SakaySain-styled Simulation Lab scaffold ──────────────────────────
    // All engine logic above this line is untouched.
    // Only the visual presentation changes here.

    return Scaffold(
      backgroundColor: const Color(0xFF0E3530),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── TOP BAR ──────────────────────────────────────────────────
            Container(
              color: const Color(0xFF1E7A76),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Simulation Lab',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  // Quick stats
                  _LabChip(
                    label:
                        'J:${_users.where((u) => !u.isPhoneUser && u.isMoving).length}',
                    tooltip: 'Active jeeps',
                  ),
                  const SizedBox(width: 6),
                  _LabChip(
                    label: 'G:${_ghostJeepsBySourceUser.length}',
                    tooltip: 'Ghost jeeps',
                  ),
                  const SizedBox(width: 6),
                  _LabChip(
                    label: 'C:${_routeChunks.length}',
                    tooltip: 'Road chunks',
                  ),
                ],
              ),
            ),

            // ── STATUS STRIP ──────────────────────────────────────────
            if (_devShowEtaPredictionData || _isWaitingForJeep)
              Container(
                color: const Color(0xFF164E4A),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (_isWaitingForJeep) ...[
                        _StatusPill(
                          icon: Icons.timer,
                          text:
                              'Wait: ${_waitElapsedSeconds().toStringAsFixed(1)}s',
                          color: Colors.orangeAccent,
                        ),
                        const SizedBox(width: 6),
                        _StatusPill(
                          icon: Icons.show_chart,
                          text:
                              'Pred: ${(_waitPredictedEtaSeconds ?? 0).toStringAsFixed(1)}s',
                          color: Colors.greenAccent,
                        ),
                        const SizedBox(width: 6),
                        _StatusPill(
                          icon: Icons.speed,
                          text:
                              'Spd: ${_latestPhoneInferredSpeed.toStringAsFixed(1)}m/s',
                          color: Colors.lightBlueAccent,
                        ),
                      ] else if (_trackedEta != null) ...[
                        _StatusPill(
                          icon: Icons.directions_bus,
                          text:
                              'ETA: ${_trackedEta!.etaSeconds.toStringAsFixed(1)}s',
                          color: Colors.greenAccent,
                        ),
                        const SizedBox(width: 6),
                        _StatusPill(
                          icon: Icons.verified,
                          text:
                              '${_trackedEta!.confidenceLabel} ${_trackedEta!.confidencePercent.toStringAsFixed(0)}%',
                          color: Colors.yellowAccent,
                        ),
                        const SizedBox(width: 6),
                        _StatusPill(
                          icon: Icons.social_distance,
                          text:
                              '${_trackedEta!.distanceMeters.toStringAsFixed(0)}m',
                          color: Colors.lightBlueAccent,
                        ),
                      ] else ...[
                        _StatusPill(
                          icon: Icons.info_outline,
                          text: _roadWaiterPin == null
                              ? 'Press Track to place waiting pin'
                              : _selectedPinDirection == null
                              ? 'Choose jeep direction'
                              : 'Scanning for jeeps...',
                          color: Colors.white60,
                        ),
                      ],
                      if (_etaTestRecords.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _StatusPill(
                          icon: Icons.analytics_outlined,
                          text:
                              'Tests: ${rollingSummary.totalTests} | Acc: ${rollingSummary.averageAccuracyPercent.toStringAsFixed(1)}%',
                          color: Colors.purpleAccent,
                        ),
                      ],
                    ],
                  ),
                ),
              ),

            // ── CANVAS (the simulation) ───────────────────────────────
            Expanded(
              child: Stack(
                children: [
                  // The actual simulation canvas
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _handleMapTap,
                    child: InteractiveViewer(
                      transformationController: _transformationController,
                      minScale: 0.5,
                      maxScale: 4,
                      constrained: false,
                      boundaryMargin: const EdgeInsets.all(500),
                      child: SizedBox(
                        width: _canvasSize,
                        height: _canvasSize,
                        child: CustomPaint(
                          painter: SimulationPainter(
                            worldRadius: worldRadius,
                            roads: [
                              ..._roadNetwork,
                              if (_draftRoutePoints.length >= 2)
                                _draftRoutePoints,
                            ],
                            roadChunks: _routeChunks
                                .map(
                                  (chunk) => (
                                    start: chunk.startPoint,
                                    end: chunk.endPoint,
                                    flowRate: chunk.flowRateJeepsPerMinute,
                                  ),
                                )
                                .toList(),
                            maxChunkFlowRate: _routeChunks.isEmpty
                                ? 1
                                : _routeChunks
                                      .map((c) => c.flowRateJeepsPerMinute)
                                      .reduce(math.max),
                            users: _users,
                            trafficZones: _trafficZones
                                .map(
                                  (zone) => (start: zone.start, end: zone.end),
                                )
                                .toList(),
                            viewportScale: _zoom,
                            frame: _frame,
                            phoneUserId: _phoneUserId,
                            selectedUserId: _controlUserId,
                            visibleToPhoneIds: effectiveVisibleToPhone,
                            phoneVisibilityRadius: phoneUser.visibilityRadius,
                            showRoadSnapZone:
                                _isDeveloperMode && _isPlacingMockUser,
                            roadSnapThreshold: _roadSnapThreshold,
                            showClusterDebugRadii: _isDeveloperMode,
                            clusterDistanceThresholdPx:
                                _clusterDistanceThresholdPx,
                            clusters: clusterInfos,
                            showTrails: _showTrails,
                            roadWaiterPin: _roadWaiterPin?.point,
                            roadWaiterDirectionIsForward:
                                _selectedPinDirection == null
                                ? null
                                : _selectedPinDirection ==
                                      RoadDirection.forward,
                            highlightedJeepId: _trackedEta?.userId,
                            pausedUserIds: _pauseUntil.entries
                                .where((e) => e.value.isAfter(DateTime.now()))
                                .map((e) => e.key)
                                .toSet(),
                            ghostMarkers: _ghostJeepsBySourceUser.values
                                .map(
                                  (ghost) => (
                                    sourceUserId: ghost.sourceUserId,
                                    position: ghost.position,
                                    jeepType: ghost.jeepType,
                                    confidence: ghost.confidence,
                                  ),
                                )
                                .toList(),
                            topFlowChunkBadges: top3FlowChunkBadges,
                            showFlowHeatOverlay: _showFlowHeatOverlay,
                            showRoadChunkDirections:
                                _isDeveloperMode && _devShowChunkStats,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Legend (bottom-right)
                  const Positioned(right: 12, bottom: 80, child: _SimLegend()),

                  // Mode badge (top-left overlay)
                  if (_isRoadEditorMode ||
                      _isPlacingMockUser ||
                      _isPlacingTrafficZone ||
                      _isPlacingRoadWaiterPin)
                    Positioned(
                      top: 10,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xDD2E9E99),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _isPlacingRoadWaiterPin
                              ? '📍 Tap road to place waiting pin'
                              : _isRoadEditorMode
                              ? '✏️ Tap to add road points'
                              : _isPlacingMockUser
                              ? '👤 Tap to place mock jeep'
                              : '🚦 Traffic zones refresh automatically',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                  // Snapzone toggle (top-right of canvas)
                  Positioned(
                    top: 10,
                    right: 12,
                    child: _CanvasToggleBtn(
                      icon: _showFlowHeatOverlay
                          ? Icons.layers
                          : Icons.layers_outlined,
                      label: 'Heat',
                      active: _showFlowHeatOverlay,
                      onTap: () => setState(
                        () => _showFlowHeatOverlay = !_showFlowHeatOverlay,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── BOTTOM DEV PANEL ──────────────────────────────────────
            _SimDevPanel(
              // Primary actions
              isWaiting: _isWaitingForJeep,
              isPlacingPin: _isPlacingRoadWaiterPin,
              onTrack: _onTrackPressed,
              onFoundJeep: _isWaitingForJeep ? _onFoundJeepPressed : null,
              onFilterJeeps: _openJeepTypeSelectionPanel,
              // Dev tools
              isDeveloperMode: _isDeveloperMode,
              onToggleDeveloperMode: _toggleDeveloperMode,
              isRoadEditorMode: _isRoadEditorMode,
              hasDraftPoints: _draftRoutePoints.isNotEmpty,
              canSaveDraft: _draftRoutePoints.length >= 2,
              onStartRoadEditor: _startRoadEditor,
              onClearDraft: _draftRoutePoints.isNotEmpty
                  ? _clearDraftRoad
                  : null,
              onSaveDraft: _draftRoutePoints.length >= 2
                  ? _saveDraftRoad
                  : null,
              onCancelRoadEditor: _isRoadEditorMode ? _cancelRoadEditor : null,
              onLocalInsights: _openLocalActivityInsights,
              onMapRouteEditor: _openMapRouteEditor,
              onRouteProfiles: _openRouteProfiles,
              isPlacingMockUser: _isPlacingMockUser,
              onToggleMockUser: () =>
                  setState(() => _isPlacingMockUser = !_isPlacingMockUser),
              isPlacingTraffic: _trafficEnabled && _trafficZones.isNotEmpty,
              onToggleTraffic: _randomizeTrafficZones,
              onRandomizeTraffic: _randomizeTrafficZones,
              // Toggles
              trafficEnabled: _trafficEnabled,
              onTrafficEnabled: (v) => setState(() => _trafficEnabled = v),
              loadingEnabled: _loadingEnabled,
              onLoadingEnabled: (v) => setState(() => _loadingEnabled = v),
              loadingPreset: _loadingPreset,
              onLoadingPresetChanged: _setLoadingPreset,
              showTrails: _showTrails,
              onShowTrails: (v) => setState(() => _showTrails = v),
              devShowEta: _devShowEtaPredictionData,
              onDevShowEta: (v) =>
                  setState(() => _devShowEtaPredictionData = v),
              devShowChunkStats: _devShowChunkStats,
              onDevShowChunkStats: (v) =>
                  setState(() => _devShowChunkStats = v),
              autoStop: _devAutoStopWhenJeepReachesPin,
              onAutoStop: (v) =>
                  setState(() => _devAutoStopWhenJeepReachesPin = v),
              includeGhosts: _devAutoStopIncludeGhostJeeps,
              onIncludeGhosts: (v) =>
                  setState(() => _devAutoStopIncludeGhostJeeps = v),
              randomGhostToggleEnabled: _randomGhostToggleEnabled,
              onRandomGhostToggle: (v) =>
                  setState(() => _randomGhostToggleEnabled = v),
              randomGhostLikelihood: _randomGhostToggleLikelihood,
              onRandomGhostLikelihood: (v) =>
                  setState(() => _randomGhostToggleLikelihood = v),
              onConvertAllToGhost: _convertAllMockJeepsToGhost,
              onRestoreAllFromGhost: _restoreAllGhostJeeps,
              // Speed/radius sliders
              controlUserLabel: '#$_controlUserId (${controlUser.jeepType})',
              controlUserSpeed: controlUser.speed.clamp(0.0, 100.0),
              onSpeedChanged: _setControlUserSpeed,
              controlUserRadius: controlUser.visibilityRadius.clamp(
                _minVisibilityRadius,
                _maxVisibilityRadius,
              ),
              minRadius: _minVisibilityRadius,
              maxRadius: _maxVisibilityRadius,
              onRadiusChanged: _setControlUserRadius,
              speedStep: _speedStep,
              visibilityStep: _visibilityStep,
            ),
          ],
        ),
      ),
    );
  }
  // ── end of overridden build ───────────────────────────────────────────────

  // (all original state/logic methods below remain untouched)

  @pragma('vm:prefer-inline')
  String get _unusedDummyForBuildSeparator => '';

  void _onTransformChanged() {
    final nextZoom = _transformationController.value.getMaxScaleOnAxis();
    if (!nextZoom.isFinite || nextZoom <= 0) {
      _transformationController.value = Matrix4.identity();
      if (_zoom != 1 && mounted) {
        setState(() {
          _zoom = 1;
        });
      }
      return;
    }
    if ((nextZoom - _zoom).abs() > 0.01 && mounted) {
      setState(() {
        _zoom = nextZoom;
      });
    }
  }

  void _advanceSimulation() {
    final now = DateTime.now();

    // Auto-generate traffic zones
    _autoGenerateTrafficZones(now);

    _updatePassengerBystanderTransition(now);

    for (final user in _users) {
      if (!user.isMoving || user.isPhoneUser) {
        continue;
      }

      final movingState =
          _movingStates[user.id] ?? _snapUserToRoadAndInitState(user);
      final previousProgress = _progressFromMovingState(movingState);

      final pauseEndsAt = _pauseUntil[user.id];
      if (pauseEndsAt != null && pauseEndsAt.isAfter(now)) {
        continue;
      }

      if (_loadingEnabled) {
        final nextEligible = _nextStopEligibleAt[user.id];
        final canStopNow = nextEligible == null || !nextEligible.isAfter(now);
        if (canStopNow &&
            _random.nextDouble() < (_stopProbability * _frameDtSeconds)) {
          final isLongUnloadStop = _random.nextDouble() < 0.35;
          final seconds = isLongUnloadStop
              ? _randomStopSeconds(
                  minSeconds: _longStopMinSeconds,
                  maxSeconds: _longStopMaxSeconds,
                )
              : _randomStopSeconds(
                  minSeconds: _shortStopMinSeconds,
                  maxSeconds: _shortStopMaxSeconds,
                );
          _pauseUntil[user.id] = now.add(Duration(seconds: seconds));

          final cooldownRange =
              _maxStopCooldownSeconds - _minStopCooldownSeconds;
          final nextCooldownSeconds =
              _minStopCooldownSeconds + _random.nextInt(cooldownRange + 1);
          _nextStopEligibleAt[user.id] = now.add(
            Duration(seconds: nextCooldownSeconds),
          );

          final traversal = _chunkTraversalByUser[user.id];
          if (traversal != null) {
            traversal.accumulatedStopSeconds += seconds;
          }
          continue;
        }
      }

      final effectiveSpeed = _effectiveSpeedForUser(user);
      var remainingDistance = effectiveSpeed * _frameDtSeconds;

      while (remainingDistance > 0) {
        final routeProfile = _getRouteForUser(user);

        // fallback to old system if no route yet
        final road = routeProfile != null
            ? routeProfile.worldPath
            : _roadNetwork[movingState.roadIndex];
        if (road.length < 2) {
          break;
        }

        final start = road[movingState.segmentIndex];
        final end = road[movingState.segmentIndex + 1];
        final segment = end - start;
        final segmentLength = _distanceBetween(start, end);
        if (segmentLength < 0.001) {
          break;
        }

        final availableDistance = movingState.forward
            ? (1 - movingState.t) * segmentLength
            : movingState.t * segmentLength;

        if (remainingDistance < availableDistance) {
          final deltaT = remainingDistance / segmentLength;
          movingState.t += movingState.forward ? deltaT : -deltaT;
          user.position = Offset.lerp(start, end, movingState.t)!;
          user.direction = _normalizeOffset(
            movingState.forward ? segment : -segment,
          );
          remainingDistance = 0;
        } else {
          remainingDistance -= availableDistance;
          movingState.t = movingState.forward ? 1 : 0;
          user.position = Offset.lerp(start, end, movingState.t)!;

          if (movingState.forward) {
            if (movingState.segmentIndex < road.length - 2) {
              movingState.segmentIndex += 1;
              movingState.t = 0;
            } else {
              movingState.forward = false;
              movingState.segmentIndex = road.length - 2;
              movingState.t = 1;
            }
          } else {
            if (movingState.segmentIndex > 0) {
              movingState.segmentIndex -= 1;
              movingState.t = 1;
            } else {
              movingState.forward = true;
              movingState.segmentIndex = 0;
              movingState.t = 0;
            }
          }
        }
      }

      final newProgress = _progressFromMovingState(movingState);
      _recordChunkTraversalForUser(
        userId: user.id,
        oldProgressMeters: previousProgress,
        newProgressMeters: newProgress,
        direction: movingState.forward
            ? RoadDirection.forward
            : RoadDirection.backward,
        now: now,
      );
      _recordRoadWaiterArrivalIfCrossed(
        userId: user.id,
        oldProgressMeters: previousProgress,
        newProgressMeters: newProgress,
        jeepType: user.jeepType,
        isGhost: false,
      );
      _recordTrailPoint(user, user.position);
      _updateKalmanForObservedUser(
        user: user,
        measurementPosition: user.position,
        now: now,
      );
    }

    _updateGhostJeeps(now);
    _simulateRandomObservedGhostTransitions(now);
    _drainRoadChunkEvents(now);
    _updatePhoneUserInferredSpeed(now);
    _sampleWaitPredictionIfWaiting(now);

    setState(() {
      _frame++;
    });
  }

  int _randomStopSeconds({required int minSeconds, required int maxSeconds}) {
    final safeMin = math.min(minSeconds, maxSeconds);
    final safeMax = math.max(minSeconds, maxSeconds);
    return safeMin + _random.nextInt((safeMax - safeMin) + 1);
  }

  void _setLoadingPreset(_LoadingPreset preset) {
    setState(() {
      _loadingPreset = preset;
      switch (preset) {
        case _LoadingPreset.light:
          _stopProbability = 0.05;
          _minStopCooldownSeconds = 22;
          _maxStopCooldownSeconds = 55;
          _shortStopMinSeconds = 1;
          _shortStopMaxSeconds = 3;
          _longStopMinSeconds = 4;
          _longStopMaxSeconds = 7;
          break;
        case _LoadingPreset.normal:
          _stopProbability = 0.10;
          _minStopCooldownSeconds = 12;
          _maxStopCooldownSeconds = 36;
          _shortStopMinSeconds = 2;
          _shortStopMaxSeconds = 5;
          _longStopMinSeconds = 6;
          _longStopMaxSeconds = 11;
          break;
        case _LoadingPreset.congested:
          _stopProbability = 0.22;
          _minStopCooldownSeconds = 6;
          _maxStopCooldownSeconds = 20;
          _shortStopMinSeconds = 3;
          _shortStopMaxSeconds = 6;
          _longStopMinSeconds = 7;
          _longStopMaxSeconds = 14;
          break;
      }
      _loadingEnabled = true;
    });
  }

  /// Auto-generate random traffic zones on road chunks every 30 seconds
  void _autoGenerateTrafficZones(DateTime now) {
    if (!_trafficEnabled || _routeChunks.isEmpty) {
      return;
    }

    _lastTrafficGenerationTime ??= now;
    final timeSinceLastGeneration = now.difference(_lastTrafficGenerationTime!);

    // Regenerate traffic every 30 seconds
    if (timeSinceLastGeneration.inSeconds >= 30) {
      _lastTrafficGenerationTime = now;

      setState(() {
        _trafficZones.clear();

        // Randomly select up to _maxTrafficLines chunks to have traffic
        final chunkIndices = List<int>.generate(_routeChunks.length, (i) => i);
        chunkIndices.shuffle(_random);

        final numTrafficZones = math.min(
          _maxTrafficLines,
          math.max(1, (_routeChunks.length ~/ 4)),
        );

        for (int i = 0; i < numTrafficZones && i < chunkIndices.length; i++) {
          final chunk = _routeChunks[chunkIndices[i]];
          _trafficZones.add(
            TrafficZone(
              start: chunk.startPoint,
              end: chunk.endPoint,
              severity: 0.4 + (_random.nextDouble() * 0.6), // 0.4 - 1.0
            ),
          );
        }
      });
    }
  }

  void _updatePassengerBystanderTransition(DateTime now) {
    final repositionedRecently =
        _lastManualPhoneRepositionAt != null &&
        now.difference(_lastManualPhoneRepositionAt!) <
            _SimulationScreenState._manualRepositionCooldown;
    if (repositionedRecently) {
      return;
    }

    if (_pendingFoundJeepVerification && _pendingFoundJeepAt != null) {
      final elapsed = now.difference(_pendingFoundJeepAt!);
      if (_latestPhoneInferredSpeed >=
          _SimulationScreenState._autoPassengerSpeedThreshold) {
        _isPassengerUser = true;
        _pendingFoundJeepVerification = false;
        _pendingFoundJeepAt = now;
      } else if (elapsed >= _SimulationScreenState._falseJeepDetectionWindow) {
        _pendingFoundJeepVerification = false;
        _pendingFoundJeepAt = null;
        _pendingFoundJeepMaxSpeed = 0;
      }
      return;
    }

    if (!_isPassengerUser || _pendingFoundJeepAt == null) {
      return;
    }

    final passengerElapsed = now.difference(_pendingFoundJeepAt!);
    final sustainedSlow =
        _latestPhoneInferredSpeed <
        (_SimulationScreenState._autoPassengerSpeedThreshold * 0.35);
    if (passengerElapsed >=
            _SimulationScreenState._minPassengerSessionDuration &&
        sustainedSlow) {
      _isPassengerUser = false;
      _pendingFoundJeepAt = null;
      _pendingFoundJeepMaxSpeed = 0;
    }
  }

  void _updatePhoneUserInferredSpeed(DateTime now) {
    if (_lastPhonePositionSample == null ||
        _lastPhonePositionSampleAt == null) {
      _lastPhonePositionSample = _phoneUser.position;
      _lastPhonePositionSampleAt = now;
      return;
    }
    final distance = _distanceBetween(
      _lastPhonePositionSample!,
      _phoneUser.position,
    );
    final elapsed =
        now.difference(_lastPhonePositionSampleAt!).inMilliseconds / 1000;
    if (elapsed > 0.5) {
      _latestPhoneInferredSpeed = distance / elapsed;
      _lastPhonePositionSample = _phoneUser.position;
      _lastPhonePositionSampleAt = now;
    }
  }

  void _sampleWaitPredictionIfWaiting(DateTime now) {
    if (!_isWaitingForJeep || _trackedEta == null) return;
    if (_lastWaitPredictionSampleAt != null &&
        now.difference(_lastWaitPredictionSampleAt!) <
            _waitPredictionSampleInterval) {
      return;
    }
    _lastWaitPredictionSampleAt = now;
    final currentEta = _trackedEta!.etaSeconds;
    _waitPredictedEtaSamples.add(currentEta);
    if (_waitPredictedEtaSamples.length > 10) {
      _waitPredictedEtaSamples.removeAt(0);
    }
    if (_waitPreviousPredictionSample != null) {
      final diff = (currentEta - _waitPreviousPredictionSample!).abs();
      _waitPredictionStabilityAccumulator += diff;
      _waitPredictionStabilitySamples++;
    }
    _waitPreviousPredictionSample = currentEta;
    _waitPredictionSource = _trackedEta!.predictionSource;
    _waitPredictionMethod = _trackedEta!.predictionMethod;
    _waitConfidenceLabel = _trackedEta!.confidenceLabel;
    _waitPredictionDistanceMeters = _trackedEta!.distanceMeters;
    _waitPredictionWindowMinSeconds = _trackedEta!.predictionMinSeconds;
    _waitPredictionWindowMaxSeconds = _trackedEta!.predictionMaxSeconds;
    _waitPredictionGeneratedAt = now;
  }

  double _waitPredictionStabilityPercent() {
    if (_waitPredictionStabilitySamples == 0) return 100;
    final avgDiff =
        _waitPredictionStabilityAccumulator / _waitPredictionStabilitySamples;
    return (100 - (avgDiff * 2)).clamp(0, 100);
  }

  double _waitElapsedSeconds() {
    if (_waitStartAt == null) return 0;
    return DateTime.now().difference(_waitStartAt!).inMilliseconds / 1000;
  }

  User get _phoneUser => _users.firstWhere((u) => u.id == _phoneUserId);
  User get _controlUser => _users.firstWhere((u) => u.id == _controlUserId);

  void _toggleDeveloperMode(bool value) {
    setState(() {
      _isDeveloperMode = value;
      if (!_isDeveloperMode) {
        _isPlacingMockUser = false;
        _isPlacingTrafficZone = false;
        _isPlacingRoadWaiterPin = false;
        _isRoadEditorMode = false;
        _isAddingRoadPoints = false;
        _draftRoutePoints.clear();
      }
    });
  }

  void _onTrackPressed() {
    setState(() {
      _isPlacingRoadWaiterPin = true;
      _trackScanActive = true;
      _isRoadEditorMode = false;
      _isAddingRoadPoints = false;
      _draftRoutePoints.clear();
    });
    _trackResetTimer?.cancel();
    _trackResetTimer = Timer(_trackDuration, () {
      if (mounted) {
        setState(() {
          _trackScanActive = false;
        });
      }
    });
    _lastTrackPressedAt = DateTime.now();
  }

  void _onFoundJeepPressed() {
    if (!_isWaitingForJeep) return;
    final now = DateTime.now();
    _completeRoadWaitMeasurement(
      now: now,
      jeepType: 'Manual Confirmation',
      ghostJeepUsed: false,
    );

    setState(() {
      _pendingFoundJeepVerification = true;
      _pendingFoundJeepAt = now;
      _pendingFoundJeepMaxSpeed = _latestPhoneInferredSpeed;
      _isPassengerUser = false;
    });
  }

  void _completeRoadWaitMeasurement({
    required DateTime now,
    required String jeepType,
    bool ghostJeepUsed = false,
  }) {
    if (!_isWaitingForJeep) return;
    final elapsed = now.difference(_waitStartAt!).inMilliseconds / 1000;
    final predictionError = (_waitPredictedEtaSeconds ?? 0) - elapsed;
    final accuracy = _calculateAccuracy(
      predicted: _waitPredictedEtaSeconds ?? 0,
      actual: elapsed,
    );

    final record = EtaTestRecord(
      timestamp: now,
      roadChunkId: _roadWaiterPin?.chunkId ?? -1,
      jeepType: jeepType,
      predictedEtaSeconds: _waitPredictedEtaSeconds ?? 0,
      actualWaitTimeSeconds: elapsed,
      predictionErrorSeconds: predictionError,
      accuracyPercent: accuracy,
      trafficFactor: _waitPredictedTrafficFactor,
      chunkFlowRate:
          (_roadWaiterPin != null &&
              _roadWaiterPin!.chunkId >= 0 &&
              _roadWaiterPin!.chunkId < _routeChunks.length)
          ? _routeChunks[_roadWaiterPin!.chunkId].flowRateJeepsPerMinute
          : 0.0,
      ghostJeepUsed: ghostJeepUsed,
      predictionSource: _waitPredictionSource,
      predictionMethod: _waitPredictionMethod,
      confidenceLabel: _waitConfidenceLabel,
      predictionDistanceMeters: _waitPredictionDistanceMeters,
      predictionWindowMinSeconds: _waitPredictionWindowMinSeconds,
      predictionWindowMaxSeconds: _waitPredictionWindowMaxSeconds,
      predictionAgeSeconds: _waitPredictionGeneratedAt != null
          ? now.difference(_waitPredictionGeneratedAt!).inSeconds.toDouble()
          : 0,
      predictionStabilityPercent: _waitPredictionStabilityPercent(),
    );

    setState(() {
      _latestEtaTestRecord = record;
      _etaTestRecords.add(record);
      _isWaitingForJeep = false;
      _waitStartAt = null;
      _waitPredictedEtaSeconds = null;
      _roadWaiterPin = null;
      _selectedPinDirection = null;
      if (accuracy > 80) {
        _updateChunkAccuracyStats(record.roadChunkId, accuracy);
      }
    });
  }

  void _cancelRoadWaitMeasurementState() {
    _isWaitingForJeep = false;
    _waitStartAt = null;
    _waitPredictedEtaSeconds = null;
    _waitPredictedEtaSamples.clear();
    _lastWaitPredictionSampleAt = null;
    _waitPredictionStabilityAccumulator = 0;
    _waitPredictionStabilitySamples = 0;
    _waitPreviousPredictionSample = null;
    _waitPredictedTrafficFactor = 1;
    _waitUsedGhostCandidate = false;
    _waitPredictionSource = 'Unknown';
    _waitPredictionMethod = 'Unknown';
    _waitConfidenceLabel = 'LOW';
    _waitPredictionDistanceMeters = 0;
    _waitPredictionWindowMinSeconds = 0;
    _waitPredictionWindowMaxSeconds = 0;
    _waitPredictionGeneratedAt = null;
    _pendingFoundJeepVerification = false;
    _pendingFoundJeepAt = null;
    _pendingFoundJeepMaxSpeed = 0;
    _isPassengerUser = false;
  }

  double _calculateAccuracy({
    required double predicted,
    required double actual,
  }) {
    if (actual < 1) return 100;
    final error = (predicted - actual).abs();
    return (100 - (error / actual * 100)).clamp(0, 100);
  }

  void _updateChunkAccuracyStats(int chunkId, double accuracy) {
    final currentMean = _chunkAccuracyMeanByChunk[chunkId] ?? 0;
    final currentCount = _chunkAccuracySamplesByChunk[chunkId] ?? 0;
    _chunkAccuracyMeanByChunk[chunkId] =
        ((currentMean * currentCount) + accuracy) / (currentCount + 1);
    _chunkAccuracySamplesByChunk[chunkId] = currentCount + 1;
  }

  double _adaptiveSourceWeightForChunk({
    required int chunkId,
    required String source,
    required double baseWeight,
  }) {
    final chunkAccuracy = _chunkAccuracyMeanByChunk[chunkId];
    if (chunkAccuracy == null) return baseWeight;
    final boost = (chunkAccuracy / 100).clamp(0.0, 0.3);
    return baseWeight + boost;
  }

  String _formatSignedSeconds(double seconds) {
    final sign = seconds >= 0 ? '+' : '';
    return '$sign${seconds.toStringAsFixed(1)}s';
  }

  ({
    int totalTests,
    double averageAccuracyPercent,
    double meanAbsoluteErrorSeconds,
    double meanRelativeErrorPercent,
    String bestRouteLabel,
    double bestRouteAccuracyPercent,
    String worstRouteLabel,
    double worstRouteAccuracyPercent,
  })
  _buildRollingAccuracySummary() {
    if (_etaTestRecords.isEmpty) {
      return (
        totalTests: 0,
        averageAccuracyPercent: 0,
        meanAbsoluteErrorSeconds: 0,
        meanRelativeErrorPercent: 0,
        bestRouteLabel: 'N/A',
        bestRouteAccuracyPercent: 0,
        worstRouteLabel: 'N/A',
        worstRouteAccuracyPercent: 0,
      );
    }
    var sumAcc = 0.0;
    var sumAbsErr = 0.0;
    var sumRelErr = 0.0;
    for (final r in _etaTestRecords) {
      sumAcc += r.accuracyPercent;
      sumAbsErr += r.predictionErrorSeconds.abs();
      sumRelErr +=
          (r.predictionErrorSeconds.abs() /
              r.actualWaitTimeSeconds.clamp(1, 9999)) *
          100;
    }
    final avgAcc = sumAcc / _etaTestRecords.length;
    final mae = sumAbsErr / _etaTestRecords.length;
    final mre = sumRelErr / _etaTestRecords.length;

    int? bestId, worstId;
    double bestAcc = -1, worstAcc = 101;
    _chunkAccuracyMeanByChunk.forEach((id, acc) {
      if (acc > bestAcc) {
        bestAcc = acc;
        bestId = id;
      }
      if (acc < worstAcc) {
        worstAcc = acc;
        worstId = id;
      }
    });

    return (
      totalTests: _etaTestRecords.length,
      averageAccuracyPercent: avgAcc,
      meanAbsoluteErrorSeconds: mae,
      meanRelativeErrorPercent: mre,
      bestRouteLabel: bestId == null ? 'N/A' : 'Chunk ${_chunkCode(bestId!)}',
      bestRouteAccuracyPercent: bestAcc == -1 ? 0 : bestAcc,
      worstRouteLabel: worstId == null
          ? 'N/A'
          : 'Chunk ${_chunkCode(worstId!)}',
      worstRouteAccuracyPercent: worstAcc == 101 ? 0 : worstAcc,
    );
  }

  Set<int> _buildTrackVisibleIds(Set<int> baseVisible) {
    if (!_trackScanActive) return baseVisible;
    final allIds = _users.where((u) => !u.isPhoneUser).map((u) => u.id).toSet();
    return {...baseVisible, ...allIds};
  }

  Map<int, Set<int>> _buildVisibilityByUser(List<User> users) {
    final visibility = <int, Set<int>>{};
    for (final observer in users) {
      final visible = <int>{};
      for (final target in users) {
        if (observer.id == target.id) continue;
        if (_distanceBetween(observer.position, target.position) <=
            observer.visibilityRadius) {
          visible.add(target.id);
        }
      }
      visibility[observer.id] = visible;
    }
    return visibility;
  }

  List<ClusterInfo> _buildVisibleMovingClusters(Set<int> visibleIds) {
    final movingVisible = _users
        .where((u) => visibleIds.contains(u.id) && u.isMoving && !u.isPhoneUser)
        .toList();
    if (movingVisible.isEmpty) return [];

    final clusters = <List<User>>[];
    final visited = <int>{};

    for (final user in movingVisible) {
      if (visited.contains(user.id)) continue;
      final currentCluster = <User>[user];
      visited.add(user.id);

      for (final other in movingVisible) {
        if (visited.contains(other.id)) continue;
        final dist = _distanceBetween(user.position, other.position);
        final speedDiff = (user.speed - other.speed).abs();
        final dirSim = _dot(
          _normalizeOffset(user.direction),
          _normalizeOffset(other.direction),
        );

        if (dist < _clusterDistanceThresholdPx &&
            speedDiff < _clusterSpeedDiffThreshold &&
            dirSim > _clusterDirectionSimilarityThreshold) {
          currentCluster.add(other);
          visited.add(other.id);
        }
      }
      if (currentCluster.length > 1) {
        clusters.add(currentCluster);
      }
    }

    return clusters.map((c) {
      var avgPos = Offset.zero;
      for (final u in c) {
        avgPos += u.position;
      }
      avgPos /= c.length.toDouble();

      return ClusterInfo(
        center: avgPos,
        userCount: c.length,
        memberUserIds: c.map((u) => u.id).toSet(),
        jeepTypes: c.map((u) => u.jeepType).toSet(),
      );
    }).toList();
  }

  void _setControlUserSpeed(double value) {
    setState(() {
      _controlUser.speed = value;
    });
  }

  void _setControlUserRadius(double value) {
    setState(() {
      _controlUser.visibilityRadius = value;
    });
  }

  double _flowOnlyEtaForPin({
    required NearestRoadPoint pin,
    required RoadDirection direction,
  }) {
    // Handle chunks with no intelligence yet
    if (pin.chunkId < 0 || pin.chunkId >= _routeChunks.length) {
      return 0;
    }
    final chunk = _routeChunks[pin.chunkId];
    final flow = chunk.flowRateJeepsPerMinute;
    if (flow <= 0.05) return 0;
    return (1 / flow) * 60 * 0.5;
  }

  // ── Ghost intelligence: bulk helpers ─────────────────────────────────────

  /// Converts ALL currently-moving mock jeeps into ghost jeeps in one tap.
  /// The jeep data continues feeding chunk statistics; visually they become
  /// semi-transparent projected markers.
  void _convertAllMockJeepsToGhost() {
    final now = DateTime.now();
    _applyState(() {
      for (final user in _users) {
        if (user.isPhoneUser || !user.isMockUser) continue;
        if (!user.isMoving) continue;
        if (_ghostJeepsBySourceUser.containsKey(user.id)) continue;
        _convertObservedJeepToGhost(user, now);
      }
    });
  }

  /// Restores ALL ghost jeeps back to observed (moving) status.
  /// Their position is restored from the ghost's last projected location,
  /// and they re-join chunk traversal immediately.
  void _restoreAllGhostJeeps() {
    final now = DateTime.now();
    _applyState(() {
      final toRestore = Map<int, GhostJeep>.from(_ghostJeepsBySourceUser);
      for (final entry in toRestore.entries) {
        User? user;
        for (final candidate in _users) {
          if (candidate.id == entry.key) {
            user = candidate;
            break;
          }
        }
        if (user == null) continue;
        _restoreObservedFromGhost(user: user, ghost: entry.value);
        _ghostJeepsBySourceUser.remove(entry.key);
        _initializeKalmanStateFor(user, now);
      }
    });
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SIMULATION LAB UI WIDGETS
// These are purely presentational — all logic stays in _SimulationScreenState
// ═══════════════════════════════════════════════════════════════════════════

class _LabChip extends StatelessWidget {
  final String label;
  final String tooltip;
  const _LabChip({required this.label, required this.tooltip});
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

class _StatusPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _StatusPill({
    required this.icon,
    required this.text,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CanvasToggleBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _CanvasToggleBtn({
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF2E9E99) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 4),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: active ? Colors.white : const Color(0xFF2E9E99),
              size: 14,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : const Color(0xFF2E9E99),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Replaces the old MapLegend with a SakaySain-styled version
class _SimLegend extends StatefulWidget {
  const _SimLegend();
  @override
  State<_SimLegend> createState() => _SimLegendState();
}

class _SimLegendState extends State<_SimLegend> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF01E7A76),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 6),
          ],
        ),
        padding: const EdgeInsets.all(8),
        child: _expanded
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.legend_toggle,
                        color: Colors.white70,
                        size: 14,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Legend',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ..._legendItems.map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: item.$2,
                              shape: item.$3
                                  ? BoxShape.circle
                                  : BoxShape.rectangle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            item.$1,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : const Icon(Icons.legend_toggle, color: Colors.white70, size: 18),
      ),
    );
  }

  static const List<(String, Color, bool)> _legendItems = [
    ('Phone user', Colors.blue, true),
    ('Mock jeep (moving)', Colors.green, false),
    ('Ghost jeep (predicted)', Colors.grey, false),
    ('Waiting user', Color(0xFFCCCCCC), true),
    ('Cluster', Colors.orange, false),
    ('Road waiter pin', Colors.yellow, true),
    ('Road chunk', Colors.blue, false),
    ('Flow heatmap (high)', Colors.redAccent, false),
    ('Traffic zone', Colors.purpleAccent, false),
    ('Snapzone radius', Colors.orange, true),
  ];
}

// ── Dev panel (collapsible bottom bar) ────────────────────────────────────

class _SimDevPanel extends StatefulWidget {
  // Primary actions
  final bool isWaiting;
  final bool isPlacingPin;
  final VoidCallback onTrack;
  final VoidCallback? onFoundJeep;
  final VoidCallback onFilterJeeps;
  // Dev tools
  final bool isDeveloperMode;
  final ValueChanged<bool> onToggleDeveloperMode;
  final bool isRoadEditorMode;
  final bool hasDraftPoints;
  final bool canSaveDraft;
  final VoidCallback onStartRoadEditor;
  final VoidCallback? onClearDraft;
  final VoidCallback? onSaveDraft;
  final VoidCallback? onCancelRoadEditor;
  final VoidCallback onLocalInsights;
  final VoidCallback onMapRouteEditor;
  final VoidCallback onRouteProfiles;
  final bool isPlacingMockUser;
  final VoidCallback onToggleMockUser;
  final bool isPlacingTraffic;
  final VoidCallback onToggleTraffic;
  final VoidCallback onRandomizeTraffic;
  // Toggles
  final bool trafficEnabled;
  final ValueChanged<bool> onTrafficEnabled;
  final bool loadingEnabled;
  final ValueChanged<bool> onLoadingEnabled;
  final _LoadingPreset loadingPreset;
  final ValueChanged<_LoadingPreset> onLoadingPresetChanged;
  final bool showTrails;
  final ValueChanged<bool> onShowTrails;
  final bool devShowEta;
  final ValueChanged<bool> onDevShowEta;
  final bool devShowChunkStats;
  final ValueChanged<bool> onDevShowChunkStats;
  final bool autoStop;
  final ValueChanged<bool> onAutoStop;
  final bool includeGhosts;
  final ValueChanged<bool> onIncludeGhosts;
  // Ghost intelligence controls
  final bool randomGhostToggleEnabled;
  final ValueChanged<bool> onRandomGhostToggle;
  final double randomGhostLikelihood;
  final ValueChanged<double> onRandomGhostLikelihood;
  final VoidCallback onConvertAllToGhost;
  final VoidCallback onRestoreAllFromGhost;
  // Sliders
  final String controlUserLabel;
  final double controlUserSpeed;
  final ValueChanged<double> onSpeedChanged;
  final double controlUserRadius;
  final double minRadius;
  final double maxRadius;
  final ValueChanged<double> onRadiusChanged;
  final double speedStep;
  final double visibilityStep;

  const _SimDevPanel({
    required this.isWaiting,
    required this.isPlacingPin,
    required this.onTrack,
    required this.onFoundJeep,
    required this.onFilterJeeps,
    required this.isDeveloperMode,
    required this.onToggleDeveloperMode,
    required this.isRoadEditorMode,
    required this.hasDraftPoints,
    required this.canSaveDraft,
    required this.onStartRoadEditor,
    required this.onClearDraft,
    required this.onSaveDraft,
    required this.onCancelRoadEditor,
    required this.onLocalInsights,
    required this.onMapRouteEditor,
    required this.onRouteProfiles,
    required this.isPlacingMockUser,
    required this.onToggleMockUser,
    required this.isPlacingTraffic,
    required this.onToggleTraffic,
    required this.onRandomizeTraffic,
    required this.trafficEnabled,
    required this.onTrafficEnabled,
    required this.loadingEnabled,
    required this.onLoadingEnabled,
    required this.loadingPreset,
    required this.onLoadingPresetChanged,
    required this.showTrails,
    required this.onShowTrails,
    required this.devShowEta,
    required this.onDevShowEta,
    required this.devShowChunkStats,
    required this.onDevShowChunkStats,
    required this.autoStop,
    required this.onAutoStop,
    required this.includeGhosts,
    required this.onIncludeGhosts,
    required this.randomGhostToggleEnabled,
    required this.onRandomGhostToggle,
    required this.randomGhostLikelihood,
    required this.onRandomGhostLikelihood,
    required this.onConvertAllToGhost,
    required this.onRestoreAllFromGhost,
    required this.controlUserLabel,
    required this.controlUserSpeed,
    required this.onSpeedChanged,
    required this.controlUserRadius,
    required this.minRadius,
    required this.maxRadius,
    required this.onRadiusChanged,
    required this.speedStep,
    required this.visibilityStep,
  });

  @override
  State<_SimDevPanel> createState() => _SimDevPanelState();
}

class _SimDevPanelState extends State<_SimDevPanel> {
  bool _expanded = true;

  @override
  void didUpdateWidget(covariant _SimDevPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isDeveloperMode && widget.isDeveloperMode) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E7A76),
        boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 10)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── ALWAYS-VISIBLE ACTION ROW ─────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // Track button
                  _PanelBtn(
                    label: widget.isPlacingPin
                        ? 'Placing...'
                        : widget.isWaiting
                        ? 'Tracking'
                        : 'Track',
                    icon: Icons.location_searching,
                    active: widget.isWaiting || widget.isPlacingPin,
                    onTap: widget.onTrack,
                  ),
                  const SizedBox(width: 8),
                  // Found Jeep button
                  _PanelBtn(
                    label: 'Found Jeep',
                    icon: Icons.directions_bus,
                    active: widget.isWaiting,
                    onTap: widget.onFoundJeep,
                    enabled: widget.isWaiting,
                  ),
                  const SizedBox(width: 8),
                  // Filter
                  _PanelBtn(
                    label: 'Filter',
                    icon: Icons.filter_list,
                    onTap: widget.onFilterJeeps,
                  ),
                  const Spacer(),
                  // Dev mode toggle
                  Row(
                    children: [
                      Text(
                        'DEV',
                        style: TextStyle(
                          color: widget.isDeveloperMode
                              ? Colors.white
                              : Colors.white38,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Transform.scale(
                        scale: 0.75,
                        child: Switch(
                          value: widget.isDeveloperMode,
                          onChanged: widget.onToggleDeveloperMode,
                          activeColor: Colors.white,
                          activeTrackColor: const Color(0xFF2E9E99),
                          inactiveThumbColor: Colors.white38,
                          inactiveTrackColor: Colors.white12,
                        ),
                      ),
                    ],
                  ),
                  // Expand/collapse chevron
                  if (widget.isDeveloperMode)
                    GestureDetector(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          _expanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_up,
                          color: Colors.white70,
                          size: 22,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // ── EXPANDED DEV TOOLS ────────────────────────────────
            if (widget.isDeveloperMode && _expanded)
              Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.40,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFF164E4A),
                  border: Border(
                    top: BorderSide(color: Colors.white12, width: 1),
                  ),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Road tools
                      _SectionLabel('Road Tools'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _SmallBtn(
                            label: widget.isRoadEditorMode
                                ? 'Editing...'
                                : 'Road Editor',
                            onTap: widget.onStartRoadEditor,
                          ),
                          _SmallBtn(
                            label: 'Clear Draft',
                            onTap: widget.onClearDraft,
                            enabled: widget.hasDraftPoints,
                          ),
                          _SmallBtn(
                            label: 'Save Draft',
                            onTap: widget.onSaveDraft,
                            enabled: widget.canSaveDraft,
                            highlight: true,
                          ),
                          _SmallBtn(
                            label: 'Cancel Edit',
                            onTap: widget.onCancelRoadEditor,
                            enabled: widget.isRoadEditorMode,
                          ),
                          _SmallBtn(
                            label: 'Map Route Editor',
                            onTap: widget.onMapRouteEditor,
                          ),
                          _SmallBtn(
                            label: 'Load Route',
                            onTap: widget.onRouteProfiles,
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),
                      _SectionLabel('Simulation Tools'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _SmallBtn(
                            label: widget.isPlacingMockUser
                                ? 'Stop Placing'
                                : 'Place Jeep',
                            onTap: widget.onToggleMockUser,
                            active: widget.isPlacingMockUser,
                          ),
                          _SmallBtn(
                            label: 'Random Traffic',
                            onTap: widget.onToggleTraffic,
                            active: widget.isPlacingTraffic,
                          ),
                          _SmallBtn(
                            label: 'Randomize Traffic',
                            onTap: widget.onRandomizeTraffic,
                          ),
                          _SmallBtn(
                            label: 'Local Insights',
                            onTap: widget.onLocalInsights,
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),
                      _SectionLabel('Toggles'),
                      _ToggleRow(
                        'Traffic Enabled',
                        widget.trafficEnabled,
                        widget.onTrafficEnabled,
                      ),
                      _ToggleRow(
                        'Mock Loading',
                        widget.loadingEnabled,
                        widget.onLoadingEnabled,
                      ),
                      const Text(
                        'Loading Preset',
                        style: TextStyle(color: Colors.white60, fontSize: 11),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _SmallBtn(
                            label: 'Light',
                            active:
                                widget.loadingPreset == _LoadingPreset.light,
                            onTap: () => widget.onLoadingPresetChanged(
                              _LoadingPreset.light,
                            ),
                          ),
                          _SmallBtn(
                            label: 'Normal',
                            active:
                                widget.loadingPreset == _LoadingPreset.normal,
                            onTap: () => widget.onLoadingPresetChanged(
                              _LoadingPreset.normal,
                            ),
                          ),
                          _SmallBtn(
                            label: 'Congested',
                            active:
                                widget.loadingPreset ==
                                _LoadingPreset.congested,
                            onTap: () => widget.onLoadingPresetChanged(
                              _LoadingPreset.congested,
                            ),
                          ),
                        ],
                      ),
                      _ToggleRow(
                        'Show Trails',
                        widget.showTrails,
                        widget.onShowTrails,
                      ),
                      _ToggleRow(
                        'Show ETA Data',
                        widget.devShowEta,
                        widget.onDevShowEta,
                      ),
                      _ToggleRow(
                        'Show Chunk Stats',
                        widget.devShowChunkStats,
                        widget.onDevShowChunkStats,
                      ),
                      _ToggleRow(
                        'Auto-stop on Arrival',
                        widget.autoStop,
                        widget.onAutoStop,
                      ),
                      _ToggleRow(
                        'Include Ghost Jeeps',
                        widget.includeGhosts,
                        widget.onIncludeGhosts,
                      ),

                      const SizedBox(height: 10),
                      _SectionLabel('Ghost Jeep Intelligence'),
                      _ToggleRow(
                        'Random Ghost Transitions',
                        widget.randomGhostToggleEnabled,
                        widget.onRandomGhostToggle,
                      ),
                      if (widget.randomGhostToggleEnabled) ...[
                        const Text(
                          'Transition Likelihood',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        Slider(
                          value: widget.randomGhostLikelihood.clamp(0.01, 0.5),
                          min: 0.01,
                          max: 0.5,
                          divisions: 49,
                          label:
                              '${(widget.randomGhostLikelihood * 100).toStringAsFixed(0)}%',
                          activeColor: Colors.purpleAccent,
                          inactiveColor: Colors.white24,
                          onChanged: widget.onRandomGhostLikelihood,
                        ),
                      ],
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _SmallBtn(
                            label: '👻 All → Ghost',
                            onTap: widget.onConvertAllToGhost,
                          ),
                          _SmallBtn(
                            label: '🚌 Restore All',
                            onTap: widget.onRestoreAllFromGhost,
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),
                      _SectionLabel('Control: ${widget.controlUserLabel}'),
                      const Text(
                        'Speed',
                        style: TextStyle(color: Colors.white60, fontSize: 11),
                      ),
                      Slider(
                        value: widget.controlUserSpeed,
                        min: 0,
                        max: 100,
                        divisions: (100 / widget.speedStep).round(),
                        label: widget.controlUserSpeed.toStringAsFixed(0),
                        activeColor: const Color(0xFF2E9E99),
                        inactiveColor: Colors.white24,
                        onChanged: widget.onSpeedChanged,
                      ),
                      const Text(
                        'Visibility Radius',
                        style: TextStyle(color: Colors.white60, fontSize: 11),
                      ),
                      Slider(
                        value: widget.controlUserRadius,
                        min: widget.minRadius,
                        max: widget.maxRadius,
                        divisions:
                            ((widget.maxRadius - widget.minRadius) /
                                    widget.visibilityStep)
                                .round(),
                        label: widget.controlUserRadius.toStringAsFixed(0),
                        activeColor: const Color(0xFF2E9E99),
                        inactiveColor: Colors.white24,
                        onChanged: widget.onRadiusChanged,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Panel micro-widgets ──────────────────────────────────────────────────

class _PanelBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final bool enabled;

  const _PanelBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveEnabled = enabled && onTap != null;
    return GestureDetector(
      onTap: effectiveEnabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: effectiveEnabled ? 1.0 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.white.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active ? Colors.white : Colors.white.withOpacity(0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: active ? const Color(0xFF1E7A76) : Colors.white,
                size: 14,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: active ? const Color(0xFF1E7A76) : Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool enabled;
  final bool active;
  final bool highlight;

  const _SmallBtn({
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.active = false,
    this.highlight = false,
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF2E9E99)
                : highlight
                ? Colors.white
                : Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withOpacity(0.25)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: highlight ? const Color(0xFF1E7A76) : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow(this.label, this.value, this.onChanged);
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        Transform.scale(
          scale: 0.75,
          child: Switch(
            value: value,
            onChanged: onChanged,
            activeColor: Colors.white,
            activeTrackColor: const Color(0xFF2E9E99),
            inactiveThumbColor: Colors.white38,
            inactiveTrackColor: Colors.white12,
          ),
        ),
      ],
    );
  }
}
