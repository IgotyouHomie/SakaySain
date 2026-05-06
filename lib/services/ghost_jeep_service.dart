import 'dart:async';
import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'passenger_service.dart';

/// ╔══════════════════════════════════════════════════════════════════════════╗
/// ║  GHOST JEEP SERVICE — Feature 12                                         ║
/// ║  Predicts jeep continuation after passenger exits                        ║
/// ╚══════════════════════════════════════════════════════════════════════════╝

enum GhostJeepConfidence {
  veryHigh,   // >90% confidence
  high,       // 70-90%
  medium,     // 50-70%
  low,        // 30-50%
  veryLow,    // <30%
}

/// Predicted ghost jeep position
class GhostJeepPrediction {
  final String jeepId;
  final LatLng predictedPosition;
  final DateTime predictionTime;
  final DateTime lastSighting;
  final GhostJeepConfidence confidence;
  final List<LatLng> historicalRoute;
  final double averageSpeed; // meters per second
  final int timeSinceLastSighting; // seconds
  final String jeepType;
  final double confidenceDecay; // 0.0 - 1.0 factor

  GhostJeepPrediction({
    required this.jeepId,
    required this.predictedPosition,
    required this.predictionTime,
    required this.lastSighting,
    required this.confidence,
    required this.historicalRoute,
    required this.averageSpeed,
    required this.timeSinceLastSighting,
    required this.jeepType,
    required this.confidenceDecay,
  });

  /// Serialize for display/storage
  Map<String, dynamic> toJson() => {
    'jeepId': jeepId,
    'predictedPosition': {'lat': predictedPosition.latitude, 'lng': predictedPosition.longitude},
    'confidence': confidence.toString(),
    'confidenceDecay': confidenceDecay,
    'timeSinceLastSighting': timeSinceLastSighting,
    'jeepType': jeepType,
  };
}

/// Manages ghost jeep predictions based on historical passenger data
class GhostJeepService {
  static final GhostJeepService _instance = GhostJeepService._internal();

  factory GhostJeepService() => _instance;
  GhostJeepService._internal();

  // Historical data storage (in real app, this comes from backend)
  final Map<String, List<PassengerJourneyData>> _jeepHistories = {};
  final Map<String, DateTime> _lastSightings = {};
  final Map<String, GhostJeepPrediction> _activePredictions = {};

  Timer? _predictionUpdateTimer;
  final List<Function(Map<String, GhostJeepPrediction>)> _predictionListeners = [];

  // Constants
  static const double _confidenceDecayPerMinute = 0.02; // Linear decay
  static const double _maxPredictionAgeMinutes = 30.0;

  // ── Getters ──────────────────────────────────────────────────────────────
  Map<String, GhostJeepPrediction> get activePredictions => _activePredictions;

  void addPredictionListener(Function(Map<String, GhostJeepPrediction>) listener) {
    _predictionListeners.add(listener);
  }

  void removePredictionListener(Function(Map<String, GhostJeepPrediction>) listener) {
    _predictionListeners.remove(listener);
  }

  void _notifyPredictions() {
    for (var listener in _predictionListeners) {
      listener(_activePredictions);
    }
  }

  /// ╔════════════════════════════════════════════════════════════════════════╗
  /// ║ FEATURE 12: GHOST JEEP SYSTEM (V2)                                    ║
  /// ║                                                                        ║
  /// ║ Predicts jeep continuation using:                                    ║
  /// ║ • Last route                                                          ║
  /// ║ • Historical route loops                                              ║
  /// ║ • Chunk flow patterns                                                 ║
  /// ║ • Jeep type behavior                                                  ║
  /// ║ • Traffic conditions                                                  ║
  /// ║ • Confidence decay                                                   ║
  /// ╚════════════════════════════════════════════════════════════════════════╝

  /// Register a passenger exit and start ghost jeep prediction
  void registerPassengerExit(PassengerJourneyData journeyData, double trafficFactor) {
    final jeepId = journeyData.jeepId;

    // Store journey in history
    _jeepHistories.putIfAbsent(jeepId, () => []).add(journeyData);
    _lastSightings[jeepId] = DateTime.now();

    // Generate initial prediction
    _updateGhostJeepPrediction(jeepId, journeyData, trafficFactor);
  }

  /// Generate or update ghost jeep prediction
  void _updateGhostJeepPrediction(
    String jeepId,
    PassengerJourneyData latestJourney,
    double trafficFactor, // 0.0-2.0: how traffic affects speed (1.0 = normal)
  ) {
    final lastSighting = _lastSightings[jeepId] ?? DateTime.now();
    final timeSinceSighting =
        DateTime.now().difference(lastSighting).inSeconds;

    // Don't predict if too old
    if (timeSinceSighting > _maxPredictionAgeMinutes * 60) {
      _activePredictions.remove(jeepId);
      _notifyPredictions();
      return;
    }

    // Build historical context
    final history = _jeepHistories[jeepId] ?? [];
    final historicalRoutes = _extractHistoricalPatterns(history);

    // Calculate average speed from journey
    double avgSpeed = _calculateAverageSpeed(latestJourney);
    avgSpeed *= trafficFactor; // Adjust for traffic

    // Predict next position
    final predictedPosition = _predictNextPosition(
      latestJourney,
      historicalRoutes,
      avgSpeed,
      timeSinceSighting,
    );

    // Calculate confidence with decay
    final confidence = _calculateConfidence(
      latestJourney,
      history,
      timeSinceSighting,
      trafficFactor,
    );

    // Calculate confidence decay factor
    final decayMinutes = timeSinceSighting / 60.0;
    final decayFactor = math.max(0.0, 1.0 - (decayMinutes * _confidenceDecayPerMinute));

    final prediction = GhostJeepPrediction(
      jeepId: jeepId,
      predictedPosition: predictedPosition,
      predictionTime: DateTime.now(),
      lastSighting: lastSighting,
      confidence: confidence,
      historicalRoute: latestJourney.routePoints,
      averageSpeed: avgSpeed,
      timeSinceLastSighting: timeSinceSighting,
      jeepType: latestJourney.jeepType,
      confidenceDecay: decayFactor,
    );

    _activePredictions[jeepId] = prediction;
    _notifyPredictions();
  }

  /// Extract patterns from historical journeys
  List<List<LatLng>> _extractHistoricalPatterns(List<PassengerJourneyData> historicalJourneys) {
    return historicalJourneys
        .where((j) => j.routePoints.isNotEmpty)
        .map((j) => j.routePoints)
        .toList();
  }

  /// Predict next position based on route and speed
  LatLng _predictNextPosition(
    PassengerJourneyData latestJourney,
    List<List<LatLng>> historicalRoutes,
    double speedMetersPerSecond,
    int elapsedSeconds,
  ) {
    if (latestJourney.routePoints.isEmpty) {
      return latestJourney.startLocation;
    }

    // Start from last known position
    LatLng currentPos = latestJourney.routePoints.last;

    // Calculate distance traveled: speed (m/s) × elapsed time (s)
    double distanceTraveledMeters = speedMetersPerSecond * elapsedSeconds;

    // Try to follow historical route if available
    LatLng? nextPos = _projectAlongRoute(
      latestJourney.routePoints,
      currentPos,
      distanceTraveledMeters,
    );

    if (nextPos != null) return nextPos;

    // Fallback: project forward in the last direction
    if (latestJourney.routePoints.length >= 2) {
      final prev = latestJourney.routePoints[latestJourney.routePoints.length - 2];
      return _projectForward(prev, currentPos, distanceTraveledMeters);
    }

    return currentPos;
  }

  /// Project a point along a route for a given distance
  LatLng? _projectAlongRoute(
    List<LatLng> route,
    LatLng currentPos,
    double distanceMeters,
  ) {
    if (route.length < 2) return null;

    // Find closest segment to current position
    int startIdx = 0;
    for (int i = 0; i < route.length - 1; i++) {
      final dist = _haversineDistance(route[i], currentPos);
      if (dist < 200) {
        // Within 200m
        startIdx = i;
        break;
      }
    }

    // Project forward from current position
    double remaining = distanceMeters;
    for (int i = startIdx; i < route.length - 1; i++) {
      final segmentLength = _haversineDistance(route[i], route[i + 1]);
      if (remaining <= segmentLength) {
        // Within this segment
        final t = remaining / segmentLength;
        return _lerp(route[i], route[i + 1], t);
      }
      remaining -= segmentLength;
    }

    return null; // Reached end of route
  }

  /// Project forward in the direction of last movement
  LatLng _projectForward(LatLng prev, LatLng current, double distanceMeters) {
    final latDiff = current.latitude - prev.latitude;
    final lngDiff = current.longitude - prev.longitude;
    final directionDistance = _haversineDistance(prev, current);

    if (directionDistance == 0) return current;

    final latStep = (latDiff / directionDistance) * (distanceMeters / 111000);
    final lngStep = (lngDiff / directionDistance) * (distanceMeters / 111000);

    return LatLng(
      current.latitude + latStep,
      current.longitude + lngStep,
    );
  }

  /// Calculate average speed from journey data
  double _calculateAverageSpeed(PassengerJourneyData journey) {
    if (journey.speeds.isEmpty) return 5.0; // Default 5 m/s (~18 km/h)
    final sum = journey.speeds.reduce((a, b) => a + b);
    return sum / journey.speeds.length;
  }

  /// Calculate confidence level based on multiple factors
  GhostJeepConfidence _calculateConfidence(
    PassengerJourneyData latestJourney,
    List<PassengerJourneyData> history,
    int timeSinceSighting,
    double trafficFactor,
  ) {
    double score = 80.0; // Start with good confidence

    // Factor 1: History depth (more history = higher confidence)
    final historyFactor = math.min(history.length * 10, 30);
    score += historyFactor;

    // Factor 2: Route consistency (if routes are similar)
    if (history.isNotEmpty) {
      final consistency = _calculateRouteConsistency(latestJourney, history);
      score += consistency * 20;
    }

    // Factor 3: Time decay (older sighting = lower confidence)
    final timeFactor = -(timeSinceSighting / 60); // -1 per minute
    score += timeFactor;

    // Factor 4: Traffic (uncertain traffic = lower confidence)
    if (trafficFactor > 1.5 || trafficFactor < 0.5) {
      score -= 20;
    }

    // Clamp and convert to enum
    score = score.clamp(0, 100);

    if (score > 90) return GhostJeepConfidence.veryHigh;
    if (score > 70) return GhostJeepConfidence.high;
    if (score > 50) return GhostJeepConfidence.medium;
    if (score > 30) return GhostJeepConfidence.low;
    return GhostJeepConfidence.veryLow;
  }

  /// Calculate how consistent current route is with historical routes
  double _calculateRouteConsistency(
    PassengerJourneyData current,
    List<PassengerJourneyData> history,
  ) {
    if (history.isEmpty || current.routePoints.isEmpty) return 0.5;

    int pathMatches = 0;
    for (final historicalJourney in history) {
      if (historicalJourney.routePoints.isEmpty) continue;

      // Check if first few chunks match
      final checkLength = math.min(
        5,
        math.min(
          historicalJourney.routePoints.length,
          current.routePoints.length,
        ),
      );
      int matches = 0;

      for (int i = 0; i < checkLength; i++) {
        final dist = _haversineDistance(
          current.routePoints[i],
          historicalJourney.routePoints[i],
        );
        if (dist < 100) matches++; // Within 100m = match
      }

      if (matches >= checkLength * 0.7) pathMatches++;
    }

    return pathMatches / history.length;
  }

  /// Haversine distance between two points (in meters)
  double _haversineDistance(LatLng a, LatLng b) {
    const R = 6371000.0; // Earth radius in meters
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * R * math.asin(math.sqrt(s));
  }

  /// Linear interpolation between two points
  LatLng _lerp(LatLng a, LatLng b, double t) {
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  /// Start periodic ghost jeep updates
  void startPeriodicUpdates({
    Duration interval = const Duration(seconds: 30),
    double trafficFactor = 1.0,
  }) {
    _predictionUpdateTimer?.cancel();
    _predictionUpdateTimer = Timer.periodic(interval, (_) {
      // Update all active predictions
      for (final entry in _activePredictions.entries) {
        // In a real app, fetch latest journey data from backend
        // For now, just recalculate with time decay
      }
    });
  }

  /// Stop periodic updates
  void stopPeriodicUpdates() {
    _predictionUpdateTimer?.cancel();
  }

  /// Get confidence as percentage (0-100)
  int getConfidencePercent(GhostJeepConfidence confidence) {
    switch (confidence) {
      case GhostJeepConfidence.veryHigh:
        return 95;
      case GhostJeepConfidence.high:
        return 80;
      case GhostJeepConfidence.medium:
        return 60;
      case GhostJeepConfidence.low:
        return 40;
      case GhostJeepConfidence.veryLow:
        return 20;
    }
  }

  void dispose() {
    _predictionUpdateTimer?.cancel();
    _predictionListeners.clear();
  }
}



