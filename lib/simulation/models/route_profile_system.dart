import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'road_chunk.dart';
import 'road_graph.dart';

// ==============================
// 🚗 ROUTE PROFILE SYSTEM (NEW)
// ==============================
class JeepRouteProfile {
  JeepRouteProfile({
    required this.id,
    required this.name,
    required this.jeepType,
    required this.worldPath,
  }) {
    routeChunks = _buildRoadChunksFromPath(worldPath);
    roadGraph = RoadGraph.fromRouteChunks(
      chunks: routeChunks,
      isLoop: _isPathLoop(worldPath),
    );
  }

  final String id;
  final String name;
  final String jeepType;
  final List<Offset> worldPath;

  late List<RoadChunk> routeChunks;
  late RoadGraph roadGraph;

  // 📊 isolated analytics per jeep type
  final Map<int, double> chunkAccuracy = {};
  final Map<int, int> chunkSamples = {};

  static const double _chunkLengthMeters = 50.0;

  List<RoadChunk> _buildRoadChunksFromPath(List<Offset> path) {
    if (path.isEmpty) return <RoadChunk>[];

    final cumulativeLengths = <double>[0];
    for (int i = 0; i < path.length - 1; i++) {
      cumulativeLengths.add(
        cumulativeLengths.last + (path[i + 1] - path[i]).distance,
      );
    }
    final totalLength = cumulativeLengths.last;

    Offset pointAtProgress(double progress) {
      final target = progress.clamp(0.0, totalLength).toDouble();
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
    int id = 0;
    while (current < totalLength) {
      final next = math.min(totalLength, current + _chunkLengthMeters);
      chunks.add(
        RoadChunk(
          id: id,
          roadLabel: 'Route',
          indexInRoad: chunks.length + 1,
          startPoint: pointAtProgress(current),
          endPoint: pointAtProgress(next),
          lengthMeters: next - current,
          forwardDirectionLabel: '${_chunkCode(id)} -> ${_chunkCode(id + 1)}',
          reverseDirectionLabel: '${_chunkCode(id + 1)} -> ${_chunkCode(id)}',
        ),
      );
      current = next;
      id++;
    }
    return chunks;
  }

  String _chunkCode(int value) {
    return String.fromCharCode(65 + (value % 26));
  }

  bool _isPathLoop(List<Offset> path) {
    if (path.isEmpty) return false;
    return (path.first - path.last).distance < 0.001;
  }
}
