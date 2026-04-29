import 'package:flutter/material.dart';

import 'road_direction.dart';

class GhostJeep {
  GhostJeep({
    required this.sourceUserId,
    required this.jeepType,
    required this.currentChunkId,
    required this.direction,
    required this.avgSpeed,
    required this.expectedNextChunkTime,
    required this.lastChunkTransitionAt,
    required this.confidence,
  });

  final int sourceUserId;
  final String jeepType;
  int currentChunkId;
  RoadDirection direction;
  double avgSpeed;
  DateTime expectedNextChunkTime;
  DateTime lastChunkTransitionAt;
  double confidence;

  Offset position = Offset.zero;
}
