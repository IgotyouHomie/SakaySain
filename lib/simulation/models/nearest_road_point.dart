import 'package:flutter/material.dart';

class NearestRoadPoint {
  const NearestRoadPoint({
    required this.point,
    required this.roadIndex,
    required this.segmentIndex,
    required this.t,
    required this.chunkId,
    required this.distanceToRoad,
  });

  final Offset point;
  final int roadIndex;
  final int segmentIndex;
  final double t;
  final int chunkId;
  final double distanceToRoad;
}
