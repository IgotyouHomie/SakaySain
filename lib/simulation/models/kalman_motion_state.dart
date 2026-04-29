import 'package:flutter/material.dart';

class KalmanMotionState {
  KalmanMotionState({
    required this.position,
    required this.velocity,
    required this.direction,
    required this.lastUpdateTime,
  });

  Offset position;
  Offset velocity;
  Offset direction;
  DateTime lastUpdateTime;

  double get speedMetersPerSecond => velocity.distance;

  Offset predictPosition(DateTime now) {
    final dtSeconds = _dtSeconds(now);
    return Offset(
      position.dx + (velocity.dx * dtSeconds),
      position.dy + (velocity.dy * dtSeconds),
    );
  }

  void correctWithMeasurement({
    required Offset measurement,
    required DateTime now,
    required double gain,
  }) {
    final dtSeconds = _dtSeconds(now);
    final predicted = predictPosition(now);
    final error = measurement - predicted;

    final corrected = Offset(
      predicted.dx + (gain * error.dx),
      predicted.dy + (gain * error.dy),
    );

    final delta = corrected - position;
    final nextVelocity = Offset(delta.dx / dtSeconds, delta.dy / dtSeconds);
    final speed = nextVelocity.distance;

    velocity = nextVelocity;
    if (speed > 0.001) {
      direction = Offset(nextVelocity.dx / speed, nextVelocity.dy / speed);
    }
    position = corrected;
    lastUpdateTime = now;
  }

  double _dtSeconds(DateTime now) {
    final raw = now.difference(lastUpdateTime).inMilliseconds / 1000;
    return raw.clamp(0.001, 5.0);
  }
}
