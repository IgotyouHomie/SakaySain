import 'package:flutter/material.dart';

import 'road_chunk.dart';
import 'road_direction.dart';
import 'chunk_connection.dart';

class RoadGraphTransition {
  const RoadGraphTransition({
    required this.nextChunkId,
    required this.nextDirection,
    required this.viaNodeId,
  });

  final int nextChunkId;
  final RoadDirection nextDirection;
  final int viaNodeId;
}

class RoadGraphEdge {
  const RoadGraphEdge({
    required this.chunkId,
    required this.startNodeId,
    required this.endNodeId,
  });

  final int chunkId;
  final int startNodeId;
  final int endNodeId;
}

class RoadGraph {
  RoadGraph._({
    required this.edgesByChunkId,
    required this.nodesById,
    required this.adjacentEdgesByNode,
    required this.outgoingByNode,
    required this.incomingByNode,
    required this.isLoop,
    required this.forkConnectionsByChunkId,
  });

  final Map<int, RoadGraphEdge> edgesByChunkId;
  final Map<int, Offset> nodesById;
  final Map<int, List<RoadGraphEdge>> adjacentEdgesByNode;
  final Map<int, List<RoadGraphEdge>> outgoingByNode;
  final Map<int, List<RoadGraphEdge>> incomingByNode;
  final bool isLoop;
  // Map from chunk ID to list of explicitly connected target chunks (forks)
  final Map<int, List<int>> forkConnectionsByChunkId;

  factory RoadGraph.fromRouteChunks({
    required List<RoadChunk> chunks,
    required bool isLoop,
  }) {
    final edgesByChunkId = <int, RoadGraphEdge>{};
    final nodesById = <int, Offset>{};
    final adjacentByNode = <int, List<RoadGraphEdge>>{};
    final outgoingByNode = <int, List<RoadGraphEdge>>{};
    final incomingByNode = <int, List<RoadGraphEdge>>{};
    final nodeIdsByKey = <String, int>{};
    var nextNodeId = 0;

    int nodeIdForPoint(Offset point) {
      final key = _pointKey(point);
      final existing = nodeIdsByKey[key];
      if (existing != null) {
        return existing;
      }
      final id = nextNodeId;
      nextNodeId += 1;
      nodeIdsByKey[key] = id;
      nodesById[id] = point;
      return id;
    }

    for (int i = 0; i < chunks.length; i++) {
      final startNode = nodeIdForPoint(chunks[i].startPoint);
      final endNode = nodeIdForPoint(chunks[i].endPoint);
      final edge = RoadGraphEdge(
        chunkId: chunks[i].id,
        startNodeId: startNode,
        endNodeId: endNode,
      );
      edgesByChunkId[edge.chunkId] = edge;
      adjacentByNode.putIfAbsent(startNode, () => <RoadGraphEdge>[]).add(edge);
      adjacentByNode.putIfAbsent(endNode, () => <RoadGraphEdge>[]).add(edge);
      outgoingByNode
          .putIfAbsent(edge.startNodeId, () => <RoadGraphEdge>[])
          .add(edge);
      incomingByNode
          .putIfAbsent(edge.endNodeId, () => <RoadGraphEdge>[])
          .add(edge);
    }

    return RoadGraph._(
      edgesByChunkId: edgesByChunkId,
      nodesById: nodesById,
      adjacentEdgesByNode: adjacentByNode,
      outgoingByNode: outgoingByNode,
      incomingByNode: incomingByNode,
      isLoop: isLoop,
      forkConnectionsByChunkId: {}, // No forks in basic graph
    );
  }

  /// Build a road graph from chunks and explicit fork connections.
  /// Forks are explicit edges between chunks that override the default
  /// line-based connectivity.
  factory RoadGraph.withForks({
    required List<RoadChunk> chunks,
    required List<ChunkConnection> connections,
    required bool isLoop,
  }) {
    // First, build the base graph without forks
    final edgesByChunkId = <int, RoadGraphEdge>{};
    final nodesById = <int, Offset>{};
    final adjacentByNode = <int, List<RoadGraphEdge>>{};
    final outgoingByNode = <int, List<RoadGraphEdge>>{};
    final incomingByNode = <int, List<RoadGraphEdge>>{};
    final nodeIdsByKey = <String, int>{};
    var nextNodeId = 0;

    int nodeIdForPoint(Offset point) {
      final key = _pointKey(point);
      final existing = nodeIdsByKey[key];
      if (existing != null) {
        return existing;
      }
      final id = nextNodeId;
      nextNodeId += 1;
      nodeIdsByKey[key] = id;
      nodesById[id] = point;
      return id;
    }

    for (int i = 0; i < chunks.length; i++) {
      final startNode = nodeIdForPoint(chunks[i].startPoint);
      final endNode = nodeIdForPoint(chunks[i].endPoint);
      final edge = RoadGraphEdge(
        chunkId: chunks[i].id,
        startNodeId: startNode,
        endNodeId: endNode,
      );
      edgesByChunkId[edge.chunkId] = edge;
      adjacentByNode.putIfAbsent(startNode, () => <RoadGraphEdge>[]).add(edge);
      adjacentByNode.putIfAbsent(endNode, () => <RoadGraphEdge>[]).add(edge);
      outgoingByNode
          .putIfAbsent(edge.startNodeId, () => <RoadGraphEdge>[])
          .add(edge);
      incomingByNode
          .putIfAbsent(edge.endNodeId, () => <RoadGraphEdge>[])
          .add(edge);
    }

    // Build fork connections map
    final forkConnectionsByChunkId = <int, List<int>>{};
    for (final connection in connections) {
      forkConnectionsByChunkId
          .putIfAbsent(connection.fromChunkId, () => <int>[])
          .add(connection.toChunkId);
    }

    return RoadGraph._(
      edgesByChunkId: edgesByChunkId,
      nodesById: nodesById,
      adjacentEdgesByNode: adjacentByNode,
      outgoingByNode: outgoingByNode,
      incomingByNode: incomingByNode,
      isLoop: isLoop,
      forkConnectionsByChunkId: forkConnectionsByChunkId,
    );
  }

  /// Check if a chunk has explicit fork connections (multiple outgoing paths).
  bool hasFork(int chunkId) {
    final forks = forkConnectionsByChunkId[chunkId];
    return forks != null && forks.length > 1;
  }

  /// Get all possible next chunks at a fork point.
  /// Returns the list of fork destinations if this chunk has forks,
  /// otherwise returns the default next chunk as a single-item list.
  List<int> getNextChunksAtFork({
    required int currentChunkId,
    required RoadDirection direction,
  }) {
    final forks = forkConnectionsByChunkId[currentChunkId];
    if (forks != null && forks.isNotEmpty) {
      return List<int>.from(forks); // Return all fork destinations
    }

    // No explicit forks, use default logic
    final next = nextChunkId(
      currentChunkId: currentChunkId,
      direction: direction,
    );
    return next != null ? [next] : [];
  }

  List<RoadGraphTransition> candidateTransitions({
    required int currentChunkId,
    required RoadDirection currentDirection,
  }) {
    final edge = edgesByChunkId[currentChunkId];
    if (edge == null) {
      return const <RoadGraphTransition>[];
    }

    final pivotNodeId = currentDirection == RoadDirection.forward
        ? edge.endNodeId
        : edge.startNodeId;

    final adjacent =
        adjacentEdgesByNode[pivotNodeId] ?? const <RoadGraphEdge>[];
    final transitions = <RoadGraphTransition>[];

    for (final candidate in adjacent) {
      if (candidate.chunkId == currentChunkId) {
        continue;
      }

      final direction = candidate.startNodeId == pivotNodeId
          ? RoadDirection.forward
          : RoadDirection.backward;
      transitions.add(
        RoadGraphTransition(
          nextChunkId: candidate.chunkId,
          nextDirection: direction,
          viaNodeId: pivotNodeId,
        ),
      );
    }

    transitions.sort((a, b) => a.nextChunkId.compareTo(b.nextChunkId));
    return transitions;
  }

  int? nextChunkId({
    required int currentChunkId,
    required RoadDirection direction,
  }) {
    final transitions = candidateTransitions(
      currentChunkId: currentChunkId,
      currentDirection: direction,
    );
    if (transitions.isEmpty) {
      if (!isLoop) {
        return null;
      }
      if (direction == RoadDirection.forward) {
        final firstChunkId = edgesByChunkId.keys.isEmpty
            ? null
            : edgesByChunkId.keys.reduce((a, b) => a < b ? a : b);
        return firstChunkId;
      }
      final lastChunkId = edgesByChunkId.keys.isEmpty
          ? null
          : edgesByChunkId.keys.reduce((a, b) => a > b ? a : b);
      return lastChunkId;
    }

    return transitions.first.nextChunkId;
  }

  static String _pointKey(Offset point) {
    final x = point.dx.toStringAsFixed(3);
    final y = point.dy.toStringAsFixed(3);
    return '$x|$y';
  }
}
