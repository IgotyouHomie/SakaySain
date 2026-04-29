import 'package:flutter/material.dart';

class User {
  User({
    required this.id,
    required this.position,
    required this.speed,
    required this.direction,
    required this.visibilityRadius,
    required this.jeepType,
    List<Offset>? trailPositions,
    this.isPhoneUser = false,
    this.isMockUser = true,
  }) : trailPositions = trailPositions ?? <Offset>[];

  static const double movementThreshold = 30;

  final int id;
  Offset position;
  double speed;
  Offset direction;
  double visibilityRadius;
  final String jeepType;
  final List<Offset> trailPositions;
  final bool isPhoneUser;
  final bool isMockUser;

  bool get isMoving => speed >= movementThreshold;
}
