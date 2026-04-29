import 'package:flutter/material.dart';

import 'road_direction.dart';

enum RoadChunkEventType {
  jeepEnterChunk,
  jeepExitChunk,
  passengerBecameJeep,
  passengerDisconnected,
  ghostJeepCreated,
}

class RoadChunkEvent {
  const RoadChunkEvent({
    required this.type,
    required this.timestamp,
    this.userId,
    this.chunkId,
    this.jeepType,
    this.direction,
    this.observed = true,
    this.travelTimeSeconds,
    this.position,
  });

  final RoadChunkEventType type;
  final DateTime timestamp;
  final int? userId;
  final int? chunkId;
  final String? jeepType;
  final RoadDirection? direction;
  final bool observed;
  final double? travelTimeSeconds;
  final Offset? position;
}
