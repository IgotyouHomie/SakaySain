part of 'simulation_screen.dart';

extension _SimulationScreenGeometryPart on _SimulationScreenState {
  NearestRoadPoint _findNearestRoadPoint(Offset userPosition) {
    NearestRoadPoint? nearest;

    for (int roadIndex = 0; roadIndex < _roadNetwork.length; roadIndex++) {
      final road = _roadNetwork[roadIndex];
      for (
        int segmentIndex = 0;
        segmentIndex < road.length - 1;
        segmentIndex++
      ) {
        final a = road[segmentIndex];
        final b = road[segmentIndex + 1];
        final projection = _projectPointToSegment(userPosition, a, b);
        final distance = _distanceBetween(userPosition, projection.point);

        if (nearest == null || distance < nearest.distanceToRoad) {
          final progress = _progressAlongRoad(road, segmentIndex, projection.t);
          nearest = NearestRoadPoint(
            point: projection.point,
            roadIndex: roadIndex,
            segmentIndex: segmentIndex,
            t: projection.t,
            chunkId: _chunkIdForProgress(progress),
            distanceToRoad: distance,
          );
        }
      }
    }

    return nearest ??
        const NearestRoadPoint(
          point: Offset.zero,
          roadIndex: 0,
          segmentIndex: 0,
          t: 0,
          chunkId: 0,
          distanceToRoad: double.infinity,
        );
  }

  ProjectionResult _projectPointToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final ap = p - a;
    final abLenSq = (ab.dx * ab.dx) + (ab.dy * ab.dy);
    final t = abLenSq == 0
        ? 0.0
        : ((ap.dx * ab.dx) + (ap.dy * ab.dy)) / abLenSq;
    final clampedT = t.clamp(0.0, 1.0);
    return ProjectionResult(point: Offset.lerp(a, b, clampedT)!, t: clampedT);
  }

  double _progressAlongRoad(List<Offset> road, int segmentIndex, double t) {
    var distance = 0.0;
    for (int i = 0; i < segmentIndex; i++) {
      distance += _distanceBetween(road[i], road[i + 1]);
    }
    distance +=
        _distanceBetween(road[segmentIndex], road[segmentIndex + 1]) * t;
    return distance;
  }

  MovingState _snapUserToRoadAndInitState(User user) {
    final nearest = _findNearestRoadPoint(user.position);
    final road = _roadNetwork[nearest.roadIndex];
    final start = road[nearest.segmentIndex];
    final end = road[nearest.segmentIndex + 1];
    final segmentDirection = _normalizeOffset(end - start);

    final directionDot = _dot(
      _normalizeOffset(user.direction),
      segmentDirection,
    );
    final forward = directionDot >= 0;

    user.position = nearest.point;
    user.direction = forward
        ? segmentDirection
        : Offset(-segmentDirection.dx, -segmentDirection.dy);

    final state = MovingState(
      roadIndex: nearest.roadIndex,
      segmentIndex: nearest.segmentIndex,
      t: nearest.t,
      forward: forward,
    );
    _movingStates[user.id] = state;
    return state;
  }

  Offset _sceneToWorld(Offset scenePoint) {
    final center = const Offset(
      _SimulationScreenState._canvasSize / 2,
      _SimulationScreenState._canvasSize / 2,
    );
    final scale =
        _SimulationScreenState._canvasSize /
        ((_SimulationScreenState.worldRadius * 2) + 20);

    return Offset(
      (scenePoint.dx - center.dx) / scale,
      (scenePoint.dy - center.dy) / scale,
    );
  }

  Offset _clampToWorld(Offset worldPoint) {
    final distance = _distanceBetween(worldPoint, Offset.zero);
    if (distance <= _SimulationScreenState.worldRadius) {
      return worldPoint;
    }

    final factor = _SimulationScreenState.worldRadius / distance;
    return Offset(worldPoint.dx * factor, worldPoint.dy * factor);
  }

  void _recordTrailPoint(User user, Offset position) {
    if (user.trailPositions.isNotEmpty) {
      final last = user.trailPositions.last;
      final distance = _distanceBetween(last, position);
      if (distance < _SimulationScreenState._trailPointMinDistance) {
        return;
      }
    }

    user.trailPositions.add(position);
    final maxPoints = user.isPhoneUser
        ? _SimulationScreenState._trailMaxPointsPassenger
        : _SimulationScreenState._trailMaxPointsMock;

    if (user.trailPositions.length > maxPoints) {
      user.trailPositions.removeAt(0);
    }
  }

  String _assignJeepType(int userId) {
    const jeepTypes = ['Jeep A', 'Jeep B', 'Jeep C'];
    return jeepTypes[userId % jeepTypes.length];
  }

  Offset _normalizeOffset(Offset value) {
    final magnitude = math.sqrt((value.dx * value.dx) + (value.dy * value.dy));
    if (magnitude < 0.001) {
      return const Offset(0, 0);
    }
    return Offset(value.dx / magnitude, value.dy / magnitude);
  }

  double _dot(Offset a, Offset b) {
    return (a.dx * b.dx) + (a.dy * b.dy);
  }

  double _distanceBetween(Offset a, Offset b) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    return math.sqrt((dx * dx) + (dy * dy));
  }

  double _distancePointToSegment(Offset p, Offset a, Offset b) {
    return _distanceBetween(p, _projectPointToSegment(p, a, b).point);
  }
}
