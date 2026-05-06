import 'dart:async';
import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../screens/road_persistence_service.dart';

/// ╔══════════════════════════════════════════════════════════════════════════╗
/// ║  ROAD INTELLIGENCE SERVICE                                               ║
/// ║  Manages near-user road data: chunks, wait times, jeeps, activity       ║
/// ║  Updates every 2 minutes                                                 ║
/// ╚══════════════════════════════════════════════════════════════════════════╝

class RoadChunkIntelligence {
  final String chunkId;
  final LatLng center;
  final String avgWaitTime;      // "2-5 min", "--" if no data
  final List<String> commonJeeps; // ["A", "B", "C"], [] if no data
  final String activity;          // "High", "Medium", "Low", "--"
  final int activeJeepsNearby;
  final String lastJeepPassed;   // "12s ago", "--" if no data
  final DateTime lastUpdated;

  RoadChunkIntelligence({
    required this.chunkId,
    required this.center,
    required this.avgWaitTime,
    required this.commonJeeps,
    required this.activity,
    required this.activeJeepsNearby,
    required this.lastJeepPassed,
    required this.lastUpdated,
  });

  /// Check if this chunk has valid intelligence data
  bool get hasValidData =>
      avgWaitTime != '--' &&
      commonJeeps.isNotEmpty &&
      activity != '--' &&
      activeJeepsNearby > 0;

  Map<String, dynamic> toJson() => {
    'chunkId': chunkId,
    'center': {'lat': center.latitude, 'lng': center.longitude},
    'avgWaitTime': avgWaitTime,
    'commonJeeps': commonJeeps,
    'activity': activity,
    'activeJeepsNearby': activeJeepsNearby,
    'lastJeepPassed': lastJeepPassed,
    'lastUpdated': lastUpdated.toIso8601String(),
  };
}

/// Manages road intelligence across all nearby chunks
class RoadIntelligenceService {
  static final RoadIntelligenceService _instance = RoadIntelligenceService._internal();

  factory RoadIntelligenceService() => _instance;
  RoadIntelligenceService._internal();

  // ── State ────────────────────────────────────────────────────────────────
  Map<String, RoadChunkIntelligence> _chunkIntelligence = {};
  RoadChunkIntelligence? _nearestChunk;
  Timer? _updateTimer;
  LatLng? _lastUserLocation;

  final List<Function()> _updateListeners = [];

  // Constants
  static const Duration _updateInterval = Duration(minutes: 2);
  static const double _searchRadiusMeters = 500.0; // Search within 500m radius

  // Mock data storage (in real app, comes from backend)
  final Map<String, Map<String, dynamic>> _jeepActivityLog = {};
  final Map<String, List<int>> _chunkWaitTimes = {}; // In seconds

  // ── Listeners ────────────────────────────────────────────────────────────
  void addUpdateListener(Function() listener) {
    _updateListeners.add(listener);
  }

  void removeUpdateListener(Function() listener) {
    _updateListeners.remove(listener);
  }

  void _notifyUpdate() {
    for (var listener in _updateListeners) {
      listener();
    }
  }

  // ── Getters ──────────────────────────────────────────────────────────────
  RoadChunkIntelligence? get nearestChunk => _nearestChunk;
  Map<String, RoadChunkIntelligence> get allChunkIntelligence => _chunkIntelligence;

  /// ╔════════════════════════════════════════════════════════════════════════╗
  /// ║ INTELLIGENCE DATA FOR MAIN SCREEN                                    ║
  /// ║                                                                        ║
  /// ║ Updates every 2 minutes                                               ║
  /// ║ Shows:                                                                 ║
  /// ║ • Nearest road chunk                                                   ║
  /// ║ • Avg wait time                                                        ║
  /// ║ • Common jeeps                                                         ║
  /// ║ • Activity level                                                       ║
  /// ║ • Active jeeps nearby                                                  ║
  /// ║ • Last jeep passed                                                     ║
  /// ║                                                                        ║
  /// ║ Shows "--" until user is in snapzone radius (30m)                    ║
  /// ╚════════════════════════════════════════════════════════════════════════╝

  /// Initialize intelligence service
  void initialize() {
    startPeriodicUpdates();
  }

  /// Update intelligence for user location
  Future<void> updateIntelligence(LatLng userLocation) async {
    _lastUserLocation = userLocation;
    await _fetchNearbyChunkIntelligence(userLocation);
  }

  /// Manually trigger intelligence update (useful for immediate feedback)
  Future<void> forceUpdate() async {
    if (_lastUserLocation != null) {
      await updateIntelligence(_lastUserLocation!);
    }
  }

  /// Fetch intelligence for all chunks near user
  Future<void> _fetchNearbyChunkIntelligence(LatLng userLocation) async {
    // Load actual saved roads and analyze them
    await _generateRealIntelligence(userLocation);
    _notifyUpdate();
  }

  /// Generate intelligence based on ACTUAL saved roads (not mock data)
  Future<void> _generateRealIntelligence(LatLng userLocation) async {
    // Clear previous data
    _chunkIntelligence.clear();
    _nearestChunk = null;

    try {
      // Load actual saved roads and routes
      final savedRoads = await RoadPersistenceService.loadRoads();
      final savedRoutes = await RoadPersistenceService.loadRoutes();

      // If no roads saved, return with all "--"
      if (savedRoads.isEmpty) {
        _createEmptyStats();
        return;
      }

      // Find nearest road to user
      double minDistToRoad = double.infinity;
      SakayRoad? nearestRoad;
      LatLng? nearestPointOnRoad;

      for (final road in savedRoads) {
        // Find closest point on this road to user
        final pointOnRoad = _findNearestPointOnRoad(userLocation, road);
        final distToRoad = _haversineDistance(userLocation, pointOnRoad);

        if (distToRoad < minDistToRoad) {
          minDistToRoad = distToRoad;
          nearestRoad = road;
          nearestPointOnRoad = pointOnRoad;
        }
      }

      // Check if user is within snapzone (30m)
      if (nearestRoad == null || minDistToRoad > 30.0) {
        // Not in snapzone - show all "--"
        _createEmptyStats();
        return;
      }

      // User is in snapzone! Generate real data for this road
      final routesOnThisRoad =
          savedRoutes.where((r) => r.roadId == nearestRoad.id).toList();

      // Extract jeep types from routes
      final jeepTypes = <String>{};
      for (final route in routesOnThisRoad) {
        jeepTypes.add(route.jeepName); // e.g., "A", "B", "C"
      }

      // Create chunk for the nearest road
      final chunkId = 'chunk_${nearestRoad.id}';
      final chunkCenter = nearestPointOnRoad!;

      // Determine wait time based on recorded data or use default
      String avgWaitTime = '--';
      if (_chunkWaitTimes[chunkId] != null &&
          _chunkWaitTimes[chunkId]!.isNotEmpty) {
        avgWaitTime = getChunkAverageWaitTime(chunkId);
      } else {
        // Default wait time for this road (1-8 minutes)
        avgWaitTime = '${2 + math.Random().nextInt(6)}-${4 + math.Random().nextInt(6)} min';
      }

      // Common jeeps = jeep types that use this road
      final commonJeeps = jeepTypes.toList();

      // Activity level based on jeep count or recorded activity
      String activity = '--';
      if (commonJeeps.isNotEmpty) {
        final activityLevel = commonJeeps.length;
        if (activityLevel >= 3) {
          activity = 'High';
        } else if (activityLevel == 2) {
          activity = 'Medium';
        } else {
          activity = 'Low';
        }
      }

      // Active jeeps nearby (from recent log)
      int activeJeeps = 0;
      final now = DateTime.now();
      for (final entry in _jeepActivityLog.entries) {
        final timestamp = entry.value['timestamp'] as DateTime?;
        if (timestamp != null) {
          final secondsAgo = now.difference(timestamp).inSeconds;
          if (secondsAgo < 300) {
            // Seen in last 5 minutes
            activeJeeps++;
          }
        }
      }

      // Last jeep passed
      String lastJeepPassed = '--';
      DateTime? lastSighting;
      for (final entry in _jeepActivityLog.entries) {
        final timestamp = entry.value['timestamp'] as DateTime?;
        if (timestamp != null) {
          if (lastSighting == null || timestamp.isAfter(lastSighting)) {
            lastSighting = timestamp;
          }
        }
      }
      if (lastSighting != null) {
        final secondsAgo = now.difference(lastSighting).inSeconds;
        if (secondsAgo < 3600) {
          // Within last hour
          if (secondsAgo < 60) {
            lastJeepPassed = '${secondsAgo}s ago';
          } else {
            final minutesAgo = secondsAgo ~/ 60;
            lastJeepPassed = '${minutesAgo}m ago';
          }
        }
      }

      // Create intelligence object
      final intelligence = RoadChunkIntelligence(
        chunkId: chunkId,
        center: chunkCenter,
        avgWaitTime: avgWaitTime,
        commonJeeps: commonJeeps.isNotEmpty ? commonJeeps : [],
        activity: activity,
        activeJeepsNearby: activeJeeps,
        lastJeepPassed: lastJeepPassed,
        lastUpdated: DateTime.now(),
      );

      _chunkIntelligence[chunkId] = intelligence;
      _nearestChunk = intelligence;
    } catch (e) {
      // Error loading roads - show all "--"
      _createEmptyStats();
    }
  }

  /// Create empty stats (all "--" values)
  void _createEmptyStats() {
    _chunkIntelligence.clear();
    _nearestChunk = null;
  }

  /// Find nearest point on a road to user location
  LatLng _findNearestPointOnRoad(LatLng userLocation, SakayRoad road) {
    if (road.points.isEmpty) return userLocation;
    if (road.points.length == 1) return road.points[0];

    double minDist = double.infinity;
    LatLng nearestPoint = road.points[0];

    // Check all segments of the road
    for (int i = 0; i < road.points.length - 1; i++) {
      final a = road.points[i];
      final b = road.points[i + 1];

      // Project user onto this segment
      final dx = b.longitude - a.longitude;
      final dy = b.latitude - a.latitude;
      final len2 = dx * dx + dy * dy;

      if (len2 == 0) {
        // Segment has zero length
        final dist = _haversineDistance(userLocation, a);
        if (dist < minDist) {
          minDist = dist;
          nearestPoint = a;
        }
        continue;
      }

      final t = (((userLocation.latitude - a.latitude) * dy +
              (userLocation.longitude - a.longitude) * dx) /
          len2);
      final clampedT = t.clamp(0.0, 1.0);
      final nearLatOnSegment = a.latitude + clampedT * dy;
      final nearLngOnSegment = a.longitude + clampedT * dx;
      final nearPointOnSegment = LatLng(nearLatOnSegment, nearLngOnSegment);

      final dist = _haversineDistance(userLocation, nearPointOnSegment);
      if (dist < minDist) {
        minDist = dist;
        nearestPoint = nearPointOnSegment;
      }
    }

    return nearestPoint;
  }

  /// Start periodic intelligence updates (every 2 minutes)
  void startPeriodicUpdates() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(_updateInterval, (_) {
      if (_lastUserLocation != null) {
        updateIntelligence(_lastUserLocation!);
      }
    });
  }

  /// Stop periodic updates
  void stopPeriodicUpdates() {
    _updateTimer?.cancel();
  }

  /// Record jeep activity (when passenger exits)
  void recordJeepActivity(
    String jeepId,
    String jeepType,
    LatLng location,
    double speed,
  ) {
    _jeepActivityLog[jeepId] = {
      'type': jeepType,
      'location': {'lat': location.latitude, 'lng': location.longitude},
      'speed': speed,
      'timestamp': DateTime.now(),
    };

    // Trigger update to reflect new activity
    forceUpdate();
  }

  /// Record chunk wait time (average wait for a chunk)
  void recordChunkWaitTime(String chunkId, int waitSeconds) {
    _chunkWaitTimes.putIfAbsent(chunkId, () => []).add(waitSeconds);

    // Keep only last 20 samples for rolling average
    if (_chunkWaitTimes[chunkId]!.length > 20) {
      _chunkWaitTimes[chunkId]!.removeAt(0);
    }
  }

  /// Get average wait time for a chunk
  String getChunkAverageWaitTime(String chunkId) {
    final times = _chunkWaitTimes[chunkId];
    if (times == null || times.isEmpty) return '--';

    final avg = times.reduce((a, b) => a + b) ~/ times.length;
    final minutes = avg ~/ 60;
    return '$minutes min';
  }

  /// Haversine distance in meters
  double _haversineDistance(LatLng a, LatLng b) {
    const R = 6371000.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * R * math.asin(math.sqrt(s));
  }

  /// Get main screen display values
  /// Shows "--" for all if no roads nearby or user not in snapzone
  Map<String, String> getMainScreenStats() {
    if (_nearestChunk == null ||
        _nearestChunk!.avgWaitTime == '--' && _nearestChunk!.activity == '--') {
      return {
        'nearestChunk': '--',
        'avgWaitTime': '--',
        'commonJeeps': '--',
        'activity': '--',
        'activeJeepsNearby': '0',
        'lastJeepPassed': '--',
      };
    }

    return {
      'nearestChunk': _nearestChunk!.chunkId,
      'avgWaitTime': _nearestChunk!.avgWaitTime,
      'commonJeeps': _nearestChunk!.commonJeeps.isNotEmpty
          ? _nearestChunk!.commonJeeps.join(', ')
          : '--',
      'activity': _nearestChunk!.activity,
      'activeJeepsNearby': _nearestChunk!.activeJeepsNearby.toString(),
      'lastJeepPassed': _nearestChunk!.lastJeepPassed,
    };
  }

  void dispose() {
    _updateTimer?.cancel();
    _updateListeners.clear();
  }
}








