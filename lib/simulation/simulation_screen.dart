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

part 'simulation_screen_chunk_eta_part.dart';
part 'simulation_screen_interaction_part.dart';
part 'simulation_screen_geometry_part.dart';
part 'simulation_screen_verification_part.dart';


enum CommunityVoteTargetType {
  jeepSighting,
  routeAccuracy,
}

enum CommunityVoteRole {
  passenger,
  pedestrian,
}

enum CommunityVoteChoice {
  confirm,
  reject,
  accurate,
  inaccurate,
}

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
  bool _isDeveloperMode = false;
  bool _isPlacingMockUser = false;

  bool _isRoadEditorMode = false;
  bool _isAddingRoadPoints = false;
  final List<Offset> _draftRoutePoints = <Offset>[];

  bool _showTrails = true;

  bool _isPlacingTrafficZone = false;
  bool _trafficEnabled = false;
  bool _showFlowHeatOverlay = false;
  int _maxTrafficLines = 4;
  final List<TrafficZone> _trafficZones = [];

  bool _loadingEnabled = false;
  double _stopProbability = 0.1;
  bool _kalmanEnabled = true;
  double _kalmanGain = _defaultKalmanGain;
  bool _randomGhostToggleEnabled = false;
  double _randomGhostToggleLikelihood = 0.12;
  final Map<int, DateTime> _pauseUntil = {};
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

    return Scaffold(
      appBar: AppBar(title: const Text('2D Mobility Simulation')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: topPanelMaxHeight,
              child: NotificationListener<OverscrollIndicatorNotification>(
                onNotification: (notification) {
                  notification.disallowIndicator();
                  return true;
                },
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Users: ${_users.length} | Visible to phone: ${effectiveVisibleToPhone.length} | Zoom: ${_zoom.toStringAsFixed(2)}x',
                      ),
                      Text(
                        'Observed jeeps: ${_users.where((u) => !u.isPhoneUser && u.isMoving).length} | Ghost jeeps: ${_ghostJeepsBySourceUser.length}',
                      ),
                      Text('Route Source: $_routeDataSource | Map Points: ${_savedMapRoutePoints.length}'),
                      if (_isLoadingSavedRoute)
                        const Text('Loading saved route...'),
                      const SizedBox(height: 6),
                      if (_devShowEtaPredictionData)
                        Text(
                          _roadWaiterPin == null
                              ? 'ETA: Place Road Waiter Pin using Track'
                              : _selectedPinDirection == null
                              ? 'ETA: Select pin direction (Forward/Backward)'
                              : _trackedEta == null
                              ? 'ETA: No approaching jeep found for selected types'
                              : 'Nearest Jeep: ${_trackedEta!.jeepType} (#${_trackedEta!.userId}) | ETA: ${_trackedEta!.etaSeconds.toStringAsFixed(1)}s | Confidence: ${_trackedEta!.confidenceLabel} (${_trackedEta!.confidencePercent.toStringAsFixed(0)}%) | Distance: ${_trackedEta!.distanceMeters.toStringAsFixed(0)}m | TFactor: ${_trackedEta!.trafficFactor.toStringAsFixed(2)}',
                        ),
                      if (_devShowEtaPredictionData && _trackedEta != null)
                        Text(
                          'Method: ${_trackedEta!.predictionMethod} | Source: ${_trackedEta!.predictionSource} | Window: ${_trackedEta!.predictionMinSeconds.toStringAsFixed(1)}s-${_trackedEta!.predictionMaxSeconds.toStringAsFixed(1)}s | Age: ${_trackedEta!.predictionAgeSeconds.toStringAsFixed(1)}s',
                        ),
                      if (_devShowEtaPredictionData && _trackedEta != null)
                        Text(
                          'ETA components: realtime ${_trackedEta!.etaRealTimeSeconds.toStringAsFixed(1)}s, historical ${_trackedEta!.etaHistoricalSeconds.toStringAsFixed(1)}s, traffic ${_trackedEta!.etaTrafficSeconds.toStringAsFixed(1)}s',
                        ),
                      if (_isWaitingForJeep)
                        Text(
                          'Wait timer: ${_waitElapsedSeconds().toStringAsFixed(1)}s | Initial prediction: ${(_waitPredictedEtaSeconds ?? 0).toStringAsFixed(1)}s | Phone speed: ${_latestPhoneInferredSpeed.toStringAsFixed(1)} m/s',
                        ),
                      if (_isWaitingForJeep)
                        Text(
                          'Prediction Source: $_waitPredictionSource | Confidence: $_waitConfidenceLabel | Distance: ${_waitPredictionDistanceMeters.toStringAsFixed(0)}m',
                        ),
                      if (_isWaitingForJeep)
                        Text(
                          'Prediction Window: ${_waitPredictionWindowMinSeconds.toStringAsFixed(1)}s - ${_waitPredictionWindowMaxSeconds.toStringAsFixed(1)}s | Stability: ${_waitPredictionStabilityPercent().toStringAsFixed(1)}%',
                        ),
                      if (_pendingFoundJeepVerification)
                        Text(
                          'Manual jeep confirmation pending: ${_falseJeepDetectionWindow.inSeconds}s verification window',
                        ),
                      if (_isWaitingForJeep)
                        Text(
                          'Passenger state: ${_isPassengerUser ? 'PENDING/ACTIVE' : 'IDLE'}',
                        ),
                      if (_etaTestRecords.isNotEmpty)
                        Text(
                          'Total Tests: ${rollingSummary.totalTests} | Average Accuracy: ${rollingSummary.averageAccuracyPercent.toStringAsFixed(1)}%',
                        ),
                      if (_etaTestRecords.isNotEmpty)
                        Text(
                          'Mean Abs Error: ${rollingSummary.meanAbsoluteErrorSeconds.toStringAsFixed(1)}s | Mean Rel Error: ${rollingSummary.meanRelativeErrorPercent.toStringAsFixed(1)}%',
                        ),
                      if (_etaTestRecords.isNotEmpty)
                        Text(
                          'Best Route Accuracy: ${rollingSummary.bestRouteLabel} (${rollingSummary.bestRouteAccuracyPercent.toStringAsFixed(1)}%) | Worst Route Accuracy: ${rollingSummary.worstRouteLabel} (${rollingSummary.worstRouteAccuracyPercent.toStringAsFixed(1)}%)',
                        ),
                      if (_latestEtaTestRecord != null)
                        Text(
                          'Latest test: chunk ${_chunkCode(_latestEtaTestRecord!.roadChunkId)} | error ${_formatSignedSeconds(_latestEtaTestRecord!.predictionErrorSeconds)} | accuracy ${_latestEtaTestRecord!.accuracyPercent.toStringAsFixed(1)}% | jeep ${_latestEtaTestRecord!.jeepType}',
                        ),
                      if (_latestEtaTestRecord != null)
                        Text(
                          'Latest source: ${_latestEtaTestRecord!.predictionSource} (${_latestEtaTestRecord!.confidenceLabel}) | Method: ${_latestEtaTestRecord!.predictionMethod} | Dist: ${_latestEtaTestRecord!.predictionDistanceMeters.toStringAsFixed(0)}m',
                        ),
                      if (_selectedPinDirection != null)
                        Text(
                          'Direction: ${_selectedPinDirection == RoadDirection.forward ? 'FORWARD (start → end)' : 'BACKWARD (end → start)'}',
                        ),
                      if (_roadWaiterPin != null && _trackedEta == null)
                        Text(
                          'Avg arrival interval: ${_averageArrivalIntervalSeconds(_roadWaiterPin!.chunkId).toStringAsFixed(1)}s',
                        ),
                      if (_trackScanActive)
                        Text(
                          'Track scan active (${_lastTrackPressedAt == null ? 0 : DateTime.now().difference(_lastTrackPressedAt!).inSeconds}s): hidden jeeps temporarily revealed',
                        ),
                      if (_communityVotes.isNotEmpty)
                        Text(
                          'Community Votes: ${_communityVotes.length} | Your Trust: ${_trustProfileFor(_phoneUserId).reliabilityPercent.toStringAsFixed(1)}%',
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('Developer Mode'),
                          Switch(
                            value: _isDeveloperMode,
                            onChanged: _toggleDeveloperMode,
                          ),
                          ElevatedButton(
                            onPressed: _onTrackPressed,
                            child: Text(
                              _isPlacingRoadWaiterPin
                                  ? 'Tap road to place pin...'
                                  : 'Track',
                            ),
                          ),
                          ElevatedButton(
                            onPressed: _isWaitingForJeep
                                ? _onFoundJeepPressed
                                : null,
                            child: const Text('Found Jeep'),
                          ),
                          ElevatedButton(
                            onPressed: _openJeepTypeSelectionPanel,
                            child: const Text('Filter Jeeps'),
                          ),
                        ],
                      ),
                      if (!_isDeveloperMode)
                        const Text(
                          'Developer tools are hidden. Enable Developer Mode to test interactions.',
                        ),
                      const SizedBox(height: 8),
                      if (_isDeveloperMode)
                        Text(
                          _isPlacingRoadWaiterPin
                              ? 'Track Mode: Tap map to place Road Waiter Pin (snaps to road)'
                              : _isRoadEditorMode
                              ? 'Road Editor: tap map to add route points, then Save draft road.'
                              : _isPlacingMockUser
                              ? 'Dev Mode: Tap map to place mock user (near road = auto moving jeep)'
                              : _isPlacingTrafficZone
                              ? 'Dev Mode: Tap map near road to place traffic line'
                              : 'Dev Mode: Tap map to move your phone user / select mock user',
                        ),
                      if (_isDeveloperMode) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ElevatedButton(
                              onPressed: _startRoadEditor,
                              child: Text(
                                _isRoadEditorMode
                                    ? 'Editing road...'
                                    : 'Road editor',
                              ),
                            ),
                            ElevatedButton(
                              onPressed: _draftRoutePoints.isNotEmpty
                                  ? _clearDraftRoad
                                  : null,
                              child: const Text('Clear draft road'),
                            ),
                            ElevatedButton(
                              onPressed: _draftRoutePoints.length >= 2
                                  ? _saveDraftRoad
                                  : null,
                              child: const Text('Save draft road'),
                            ),
                            ElevatedButton(
                              onPressed: _isRoadEditorMode
                                  ? _cancelRoadEditor
                                  : null,
                              child: const Text('Cancel road edit'),
                            ),
                            ElevatedButton(
                              onPressed: _openLocalActivityInsights,
                              child: const Text('Local insights'),
                            ),
                            ElevatedButton(
                              onPressed: _openMapRouteEditor,
                              child: const Text('Map route editor'),
                            ),
                            ElevatedButton(
                              onPressed: _openRouteProfiles,
                              child: const Text("Load Route"),
                            ),
                            ElevatedButton(
                              onPressed: _routeChunks.isEmpty
                                  ? null
                                  : () {
                                final chunkId =
                                    _selectedVerificationChunkId ?? 0;
                                _openVerificationPanelForChunk(
                                  chunkId.clamp(0, _routeChunks.length - 1),
                                );
                              },
                              child: const Text('Community Verify'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Dev Mode Settings',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Row(
                          children: [
                            const Text('Auto-stop when jeep reaches pin'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _devAutoStopWhenJeepReachesPin,
                              onChanged: (value) => setState(
                                    () => _devAutoStopWhenJeepReachesPin = value,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Include ghost jeeps'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _devAutoStopIncludeGhostJeeps,
                              onChanged: (value) => setState(
                                    () => _devAutoStopIncludeGhostJeeps = value,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Show ETA prediction data'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _devShowEtaPredictionData,
                              onChanged: (value) => setState(
                                    () => _devShowEtaPredictionData = value,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Show chunk stats'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _devShowChunkStats,
                              onChanged: (value) =>
                                  setState(() => _devShowChunkStats = value),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Traffic Enabled'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _trafficEnabled,
                              onChanged: (value) =>
                                  setState(() => _trafficEnabled = value),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Mock Loading Enabled'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _loadingEnabled,
                              onChanged: (value) =>
                                  setState(() => _loadingEnabled = value),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Show Trails'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _showTrails,
                              onChanged: (value) =>
                                  setState(() => _showTrails = value),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ElevatedButton(
                              onPressed: _isPlacingMockUser
                                  ? () => setState(() => _isPlacingMockUser = false)
                                  : _startAddMockUser,
                              child: Text(
                                _isPlacingMockUser
                                    ? 'Stop Placing Mock Users'
                                    : 'Place Mock User',
                              ),
                            ),
                            ElevatedButton(
                              onPressed: _togglePlaceTrafficZone,
                              child: Text(
                                _isPlacingTrafficZone
                                    ? 'Stop Placing Traffic'
                                    : 'Place Traffic Zone',
                              ),
                            ),
                            ElevatedButton(
                              onPressed: _randomizeTrafficZones,
                              child: const Text('Randomize Traffic'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Control User: #$_controlUserId (${controlUser.jeepType})',
                        ),
                        Slider(
                          value: controlUser.speed.clamp(0.0, 100.0),
                          min: 0,
                          max: 100,
                          divisions: (100 / _speedStep).round(),
                          label: controlUser.speed.toStringAsFixed(0),
                          onChanged: _setControlUserSpeed,
                        ),
                        const Text('Selected mock user visibility radius'),
                        Slider(
                          value: controlUser.visibilityRadius.clamp(
                            _minVisibilityRadius,
                            _maxVisibilityRadius,
                          ),
                          min: _minVisibilityRadius,
                          max: _maxVisibilityRadius,
                          divisions:
                          ((_maxVisibilityRadius - _minVisibilityRadius) /
                              _visibilityStep)
                              .round(),
                          label: controlUser.visibilityRadius.toStringAsFixed(
                            0,
                          ),
                          onChanged: _setControlUserRadius,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ClipRect(
                child: Stack(
                  children: [
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
                                  .map(
                                    (chunk) =>
                                chunk.flowRateJeepsPerMinute,
                              )
                                  .reduce(math.max),
                              users: _users,
                              trafficZones: _trafficZones
                                  .map(
                                    (zone) =>
                                (start: zone.start, end: zone.end),
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
                                  .where(
                                    (entry) =>
                                    entry.value.isAfter(DateTime.now()),
                              )
                                  .map((entry) => entry.key)
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
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: MapLegend(selectedUserId: _controlUserId),
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

      if (_loadingEnabled &&
          _random.nextDouble() < (_stopProbability * _frameDtSeconds)) {
        final seconds = 3 + _random.nextInt(4);
        _pauseUntil[user.id] = now.add(Duration(seconds: seconds));
        final traversal = _chunkTraversalByUser[user.id];
        if (traversal != null) {
          traversal.accumulatedStopSeconds += seconds;
        }
        continue;
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

  void _updatePhoneUserInferredSpeed(DateTime now) {
    if (_lastPhonePositionSample == null || _lastPhonePositionSampleAt == null) {
      _lastPhonePositionSample = _phoneUser.position;
      _lastPhonePositionSampleAt = now;
      return;
    }
    final distance = _distanceBetween(_lastPhonePositionSample!, _phoneUser.position);
    final elapsed = now.difference(_lastPhonePositionSampleAt!).inMilliseconds / 1000;
    if (elapsed > 0.5) {
      _latestPhoneInferredSpeed = distance / elapsed;
      _lastPhonePositionSample = _phoneUser.position;
      _lastPhonePositionSampleAt = now;
    }
  }

  void _sampleWaitPredictionIfWaiting(DateTime now) {
    if (!_isWaitingForJeep || _trackedEta == null) return;
    if (_lastWaitPredictionSampleAt != null &&
        now.difference(_lastWaitPredictionSampleAt!) < _waitPredictionSampleInterval) {
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
    final avgDiff = _waitPredictionStabilityAccumulator / _waitPredictionStabilitySamples;
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
      chunkFlowRate: (_roadWaiterPin != null && _roadWaiterPin!.chunkId >= 0 && _roadWaiterPin!.chunkId < _routeChunks.length)
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

  double _calculateAccuracy({required double predicted, required double actual}) {
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
      sumRelErr += (r.predictionErrorSeconds.abs() / r.actualWaitTimeSeconds.clamp(1, 9999)) * 100;
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
    worstRouteLabel: worstId == null ? 'N/A' : 'Chunk ${_chunkCode(worstId!)}',
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
        if (_distanceBetween(observer.position, target.position) <= observer.visibilityRadius) {
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
        final dirSim = _dot(_normalizeOffset(user.direction), _normalizeOffset(other.direction));

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
    final chunk = _routeChunks[pin.chunkId];
    final flow = chunk.flowRateJeepsPerMinute;
    if (flow <= 0.05) return 0;
    return (1 / flow) * 60 * 0.5;
  }
}
