import 'package:flutter/material.dart';

class TrafficZone {
  const TrafficZone({
    required this.chunkId,
    required this.slowdownMultiplier,
    required this.start,
    required this.end,
  });

  final int chunkId;
  final double slowdownMultiplier;
  final Offset start;
  final Offset end;
}
