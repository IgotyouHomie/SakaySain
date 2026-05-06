import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../screens/road_persistence_service.dart';
import '../simulation/models/road_chunk.dart';
import '../simulation/models/road_direction.dart';
import '../simulation/models/road_graph.dart';
import '../simulation/models/tracked_eta.dart';

/// ╔══════════════════════════════════════════════════════════════════════════╗
/// ║  ROAD NETWORK ENGINE — Exposes buried simulation intelligence to UI      ║
/// ║  Bridges the gap between main screens and simulation models              ║
/// ╚══════════════════════════════════════════════════════════════════════════╝
///
/// Provides:
/// • Road network graph + chunk connectivity
/// • Snapzone validation (is user near a valid road chunk?)
/// • Waiting pin snapping (nearest safe point on road)
/// • Chunk statistics (arrival intervals, travel times, confidence)
/// • ETA predictions (hybrid: real-time + historical + traffic)
/// • Ghost jeep continuation (when real data unavailable)

class RoadNetworkEngine {
  RoadNetworkEngine._();

  static const double _snapzoneMeterRadius = 30.0;
  static const double _chunkLengthMeters = 50.0;
  static const double _metersPerLatLngDegree = 111000.0;

  // ══════════════════════════════════════════════════════════════════════════
  // ROAD NETWORK INITIALIZATION
  // ══════════════════════════════════════════════════════════════════════════

  /// Builds a complete road network from persisted roads.
  /// Returns (roadChunksByRoadId, roadGraphsByRoadId, allChunks)
  static Future<
    ({
      Map<String, List<RoadChunk>> chunksByRoadId,
      Map<String, RoadGraph> graphsByRoadId,
      List<RoadChunk> allChunks,
    })
  >
  buildRoadNetwork() async {
    final roads = await RoadPersistenceService.loadRoads();
    final chunkConnections =
        await RoadPersistenceService.loadChunkConnections();
    final chunksByRoadId = <String, List<RoadChunk>>{};
    final graphsByRoadId = <String, RoadGraph>{};
    final allChunks = <RoadChunk>[];

    int globalChunkId = 0;
    for (final road in roads) {
      if (road.points.isEmpty) continue;

      // Convert LatLng points to Offset (cartesian-ish for chunk building)
      final worldPath = road.points
          .map((latLng) => Offset(latLng.latitude, latLng.longitude))
          .toList();

      final chunks = _buildChunksFromPath(worldPath, globalChunkId, road.name);
      chunksByRoadId[road.id] = chunks;
      allChunks.addAll(chunks);

      // Filter connections for this road
      final roadConnections = chunkConnections
          .where((conn) => conn.roadId == road.id)
          .toList();

      // Build road graph for connectivity (with fork support)
      final graph = RoadGraph.withForks(
        chunks: chunks,
        connections: roadConnections,
        isLoop: _isPathLoop(worldPath),
      );
      graphsByRoadId[road.id] = graph;

      globalChunkId += chunks.length;
    }

    return (
      chunksByRoadId: chunksByRoadId,
      graphsByRoadId: graphsByRoadId,
      allChunks: allChunks,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SNAPZONE VALIDATION
  // ══════════════════════════════════════════════════════════════════════════

  /// Checks if user is within snapzone radius of any chunk.
  /// Returns (chunk, distanceMeters) or null if not in any snapzone.
  static ({RoadChunk chunk, double distanceMeters})? findUserSnapzoneChunk(
    LatLng userLatLng,
    List<RoadChunk> allChunks,
  ) {
    ({RoadChunk chunk, double distanceMeters})? nearest;
    double minDist = _snapzoneMeterRadius;

    for (final chunk in allChunks) {
      final chunkMidpoint = Offset(
        (chunk.startPoint.dx + chunk.endPoint.dx) / 2,
        (chunk.startPoint.dy + chunk.endPoint.dy) / 2,
      );

      final userOffset = Offset(userLatLng.latitude, userLatLng.longitude);
      final distLatLngDegrees = (userOffset - chunkMidpoint).distance;
      final distMeters = distLatLngDegrees * _metersPerLatLngDegree;

      if (distMeters < minDist) {
        minDist = distMeters;
        nearest = (chunk: chunk, distanceMeters: distMeters);
      }
    }

    return nearest;
  }

  /// Find nearest road segment to user (projects user onto all road segments).
  /// Returns (chunk, distanceMeters, direction) or null.
  static ({RoadChunk chunk, double distanceMeters, RoadDirection direction})?
  findNearestRoadForUser(LatLng userLatLng, List<RoadChunk> allChunks) {
    ({RoadChunk chunk, double distanceMeters, RoadDirection direction})?
    nearest;
    double minDist = double.infinity;

    final userOffset = Offset(userLatLng.latitude, userLatLng.longitude);

    for (final chunk in allChunks) {
      // Project user onto this chunk segment
      final projectedPoint = _projectPointOntoSegment(
        userOffset,
        chunk.startPoint,
        chunk.endPoint,
      );
      final dist = (userOffset - projectedPoint).distance;

      if (dist < minDist) {
        minDist = dist;
        // Determine direction: forward if closer to end, else backward
        final startDist = (userOffset - chunk.startPoint).distance;
        final endDist = (userOffset - chunk.endPoint).distance;
        final direction = endDist < startDist
            ? RoadDirection.forward
            : RoadDirection.backward;

        nearest = (
          chunk: chunk,
          distanceMeters: dist * _metersPerLatLngDegree,
          direction: direction,
        );
      }
    }

    return nearest;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // WAITING PIN SNAPPING
  // ══════════════════════════════════════════════════════════════════════════

  /// Snaps a position to the nearest safe point on a road chunk.
  /// Returns LatLng on the road segment closest to the input position.
  static LatLng snapWaitingPinToRoad(LatLng position, RoadChunk chunk) {
    final userOffset = Offset(position.latitude, position.longitude);
    final snappedOffset = _projectPointOntoSegment(
      userOffset,
      chunk.startPoint,
      chunk.endPoint,
    );
    return LatLng(snappedOffset.dx, snappedOffset.dy);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CHUNK STATISTICS & QUERIES
  // ══════════════════════════════════════════════════════════════════════════

  /// Get display-ready chunk statistics.
  static ChunkStats getChunkStats(RoadChunk chunk) {
    return ChunkStats(
      chunkId: chunk.id,
      label: chunk.label,
      avgArrivalIntervalSeconds: chunk.avgArrivalIntervalAll,
      lastJeepPassTime: chunk.lastJeepPassTime,
      observedPassCount: chunk.observedPassCount,
      speculativePassCount: chunk.speculativePassCount,
      forwardAvgTravelTimeSeconds: chunk.forwardAvgTravelTime,
      backwardAvgTravelTimeSeconds: chunk.backwardAvgTravelTime,
      flowRatePerMinute: chunk.flowRateJeepsPerMinute,
      jeepTypeStats: _buildJeepTypeStats(chunk),
    );
  }

  static Map<String, JeepTypeStats> _buildJeepTypeStats(RoadChunk chunk) {
    final stats = <String, JeepTypeStats>{};
    for (final jeepType in chunk.jeepTypePassEvents.keys) {
      final events = chunk.jeepTypePassEvents[jeepType] ?? [];
      final avgInterval = chunk.avgArrivalIntervalByType[jeepType] ?? 0;
      final avgTravel = chunk.avgTravelTimeByType[jeepType] ?? 0;
      stats[jeepType] = JeepTypeStats(
        jeepType: jeepType,
        passCount: events.length,
        avgArrivalIntervalSeconds: avgInterval,
        avgTravelTimeSeconds: avgTravel,
      );
    }
    return stats;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ETA PREDICTION ENGINE (Hybrid: Real-time + Historical + Ghost)
  // ══════════════════════════════════════════════════════════════════════════

  /// Predict ETA for a jeep to reach a destination chunk from a starting chunk.
  /// Uses:
  /// • Historical travel times per chunk (from chunk statistics)
  /// • Traffic slowdown multiplier
  /// • Ghost jeep continuation (when real data unavailable)
  /// • Confidence scoring
  static TrackedEta predictEta({
    required RoadChunk fromChunk,
    required RoadChunk toChunk,
    required List<RoadChunk> pathChunks,
    required String jeepType,
    required double trafficSlowdownFactor,
    required RoadDirection direction,
  }) {
    double totalSeconds = 0;
    double confidence = 100;
    int chunksSampled = 0;

    // Sum travel times along the path
    for (final chunk in pathChunks) {
      final travelSec = direction == RoadDirection.forward
          ? chunk.forwardAvgTravelTime
          : chunk.backwardAvgTravelTime;

      if (travelSec > 0) {
        totalSeconds += travelSec * trafficSlowdownFactor;
        chunksSampled++;
      } else {
        // Ghost jeep: assume average chunk speed if no data
        totalSeconds += (_chunkLengthMeters / 15) * trafficSlowdownFactor;
        confidence *= 0.8; // reduce confidence for unmeasured chunks
      }
    }

    // Clamp confidence 0–100
    confidence = confidence.clamp(0, 100);

    return TrackedEta(
      userId: 0, // placeholder
      jeepType: jeepType,
      etaSeconds: totalSeconds,
      confidencePercent: confidence,
      distanceMeters: pathChunks.length * _chunkLengthMeters,
      trafficFactor: trafficSlowdownFactor,
      isGhost: confidence < 50,
      predictionSource: 'Historical',
      predictionMethod: 'ChunkAverages',
      confidenceLabel: _confidenceLabel(confidence),
      predictionMinSeconds: totalSeconds * 0.8,
      predictionMaxSeconds: totalSeconds * 1.2,
      predictionAgeSeconds: 0,
    );
  }

  static String _confidenceLabel(double confidence) {
    if (confidence >= 80) return 'HIGH';
    if (confidence >= 50) return 'MEDIUM';
    return 'LOW';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UTILITY GEOMETRY
  // ══════════════════════════════════════════════════════════════════════════

  static List<RoadChunk> _buildChunksFromPath(
    List<Offset> path,
    int startingChunkId,
    String roadLabel,
  ) {
    if (path.isEmpty) return [];

    final cumulativeLengths = <double>[0];
    for (int i = 0; i < path.length - 1; i++) {
      cumulativeLengths.add(
        cumulativeLengths.last + (path[i + 1] - path[i]).distance,
      );
    }
    final totalLength = cumulativeLengths.last;

    Offset pointAtProgress(double progress) {
      final target = progress.clamp(0, totalLength).toDouble();
      for (int i = 0; i < path.length - 1; i++) {
        final segStart = cumulativeLengths[i];
        final segEnd = cumulativeLengths[i + 1];
        if (target <= segEnd || i == path.length - 2) {
          final segLength = (segEnd - segStart).clamp(0.0001, double.infinity);
          final t = ((target - segStart) / segLength).clamp(0.0, 1.0);
          return Offset.lerp(path[i], path[i + 1], t)!;
        }
      }
      return path.last;
    }

    final chunks = <RoadChunk>[];
    double current = 0;
    int id = startingChunkId;
    while (current < totalLength) {
      final next = math.min(totalLength, current + _chunkLengthMeters);
      chunks.add(
        RoadChunk(
          id: id,
          roadLabel: roadLabel,
          indexInRoad: chunks.length + 1,
          startPoint: pointAtProgress(current),
          endPoint: pointAtProgress(next),
          lengthMeters: next - current,
          forwardDirectionLabel:
              '$roadLabel-${chunks.length + 1} → $roadLabel-${chunks.length + 2}',
          reverseDirectionLabel:
              '$roadLabel-${chunks.length + 2} → $roadLabel-${chunks.length + 1}',
        ),
      );
      current = next;
      id++;
    }
    return chunks;
  }

  static bool _isPathLoop(List<Offset> path) {
    if (path.isEmpty) return false;
    return (path.first - path.last).distance < 0.001;
  }

  static Offset _projectPointOntoSegment(
    Offset point,
    Offset segStart,
    Offset segEnd,
  ) {
    final dx = segEnd.dx - segStart.dx;
    final dy = segEnd.dy - segStart.dy;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) return segStart;

    final t =
        (((point.dx - segStart.dx) * dx + (point.dy - segStart.dy) * dy) / len2)
            .clamp(0.0, 1.0);
    return Offset(segStart.dx + t * dx, segStart.dy + t * dy);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// DATA MODELS FOR UI CONSUMPTION
// ═══════════════════════════════════════════════════════════════════════════

class ChunkStats {
  const ChunkStats({
    required this.chunkId,
    required this.label,
    required this.avgArrivalIntervalSeconds,
    required this.lastJeepPassTime,
    required this.observedPassCount,
    required this.speculativePassCount,
    required this.forwardAvgTravelTimeSeconds,
    required this.backwardAvgTravelTimeSeconds,
    required this.flowRatePerMinute,
    required this.jeepTypeStats,
  });

  final int chunkId;
  final String label;
  final double avgArrivalIntervalSeconds;
  final DateTime? lastJeepPassTime;
  final int observedPassCount;
  final int speculativePassCount;
  final double forwardAvgTravelTimeSeconds;
  final double backwardAvgTravelTimeSeconds;
  final double flowRatePerMinute;
  final Map<String, JeepTypeStats> jeepTypeStats;
}

class JeepTypeStats {
  const JeepTypeStats({
    required this.jeepType,
    required this.passCount,
    required this.avgArrivalIntervalSeconds,
    required this.avgTravelTimeSeconds,
  });

  final String jeepType;
  final int passCount;
  final double avgArrivalIntervalSeconds;
  final double avgTravelTimeSeconds;
}
