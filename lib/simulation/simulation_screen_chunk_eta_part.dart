part of 'simulation_screen.dart';

extension _SimulationScreenChunkEtaPart on _SimulationScreenState {
  List<double> _buildRouteCumulativeLengths(List<Offset> path) {
    final cumulative = <double>[0];
    for (int i = 0; i < path.length - 1; i++) {
      cumulative.add(cumulative.last + _distanceBetween(path[i], path[i + 1]));
    }
    return cumulative;
  }

  double get _routeTotalLength => _routeCumulativeLengths.last;

  List<RoadChunk> _buildRoadChunksFromPath(List<Offset> path) {
    final chunks = <RoadChunk>[];
    double current = 0;
    int id = 0;
    while (current < _routeTotalLength) {
      final next = math.min(
        _routeTotalLength,
        current + _SimulationScreenState._chunkLengthMeters,
      );
      chunks.add(
        RoadChunk(
          id: id,
          startPoint: _pointAtProgress(current),
          endPoint: _pointAtProgress(next),
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
    return _distanceBetween(
          path.first,
          path.last,
        ) <
        0.001;
  }

  bool _isRouteLoop() => _isPathLoop(_routePath);

  void _emitRoadChunkEvent(RoadChunkEvent event) {
    _chunkEventQueue.add(event);
  }

  void _drainRoadChunkEvents(DateTime now) {
    if (_chunkEventQueue.isEmpty) {
      return;
    }

    final events = List<RoadChunkEvent>.from(_chunkEventQueue)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _chunkEventQueue.clear();

    for (final event in events) {
      switch (event.type) {
        case RoadChunkEventType.jeepEnterChunk:
          _handleJeepEnterChunkEvent(event, now);
          break;
        case RoadChunkEventType.jeepExitChunk:
          _handleJeepExitChunkEvent(event, now);
          break;
        case RoadChunkEventType.passengerBecameJeep:
        case RoadChunkEventType.passengerDisconnected:
        case RoadChunkEventType.ghostJeepCreated:
          break;
      }
    }
  }

  void _handleJeepEnterChunkEvent(RoadChunkEvent event, DateTime now) {
    final chunkId = event.chunkId;
    if (chunkId == null || chunkId < 0 || chunkId >= _routeChunks.length) {
      return;
    }

    final chunk = _routeChunks[chunkId];
    chunk.lastUpdated = event.timestamp.isAfter(now) ? now : event.timestamp;
  }

  void _handleJeepExitChunkEvent(RoadChunkEvent event, DateTime now) {
    final chunkId = event.chunkId;
    final jeepType = event.jeepType;
    if (chunkId == null || jeepType == null) {
      return;
    }
    if (chunkId < 0 || chunkId >= _routeChunks.length) {
      return;
    }

    final chunk = _routeChunks[chunkId];
    final travelSeconds = event.travelTimeSeconds;
    if (travelSeconds != null && travelSeconds > 0) {
      final direction = event.direction ?? RoadDirection.forward;
      final directionalSamples = direction == RoadDirection.forward
          ? chunk.forwardTravelSamples
          : chunk.backwardTravelSamples;
      directionalSamples.add(travelSeconds);
      if (directionalSamples.length > _SimulationScreenState._maxChunkSamples) {
        directionalSamples.removeAt(0);
      }
      var directionalSum = 0.0;
      for (final value in directionalSamples) {
        directionalSum += value;
      }
      final directionalAverage = directionalSum / directionalSamples.length;
      if (direction == RoadDirection.forward) {
        chunk.forwardAvgTravelTime = directionalAverage;
      } else {
        chunk.backwardAvgTravelTime = directionalAverage;
      }

      chunk.observedTravelSamplesAll.add(travelSeconds);
      if (chunk.observedTravelSamplesAll.length >
          _SimulationScreenState._maxChunkSamples) {
        chunk.observedTravelSamplesAll.removeAt(0);
      }
      chunk.updateTravelTimeAll(travelSeconds);

      final typeSamples = chunk.observedTravelSamplesByType.putIfAbsent(
        jeepType,
        () => <double>[],
      );
      typeSamples.add(travelSeconds);
      if (typeSamples.length > _SimulationScreenState._maxChunkSamples) {
        typeSamples.removeAt(0);
      }
      chunk.updateTravelTimeByType(jeepType, travelSeconds);

      final bucket = _timeBucketKey(event.timestamp);
      final directionalBucketMap = direction == RoadDirection.forward
          ? chunk.forwardSamplesByBucket
          : chunk.backwardSamplesByBucket;
      final directionalBucketAverages = direction == RoadDirection.forward
          ? chunk.forwardAverageByBucket
          : chunk.backwardAverageByBucket;
      final bucketSamples = directionalBucketMap.putIfAbsent(
        bucket,
        () => <double>[],
      );
      bucketSamples.add(travelSeconds);
      if (bucketSamples.length > _SimulationScreenState._maxChunkSamples) {
        bucketSamples.removeAt(0);
      }
      var bucketSum = 0.0;
      for (final value in bucketSamples) {
        bucketSum += value;
      }
      directionalBucketAverages[bucket] = bucketSum / bucketSamples.length;
    }

    _recordChunkPassEvent(
      chunkId: chunkId,
      jeepType: jeepType,
      now: event.timestamp,
      observed: event.observed,
    );
    chunk.lastUpdated = event.timestamp.isAfter(now) ? now : event.timestamp;
  }

  Offset _pointAtProgress(double progress) {
    final target = progress.clamp(0, _routeTotalLength).toDouble();
    for (int i = 0; i < _routePath.length - 1; i++) {
      final segStart = _routeCumulativeLengths[i];
      final segEnd = _routeCumulativeLengths[i + 1];
      if (target <= segEnd ||
          i == _routePath.length - 2) {
        final segLength = (segEnd - segStart).clamp(0.0001, double.infinity);
        final t = ((target - segStart) / segLength).clamp(0.0, 1.0);
        return Offset.lerp(
          _routePath[i],
          _routePath[i + 1],
          t,
        )!;
      }
    }
    return _routePath.last;
  }

  int _chunkIdForProgress(double progress) {
    if (_routeChunks.isEmpty) {
      return 0;
    }
    final raw = (progress / _SimulationScreenState._chunkLengthMeters).floor();
    return raw.clamp(0, _routeChunks.length - 1);
  }

  double _progressFromMovingState(MovingState state) {
    final road = _roadNetwork[state.roadIndex];
    return _progressAlongRoad(road, state.segmentIndex, state.t);
  }

  String _timeBucketKey(DateTime time) {
    final h = time.hour;
    if (h >= 6 && h < 10) {
      return 'morning';
    }
    if (h >= 10 && h < 16) {
      return 'midday';
    }
    if (h >= 16 && h < 20) {
      return 'evening';
    }
    return 'night';
  }

  void _initializeChunkTraversalFor(User user) {
    final state = _movingStates[user.id];
    if (state == null) {
      return;
    }
    final progress = _progressFromMovingState(state);
    _chunkTraversalByUser[user.id] = ChunkTraversalState(
      chunkId: _chunkIdForProgress(progress),
      entryTime: DateTime.now(),
      direction: state.forward ? RoadDirection.forward : RoadDirection.backward,
    );
  }

  void _initializeKalmanStateFor(User user, DateTime now) {
    final direction = _normalizeOffset(user.direction);
    final velocity = Offset(
      direction.dx * user.speed,
      direction.dy * user.speed,
    );
    _kalmanStateByUser[user.id] = KalmanMotionState(
      position: user.position,
      velocity: velocity,
      direction: direction,
      lastUpdateTime: now,
    );
  }

  void _removeKalmanStateForUser(int userId) {
    _kalmanStateByUser.remove(userId);
  }

  void _updateKalmanForObservedUser({
    required User user,
    required Offset measurementPosition,
    required DateTime now,
  }) {
    if (!_kalmanEnabled || user.isPhoneUser || !user.isMoving) {
      return;
    }

    if (!_kalmanStateByUser.containsKey(user.id)) {
      _initializeKalmanStateFor(user, now);
    }
    final kalman = _kalmanStateByUser[user.id];
    if (kalman == null) {
      return;
    }

    kalman.correctWithMeasurement(
      measurement: measurementPosition,
      now: now,
      gain: _kalmanGain,
    );

    user.position = kalman.position;
    if (kalman.speedMetersPerSecond > 0.01) {
      user.direction = kalman.direction;
    }
  }

  double _realtimeSpeedForUser(User user) {
    final kalman = _kalmanStateByUser[user.id];
    if (_kalmanEnabled && kalman != null) {
      final speed = kalman.speedMetersPerSecond;
      if (speed > 0.1) {
        return speed;
      }
    }
    return _effectiveSpeedForUser(user).clamp(0.1, 1000.0);
  }

  void _recordChunkTraversalForUser({
    required int userId,
    required double oldProgressMeters,
    required double newProgressMeters,
    required RoadDirection direction,
    required DateTime now,
  }) {
    final newChunk = _chunkIdForProgress(newProgressMeters);
    final traversal = _chunkTraversalByUser[userId];

    if (traversal == null) {
      _chunkTraversalByUser[userId] = ChunkTraversalState(
        chunkId: newChunk,
        entryTime: now,
        direction: direction,
      );
      User? user;
      for (final candidate in _users) {
        if (candidate.id == userId) {
          user = candidate;
          break;
        }
      }
      if (user != null) {
        _emitRoadChunkEvent(
          RoadChunkEvent(
            type: RoadChunkEventType.jeepEnterChunk,
            timestamp: now,
            userId: userId,
            chunkId: newChunk,
            jeepType: user.jeepType,
            direction: direction,
            observed: true,
          ),
        );
      }
      return;
    }

    if (traversal.direction != direction) {
      traversal
        ..chunkId = newChunk
        ..entryTime = now
        ..direction = direction
        ..accumulatedStopSeconds = 0;
      return;
    }

    if (traversal.chunkId == newChunk) {
      return;
    }

    User? user;
    for (final candidate in _users) {
      if (candidate.id == userId) {
        user = candidate;
        break;
      }
    }
    final elapsedSeconds =
        now.difference(traversal.entryTime).inMilliseconds / 1000 +
        traversal.accumulatedStopSeconds;
    final completedChunkId = traversal.chunkId;
    if (user != null) {
      _emitRoadChunkEvent(
        RoadChunkEvent(
          type: RoadChunkEventType.jeepExitChunk,
          timestamp: now,
          userId: userId,
          chunkId: completedChunkId,
          jeepType: user.jeepType,
          direction: traversal.direction,
          observed: true,
          travelTimeSeconds: elapsedSeconds,
        ),
      );
      _emitRoadChunkEvent(
        RoadChunkEvent(
          type: RoadChunkEventType.jeepEnterChunk,
          timestamp: now,
          userId: userId,
          chunkId: newChunk,
          jeepType: user.jeepType,
          direction: direction,
          observed: true,
        ),
      );
    }

    traversal
      ..chunkId = newChunk
      ..entryTime = now
      ..direction = direction
      ..accumulatedStopSeconds = 0;
  }

  void _recordChunkPassEvent({
    required int chunkId,
    required String jeepType,
    required DateTime now,
    required bool observed,
  }) {
    if (chunkId < 0 || chunkId >= _routeChunks.length) {
      return;
    }

    final chunk = _routeChunks[chunkId];
    final event = ChunkPassEvent(
      time: now,
      jeepType: jeepType,
      observed: observed,
    );

    if (observed) {
      final previousPass = chunk.lastJeepPassTimeObserved;
      final previousTypePass = chunk.lastJeepPassTimeByTypeObserved[jeepType];
      chunk.jeepPassEvents.add(event);
      if (chunk.jeepPassEvents.length >
          _SimulationScreenState._maxPassEventSamples) {
        chunk.jeepPassEvents.removeAt(0);
      }
      final byType = chunk.jeepTypePassEvents.putIfAbsent(
        jeepType,
        () => <ChunkPassEvent>[],
      );
      byType.add(event);
      if (byType.length > _SimulationScreenState._maxPassEventSamples) {
        byType.removeAt(0);
      }
      chunk.observedPassCount++;
      chunk.lastJeepPassTimeObserved = now;
      chunk.lastJeepPassTimeByTypeObserved[jeepType] = now;

      if (previousPass != null) {
        final deltaSeconds = now.difference(previousPass).inMilliseconds / 1000;
        chunk.avgArrivalIntervalAllObserved = RoadChunk.updateRollingMean(
          currentMean: chunk.avgArrivalIntervalAllObserved,
          currentCount: chunk.arrivalIntervalObservedSamples,
          sample: deltaSeconds,
        );
        chunk.arrivalIntervalObservedSamples += 1;
      }

      if (previousTypePass != null) {
        final deltaTypeSeconds =
            now.difference(previousTypePass).inMilliseconds / 1000;
        final typeCount =
            chunk.arrivalIntervalObservedSamplesByType[jeepType] ?? 0;
        final currentMean =
            chunk.avgArrivalIntervalByTypeObserved[jeepType] ?? 0;
        chunk.avgArrivalIntervalByTypeObserved[jeepType] =
            RoadChunk.updateRollingMean(
              currentMean: currentMean,
              currentCount: typeCount,
              sample: deltaTypeSeconds,
            );
        chunk.arrivalIntervalObservedSamplesByType[jeepType] = typeCount + 1;
      }
    } else {
      final previousPass = chunk.lastJeepPassTimeSpeculative;
      final previousTypePass =
          chunk.lastJeepPassTimeByTypeSpeculative[jeepType];
      chunk.speculativePassEvents.add(event);
      if (chunk.speculativePassEvents.length >
          _SimulationScreenState._maxPassEventSamples) {
        chunk.speculativePassEvents.removeAt(0);
      }
      final byType = chunk.speculativeJeepTypePassEvents.putIfAbsent(
        jeepType,
        () => <ChunkPassEvent>[],
      );
      byType.add(event);
      if (byType.length > _SimulationScreenState._maxPassEventSamples) {
        byType.removeAt(0);
      }
      chunk.speculativePassCount++;
      chunk.lastJeepPassTimeSpeculative = now;
      chunk.lastJeepPassTimeByTypeSpeculative[jeepType] = now;

      if (previousPass != null) {
        final deltaSeconds = now.difference(previousPass).inMilliseconds / 1000;
        chunk.avgArrivalIntervalAllSpeculative = RoadChunk.updateRollingMean(
          currentMean: chunk.avgArrivalIntervalAllSpeculative,
          currentCount: chunk.arrivalIntervalSpeculativeSamples,
          sample: deltaSeconds,
        );
        chunk.arrivalIntervalSpeculativeSamples += 1;
      }

      if (previousTypePass != null) {
        final deltaTypeSeconds =
            now.difference(previousTypePass).inMilliseconds / 1000;
        final typeCount =
            chunk.arrivalIntervalSpeculativeSamplesByType[jeepType] ?? 0;
        final currentMean =
            chunk.avgArrivalIntervalByTypeSpeculative[jeepType] ?? 0;
        chunk.avgArrivalIntervalByTypeSpeculative[jeepType] =
            RoadChunk.updateRollingMean(
              currentMean: currentMean,
              currentCount: typeCount,
              sample: deltaTypeSeconds,
            );
        chunk.arrivalIntervalSpeculativeSamplesByType[jeepType] = typeCount + 1;
      }
    }

    _recalculateChunkArrivalProbabilities(chunk);
    _recalculateChunkFlowRates(chunk, now);
  }

  void _recalculateChunkFlowRates(RoadChunk chunk, DateTime now) {
    const windowSeconds = 120.0;
    final cutoff = now.subtract(const Duration(seconds: 120));

    var weightedTotalCount = 0.0;
    final weightedByType = <String, double>{};

    for (final event in chunk.jeepPassEvents) {
      if (event.time.isBefore(cutoff)) {
        continue;
      }
      weightedTotalCount += 1.0;
      weightedByType[event.jeepType] =
          (weightedByType[event.jeepType] ?? 0) + 1.0;
    }

    for (final event in chunk.speculativePassEvents) {
      if (event.time.isBefore(cutoff)) {
        continue;
      }
      weightedTotalCount += 0.5;
      weightedByType[event.jeepType] =
          (weightedByType[event.jeepType] ?? 0) + 0.5;
    }

    chunk.flowRateJeepsPerMinute = (weightedTotalCount / windowSeconds) * 60;
    chunk.flowRateJeepsPerMinuteByType.clear();
    for (final entry in weightedByType.entries) {
      chunk.flowRateJeepsPerMinuteByType[entry.key] =
          (entry.value / windowSeconds) * 60;
    }
  }

  void _recalculateChunkArrivalProbabilities(RoadChunk chunk) {
    final weightedCounts = <String, double>{};
    var totalWeight = 0.0;

    for (final event in chunk.jeepPassEvents) {
      weightedCounts[event.jeepType] =
          (weightedCounts[event.jeepType] ?? 0) + 1.0;
      totalWeight += 1.0;
    }
    for (final event in chunk.speculativePassEvents) {
      weightedCounts[event.jeepType] =
          (weightedCounts[event.jeepType] ?? 0) + 0.5;
      totalWeight += 0.5;
    }

    chunk.jeepArrivalProbabilityByType.clear();
    if (totalWeight <= 0) {
      return;
    }
    for (final entry in weightedCounts.entries) {
      chunk.jeepArrivalProbabilityByType[entry.key] =
          ((entry.value / totalWeight) * 100).clamp(0.0, 100.0);
    }
  }

  void _convertObservedJeepToGhost(User user, DateTime now) {
    final traversal = _chunkTraversalByUser[user.id];
    final state = _movingStates[user.id];
    final direction =
        traversal?.direction ??
        ((state?.forward ?? true)
            ? RoadDirection.forward
            : RoadDirection.backward);
    final chunkId =
        traversal?.chunkId ??
        (state == null
            ? 0
            : _chunkIdForProgress(_progressFromMovingState(state)));
    final bucket = _timeBucketKey(now);
    final travelSeconds = _estimatedChunkTravelTimeSeconds(
      chunkId: chunkId,
      bucket: bucket,
      direction: direction,
    ).clamp(1.0, 180.0);

    final ghost = GhostJeep(
      sourceUserId: user.id,
      jeepType: user.jeepType,
      currentChunkId: chunkId,
      direction: direction,
      avgSpeed: _routeChunks[chunkId].lengthMeters / travelSeconds,
      expectedNextChunkTime: now.add(
        Duration(milliseconds: (travelSeconds * 1000).round()),
      ),
      lastChunkTransitionAt: now,
      confidence: _SimulationScreenState._ghostConfidenceStart,
    )..position = user.position;

    _emitRoadChunkEvent(
      RoadChunkEvent(
        type: RoadChunkEventType.passengerDisconnected,
        timestamp: now,
        userId: user.id,
        chunkId: chunkId,
        jeepType: user.jeepType,
        direction: direction,
        observed: true,
        position: user.position,
      ),
    );
    _emitRoadChunkEvent(
      RoadChunkEvent(
        type: RoadChunkEventType.ghostJeepCreated,
        timestamp: now,
        userId: user.id,
        chunkId: chunkId,
        jeepType: user.jeepType,
        direction: direction,
        observed: false,
        position: user.position,
      ),
    );

    _ghostJeepsBySourceUser[user.id] = ghost;
    _removeKalmanStateForUser(user.id);
  }

  void _removeGhostForObservedUser(int userId) {
    _ghostJeepsBySourceUser.remove(userId);
  }

  void _simulateRandomObservedGhostTransitions(DateTime now) {
    if (!_isDeveloperMode || !_randomGhostToggleEnabled) {
      return;
    }

    final chanceThisFrame =
        (_randomGhostToggleLikelihood * _SimulationScreenState._frameDtSeconds)
            .clamp(0.0, 1.0);

    for (final user in _users) {
      if (user.isPhoneUser || !user.isMockUser) {
        continue;
      }

      final ghost = _ghostJeepsBySourceUser[user.id];
      if (user.isMoving && ghost == null) {
        if (_random.nextDouble() < chanceThisFrame) {
          _convertObservedJeepToGhost(user, now);
        }
        continue;
      }

      if (ghost != null) {
        if (_random.nextDouble() < chanceThisFrame) {
          if (!user.isMoving) {
            _restoreObservedFromGhost(user: user, ghost: ghost);
          } else {
            _initializeKalmanStateFor(user, now);
          }
          _removeGhostForObservedUser(user.id);
        }
      }
    }
  }

  void _restoreObservedFromGhost({
    required User user,
    required GhostJeep ghost,
  }) {
    user
      ..position = ghost.position
      ..speed = ghost.avgSpeed.clamp(User.movementThreshold, 90)
      ..direction = ghost.direction == RoadDirection.forward
          ? (_routePath.last -
                _routePath.first)
          : (_routePath.first -
                _routePath.last);

    final state = _snapUserToRoadAndInitState(user);
    state.forward = ghost.direction == RoadDirection.forward;
    _initializeChunkTraversalFor(user);
    _initializeKalmanStateFor(user, DateTime.now());
    _emitRoadChunkEvent(
      RoadChunkEvent(
        type: RoadChunkEventType.passengerBecameJeep,
        timestamp: DateTime.now(),
        userId: user.id,
        chunkId: ghost.currentChunkId,
        jeepType: user.jeepType,
        direction: ghost.direction,
        observed: true,
        position: user.position,
      ),
    );
  }

  void _updateGhostJeeps(DateTime now) {
    if (_ghostJeepsBySourceUser.isEmpty) {
      return;
    }

    final toRemove = <int>[];
    final bucket = _timeBucketKey(now);

    for (final entry in _ghostJeepsBySourceUser.entries) {
      final ghost = entry.value;
      final oldProgress = _ghostProgressMeters(ghost, now);

      while (!now.isBefore(ghost.expectedNextChunkTime)) {
        final transitionTime = ghost.expectedNextChunkTime;
        final travelSeconds =
            transitionTime
                .difference(ghost.lastChunkTransitionAt)
                .inMilliseconds /
            1000;
        _emitRoadChunkEvent(
          RoadChunkEvent(
            type: RoadChunkEventType.jeepExitChunk,
            timestamp: transitionTime,
            userId: -ghost.sourceUserId,
            chunkId: ghost.currentChunkId,
            jeepType: ghost.jeepType,
            direction: ghost.direction,
            observed: false,
            travelTimeSeconds: travelSeconds,
          ),
        );

        final transition = _nextGhostTransition(
          chunkId: ghost.currentChunkId,
          direction: ghost.direction,
          jeepType: ghost.jeepType,
        );

        ghost.confidence -= _ghostDecayForTransition(
          wrappedLoop: transition.wrappedLoop,
          terminalBounce: transition.terminalBounce,
        );
        if (ghost.confidence < _SimulationScreenState._ghostConfidenceMin) {
          toRemove.add(entry.key);
          break;
        }

        ghost
          ..currentChunkId = transition.nextChunkId
          ..direction = transition.nextDirection
          ..lastChunkTransitionAt = ghost.expectedNextChunkTime;

        _emitRoadChunkEvent(
          RoadChunkEvent(
            type: RoadChunkEventType.jeepEnterChunk,
            timestamp: transitionTime,
            userId: -ghost.sourceUserId,
            chunkId: ghost.currentChunkId,
            jeepType: ghost.jeepType,
            direction: ghost.direction,
            observed: false,
          ),
        );

        final nextTravelSeconds = _estimatedChunkTravelTimeSeconds(
          chunkId: ghost.currentChunkId,
          bucket: bucket,
          direction: ghost.direction,
        ).clamp(1.0, 180.0);
        ghost
          ..avgSpeed =
              _routeChunks[ghost.currentChunkId].lengthMeters /
              nextTravelSeconds
          ..expectedNextChunkTime = ghost.lastChunkTransitionAt.add(
            Duration(milliseconds: (nextTravelSeconds * 1000).round()),
          );
      }

      final totalMs = ghost.expectedNextChunkTime
          .difference(ghost.lastChunkTransitionAt)
          .inMilliseconds
          .clamp(1, 2147483647);
      final elapsedMs = now
          .difference(ghost.lastChunkTransitionAt)
          .inMilliseconds
          .clamp(0, totalMs);
      final t = elapsedMs / totalMs;
      final chunk = _routeChunks[ghost.currentChunkId];
      ghost.position = ghost.direction == RoadDirection.forward
          ? Offset.lerp(chunk.startPoint, chunk.endPoint, t)!
          : Offset.lerp(chunk.endPoint, chunk.startPoint, t)!;

      // Keep the source observed marker aligned with ghost projection so it
      // does not appear frozen when random observed<->ghost mode is enabled.
      User? sourceUser;
      for (final candidate in _users) {
        if (candidate.id == ghost.sourceUserId) {
          sourceUser = candidate;
          break;
        }
      }
      if (sourceUser != null) {
        sourceUser
          ..position = ghost.position
          ..direction = ghost.direction == RoadDirection.forward
              ? _normalizeOffset(
                  _routePath.last -
                      _routePath.first,
                )
              : _normalizeOffset(
                  _routePath.first -
                      _routePath.last,
                );
      }

      final newProgress = _ghostProgressMeters(ghost, now);
      _recordRoadWaiterArrivalIfCrossed(
        userId: -ghost.sourceUserId,
        oldProgressMeters: oldProgress,
        newProgressMeters: newProgress,
        jeepType: ghost.jeepType,
        isGhost: true,
      );
    }

    for (final id in toRemove) {
      _ghostJeepsBySourceUser.remove(id);
    }
  }

  ({
    int nextChunkId,
    RoadDirection nextDirection,
    bool wrappedLoop,
    bool terminalBounce,
  })
  _nextGhostTransition({
    required int chunkId,
    required RoadDirection direction,
    required String jeepType,
  }) {
    final maxChunk = _routeChunks.length - 1;
    if (maxChunk <= 0) {
      return (
        nextChunkId: 0,
        nextDirection: direction,
        wrappedLoop: false,
        terminalBounce: false,
      );
    }

    final routeIsLoop = _isRouteLoop();
    final graphCandidates = _roadGraph.candidateTransitions(
      currentChunkId: chunkId,
      currentDirection: direction,
    );
    if (graphCandidates.isNotEmpty) {
      RoadGraphTransition? best;
      var bestScore = double.negativeInfinity;
      for (final candidate in graphCandidates) {
        if (candidate.nextChunkId < 0 ||
            candidate.nextChunkId >= _routeChunks.length) {
          continue;
        }
        final candidateChunk = _routeChunks[candidate.nextChunkId];
        final directionalBias = candidate.nextDirection == direction
            ? 0.25
            : 0.0;
        final typeFlow =
            candidateChunk.flowRateJeepsPerMinuteByType[jeepType] ?? 0.0;
        final totalFlow = candidateChunk.flowRateJeepsPerMinute;
        final score = directionalBias + (typeFlow * 1.5) + totalFlow;
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }

      final selected = best ?? graphCandidates.first;
      return (
        nextChunkId: selected.nextChunkId,
        nextDirection: selected.nextDirection,
        wrappedLoop:
            routeIsLoop &&
            ((direction == RoadDirection.forward &&
                    selected.nextChunkId < chunkId) ||
                (direction == RoadDirection.backward &&
                    selected.nextChunkId > chunkId)),
        terminalBounce: false,
      );
    }

    if (direction == RoadDirection.forward) {
      if (chunkId < maxChunk) {
        return (
          nextChunkId: chunkId + 1,
          nextDirection: direction,
          wrappedLoop: false,
          terminalBounce: false,
        );
      }
      if (routeIsLoop) {
        return (
          nextChunkId: 0,
          nextDirection: direction,
          wrappedLoop: true,
          terminalBounce: false,
        );
      }
      return (
        nextChunkId: maxChunk - 1,
        nextDirection: RoadDirection.backward,
        wrappedLoop: false,
        terminalBounce: true,
      );
    }

    if (chunkId > 0) {
      return (
        nextChunkId: chunkId - 1,
        nextDirection: direction,
        wrappedLoop: false,
        terminalBounce: false,
      );
    }
    if (routeIsLoop) {
      return (
        nextChunkId: maxChunk,
        nextDirection: direction,
        wrappedLoop: true,
        terminalBounce: false,
      );
    }
    return (
      nextChunkId: 1,
      nextDirection: RoadDirection.forward,
      wrappedLoop: false,
      terminalBounce: true,
    );
  }

  double _ghostDecayForTransition({
    required bool wrappedLoop,
    required bool terminalBounce,
  }) {
    if (wrappedLoop) {
      return _SimulationScreenState._ghostConfidenceDecayLoop;
    }
    if (terminalBounce) {
      return _SimulationScreenState._ghostConfidenceDecayTerminal;
    }
    return _SimulationScreenState._ghostConfidenceDecayDefault;
  }

  double _ghostProgressMeters(GhostJeep ghost, DateTime now) {
    final start = _chunkStartProgressMeters(ghost.currentChunkId);
    final chunkLength = _routeChunks[ghost.currentChunkId].lengthMeters;
    final totalMs = ghost.expectedNextChunkTime
        .difference(ghost.lastChunkTransitionAt)
        .inMilliseconds
        .clamp(1, 2147483647);
    final elapsedMs = now
        .difference(ghost.lastChunkTransitionAt)
        .inMilliseconds
        .clamp(0, totalMs);
    final t = elapsedMs / totalMs;
    if (ghost.direction == RoadDirection.forward) {
      return start + (chunkLength * t);
    }
    return start + (chunkLength * (1 - t));
  }

  double _chunkStartProgressMeters(int chunkId) {
    var total = 0.0;
    for (int i = 0; i < chunkId && i < _routeChunks.length; i++) {
      total += _routeChunks[i].lengthMeters;
    }
    return total;
  }

  void _recordRoadWaiterArrivalIfCrossed({
    required int userId,
    required double oldProgressMeters,
    required double newProgressMeters,
    required String jeepType,
    required bool isGhost,
  }) {
    final pin = _roadWaiterPin;
    if (pin == null) {
      return;
    }

    final target = _progressAlongRoad(
      _routePath,
      pin.segmentIndex,
      pin.t,
    );
    final crossedForward =
        oldProgressMeters < target && newProgressMeters >= target;
    final crossedBackward =
        oldProgressMeters > target && newProgressMeters <= target;
    if (!crossedForward && !crossedBackward) {
      return;
    }

    final crossingDirection = crossedForward
        ? RoadDirection.forward
        : RoadDirection.backward;
    if (_selectedPinDirection != null &&
        _selectedPinDirection != crossingDirection) {
      return;
    }

    final logs = _pinArrivalLogsByChunk.putIfAbsent(
      pin.chunkId,
      () => <DateTime>[],
    );
    final now = DateTime.now();
    if (logs.isNotEmpty && now.difference(logs.last).inSeconds < 2) {
      return;
    }
    logs.add(now);
    if (logs.length > _SimulationScreenState._maxPinArrivalSamples) {
      logs.removeAt(0);
    }

    if (!_isWaitingForJeep || !_devAutoStopWhenJeepReachesPin) {
      return;
    }
    if (isGhost && !_devAutoStopIncludeGhostJeeps) {
      return;
    }
    if (_selectedJeepTypes.isNotEmpty &&
        !_selectedJeepTypes.contains(jeepType)) {
      return;
    }

    _completeRoadWaitMeasurement(
      now: now,
      jeepType: isGhost ? '$jeepType (ghost)' : jeepType,
      ghostJeepUsed: isGhost,
    );
  }

  double _effectiveSpeedForUser(User user) {
    var speed = user.speed;
    if (_trafficEnabled) {
      final state = _movingStates[user.id];
      if (state != null) {
        final progress = _progressFromMovingState(state);
        final chunkId = _chunkIdForProgress(progress);
        speed /= _slowdownMultiplierForChunk(chunkId);
      } else if (_isUserInTraffic(user.position)) {
        speed *= 0.45;
      }
    }
    return speed;
  }

  bool _isUserInTraffic(Offset point) {
    for (final zone in _trafficZones) {
      if (_distancePointToSegment(point, zone.start, zone.end) <= 10) {
        return true;
      }
    }
    return false;
  }

  TrackedEta? _computeNearestIncomingEta({
    required NearestRoadPoint? roadWaiterPin,
    required RoadDirection? selectedDirection,
    required Set<int> candidateUserIds,
  }) {
    final targetPin = roadWaiterPin;
    final direction = selectedDirection;
    if (targetPin == null || direction == null) {
      return null;
    }

    final bucket = _timeBucketKey(DateTime.now());

    final targetProgress = _progressAlongRoad(
      _routePath,
      targetPin.segmentIndex,
      targetPin.t,
    );

    TrackedEta? bestReal;
    TrackedEta? bestGhost;

    for (final user in _users) {
      if (user.isPhoneUser || !user.isMoving) {
        continue;
      }
      if (!candidateUserIds.contains(user.id)) {
        continue;
      }
      if (_selectedJeepTypes.isNotEmpty &&
          !_selectedJeepTypes.contains(user.jeepType)) {
        continue;
      }

      final state = _movingStates[user.id];
      if (state == null || state.roadIndex != targetPin.roadIndex) {
        continue;
      }
      final userDirection = state.forward
          ? RoadDirection.forward
          : RoadDirection.backward;
      if (userDirection != direction) {
        continue;
      }

      final road = _roadNetwork[state.roadIndex];
      final userProgress = _progressAlongRoad(
        road,
        state.segmentIndex,
        state.t,
      );
      final isApproaching = state.forward
          ? userProgress < targetProgress
          : userProgress > targetProgress;
      if (!isApproaching) {
        continue;
      }

      final distance = (targetProgress - userProgress).abs();
      if (distance < _SimulationScreenState._minimumPredictionDistanceMeters) {
        continue;
      }

      final weightedEta = _buildWeightedEta(
        fromProgressMeters: userProgress,
        toProgressMeters: targetProgress,
        currentSpeedMetersPerSecond: _realtimeSpeedForUser(user),
        bucket: bucket,
        direction: direction,
        jeepType: user.jeepType,
      );
      if (!weightedEta.finalEtaSeconds.isFinite ||
          weightedEta.finalEtaSeconds <= 0) {
        continue;
      }

      final candidate = TrackedEta(
        userId: user.id,
        jeepType: user.jeepType,
        etaSeconds: weightedEta.finalEtaSeconds,
        confidencePercent: _confidenceForRange(
          fromProgressMeters: userProgress,
          toProgressMeters: targetProgress,
          bucket: bucket,
          direction: direction,
        ).clamp(55.0, 99.0),
        distanceMeters: distance,
        etaRealTimeSeconds: weightedEta.realTimeSeconds,
        etaHistoricalSeconds: weightedEta.historicalSeconds,
        etaTrafficSeconds: weightedEta.trafficAdjustedSeconds,
        trafficFactor: weightedEta.trafficFactor,
        isGhost: false,
        predictionSource: 'Passenger Jeep',
        predictionMethod: 'Passenger Jeep ETA',
        confidenceLabel: 'HIGH',
        predictionMinSeconds: (weightedEta.finalEtaSeconds * 0.85).clamp(
          0.0,
          1000000.0,
        ),
        predictionMaxSeconds: (weightedEta.finalEtaSeconds * 1.15).clamp(
          0.0,
          1000000.0,
        ),
        predictionAgeSeconds: 0,
      );

      if (bestReal == null || candidate.etaSeconds < bestReal.etaSeconds) {
        bestReal = candidate;
      }
    }

    for (final ghost in _ghostJeepsBySourceUser.values) {
      if (_selectedJeepTypes.isNotEmpty &&
          !_selectedJeepTypes.contains(ghost.jeepType)) {
        continue;
      }
      if (ghost.direction != direction) {
        continue;
      }

      final ghostProgress = _ghostProgressMeters(ghost, DateTime.now());
      final isApproaching = ghost.direction == RoadDirection.forward
          ? ghostProgress < targetProgress
          : ghostProgress > targetProgress;
      if (!isApproaching) {
        continue;
      }

      final distance = (targetProgress - ghostProgress).abs();
      if (distance < _SimulationScreenState._minimumPredictionDistanceMeters) {
        continue;
      }

      final weightedEta = _buildWeightedEta(
        fromProgressMeters: ghostProgress,
        toProgressMeters: targetProgress,
        currentSpeedMetersPerSecond: ghost.avgSpeed.clamp(0.1, 1000.0),
        bucket: bucket,
        direction: direction,
        jeepType: ghost.jeepType,
      );
      if (!weightedEta.finalEtaSeconds.isFinite ||
          weightedEta.finalEtaSeconds <= 0) {
        continue;
      }

      final confidenceAdjustedRankingEta =
          weightedEta.finalEtaSeconds / ghost.confidence.clamp(0.35, 1.0);
      final candidate = TrackedEta(
        userId: -ghost.sourceUserId,
        jeepType: '${ghost.jeepType} (ghost)',
        etaSeconds: weightedEta.finalEtaSeconds,
        confidencePercent: (ghost.confidence * 100).clamp(40.0, 90.0),
        distanceMeters: distance,
        etaRealTimeSeconds: weightedEta.realTimeSeconds,
        etaHistoricalSeconds: weightedEta.historicalSeconds,
        etaTrafficSeconds: weightedEta.trafficAdjustedSeconds,
        trafficFactor: weightedEta.trafficFactor,
        isGhost: true,
        predictionSource: 'Ghost Jeep',
        predictionMethod: 'Ghost Projection',
        confidenceLabel: 'MEDIUM',
        predictionMinSeconds: (weightedEta.finalEtaSeconds * 0.75).clamp(
          0.0,
          1000000.0,
        ),
        predictionMaxSeconds: (weightedEta.finalEtaSeconds * 1.35).clamp(
          0.0,
          1000000.0,
        ),
        predictionAgeSeconds:
            DateTime.now()
                .difference(ghost.lastChunkTransitionAt)
                .inMilliseconds /
            1000,
      );

      if (bestGhost == null ||
          confidenceAdjustedRankingEta <
              (bestGhost.etaSeconds /
                  (bestGhost.confidencePercent / 100).clamp(0.35, 1.0))) {
        bestGhost = candidate;
      }
    }

    final flowEtaSeconds = _flowOnlyEtaForPin(
      pin: targetPin,
      direction: direction,
    );
    final hasFlow = flowEtaSeconds > 0.1;
    final flowDistance = _SimulationScreenState._upstreamScanMaxMeters;
    final flowMin = (flowEtaSeconds * 0.7).clamp(0.0, 1000000.0);
    final flowMax = (flowEtaSeconds * 1.3).clamp(0.0, 1000000.0);

    final components =
        <
          ({
            double eta,
            double weight,
            double distance,
            double min,
            double max,
            double age,
          })
        >[];
    final adaptiveChunkId = targetPin.chunkId.clamp(0, _routeChunks.length - 1);

    if (bestReal != null) {
      components.add((
        eta: bestReal.etaSeconds,
        weight: _adaptiveSourceWeightForChunk(
          chunkId: adaptiveChunkId,
          source: 'Passenger Jeep',
          baseWeight: 0.6,
        ),
        distance: bestReal.distanceMeters,
        min: bestReal.predictionMinSeconds,
        max: bestReal.predictionMaxSeconds,
        age: bestReal.predictionAgeSeconds,
      ));
    }
    if (bestGhost != null) {
      components.add((
        eta: bestGhost.etaSeconds,
        weight: _adaptiveSourceWeightForChunk(
          chunkId: adaptiveChunkId,
          source: 'Ghost Jeep',
          baseWeight: 0.3,
        ),
        distance: bestGhost.distanceMeters,
        min: bestGhost.predictionMinSeconds,
        max: bestGhost.predictionMaxSeconds,
        age: bestGhost.predictionAgeSeconds,
      ));
    }
    if (hasFlow) {
      components.add((
        eta: flowEtaSeconds,
        weight: _adaptiveSourceWeightForChunk(
          chunkId: adaptiveChunkId,
          source: 'Flow Estimate',
          baseWeight: 0.1,
        ),
        distance: flowDistance,
        min: flowMin,
        max: flowMax,
        age: 0.0,
      ));
    }

    if (components.isEmpty) {
      return null;
    }

    var weightSum = 0.0;
    var etaWeighted = 0.0;
    var distanceWeighted = 0.0;
    var minWeighted = 0.0;
    var maxWeighted = 0.0;
    var ageWeighted = 0.0;
    for (final c in components) {
      weightSum += c.weight;
      etaWeighted += c.eta * c.weight;
      distanceWeighted += c.distance * c.weight;
      minWeighted += c.min * c.weight;
      maxWeighted += c.max * c.weight;
      ageWeighted += c.age * c.weight;
    }
    final normalizedEta = etaWeighted / weightSum;
    final normalizedDistance = distanceWeighted / weightSum;
    final normalizedMin = minWeighted / weightSum;
    final normalizedMax = maxWeighted / weightSum;
    final normalizedAge = ageWeighted / weightSum;

    final source = bestReal != null
        ? 'Passenger Jeep'
        : bestGhost != null
        ? 'Ghost Jeep'
        : 'Flow Estimate';
    final confidenceLabel = bestReal != null
        ? 'HIGH'
        : bestGhost != null
        ? 'MEDIUM'
        : 'LOW';
    final method = components.length > 1 ? 'Hybrid Weighted' : source;

    final confidencePercent = confidenceLabel == 'HIGH'
        ? 90.0
        : confidenceLabel == 'MEDIUM'
        ? 65.0
        : 35.0;

    return TrackedEta(
      userId: bestReal?.userId ?? bestGhost?.userId ?? -999,
      jeepType: bestReal?.jeepType ?? bestGhost?.jeepType ?? 'Flow Estimate',
      etaSeconds: normalizedEta,
      confidencePercent: confidencePercent,
      distanceMeters: normalizedDistance,
      etaRealTimeSeconds:
          bestReal?.etaRealTimeSeconds ??
          bestGhost?.etaRealTimeSeconds ??
          normalizedEta,
      etaHistoricalSeconds:
          bestReal?.etaHistoricalSeconds ??
          bestGhost?.etaHistoricalSeconds ??
          normalizedEta,
      etaTrafficSeconds:
          bestReal?.etaTrafficSeconds ??
          bestGhost?.etaTrafficSeconds ??
          normalizedEta,
      trafficFactor: bestReal?.trafficFactor ?? bestGhost?.trafficFactor ?? 1,
      isGhost: bestReal == null && bestGhost != null,
      predictionSource: source,
      predictionMethod: method,
      confidenceLabel: confidenceLabel,
      predictionMinSeconds: normalizedMin,
      predictionMaxSeconds: normalizedMax,
      predictionAgeSeconds: normalizedAge,
    );
  }

  ({
    double realTimeSeconds,
    double historicalSeconds,
    double trafficAdjustedSeconds,
    double trafficFactor,
    double finalEtaSeconds,
  })
  _buildWeightedEta({
    required double fromProgressMeters,
    required double toProgressMeters,
    required double currentSpeedMetersPerSecond,
    required String bucket,
    required RoadDirection direction,
    required String jeepType,
  }) {
    final distanceMeters = (toProgressMeters - fromProgressMeters).abs();
    final etaRealTime =
        distanceMeters / currentSpeedMetersPerSecond.clamp(0.1, 1000.0);
    final etaHistorical = _estimateHistoricalEtaFromChunks(
      fromProgressMeters: fromProgressMeters,
      toProgressMeters: toProgressMeters,
      bucket: bucket,
      direction: direction,
      jeepType: jeepType,
    );
    final trafficFactor = _trafficFactorForRange(
      fromProgressMeters: fromProgressMeters,
      toProgressMeters: toProgressMeters,
      direction: direction,
    );
    final etaTraffic = etaHistorical * trafficFactor;
    final etaFinal =
        (_SimulationScreenState._etaWeightRealTime * etaRealTime) +
        (_SimulationScreenState._etaWeightHistorical * etaHistorical) +
        (_SimulationScreenState._etaWeightTraffic * etaTraffic);

    return (
      realTimeSeconds: etaRealTime,
      historicalSeconds: etaHistorical,
      trafficAdjustedSeconds: etaTraffic,
      trafficFactor: trafficFactor,
      finalEtaSeconds: etaFinal,
    );
  }

  double _estimateHistoricalEtaFromChunks({
    required double fromProgressMeters,
    required double toProgressMeters,
    required String bucket,
    required RoadDirection direction,
    required String jeepType,
  }) {
    final chunkIds = _chunkIdsBetween(fromProgressMeters, toProgressMeters);
    var total = 0.0;
    for (final chunkId in chunkIds) {
      total += _estimatedChunkTravelTimeSecondsByType(
        chunkId: chunkId,
        bucket: bucket,
        direction: direction,
        jeepType: jeepType,
      );
    }
    return total;
  }

  double _trafficFactorForRange({
    required double fromProgressMeters,
    required double toProgressMeters,
    required RoadDirection direction,
  }) {
    final chunkIds = _chunkIdsBetween(fromProgressMeters, toProgressMeters);
    if (chunkIds.isEmpty) {
      return 1;
    }

    var ratioSum = 0.0;
    var ratioCount = 0;
    for (final chunkId in chunkIds) {
      final normalSpeed = _normalSpeedForChunk(chunkId, direction);
      final currentSpeed = _currentSpeedForChunk(chunkId, direction);
      if (normalSpeed <= 0 || currentSpeed <= 0) {
        continue;
      }
      ratioSum += (normalSpeed / currentSpeed).clamp(0.6, 3.0);
      ratioCount++;
    }
    if (ratioCount == 0) {
      return 1;
    }
    return ratioSum / ratioCount;
  }

  double _normalSpeedForChunk(int chunkId, RoadDirection direction) {
    final chunk = _routeChunks[chunkId];
    final normalTime = chunk.avgTravelTimeAll > 0
        ? chunk.avgTravelTimeAll
        : _estimatedChunkTravelTimeSeconds(
            chunkId: chunkId,
            bucket: _timeBucketKey(DateTime.now()),
            direction: direction,
          );
    return chunk.lengthMeters / normalTime.clamp(0.1, 1000.0);
  }

  double _currentSpeedForChunk(int chunkId, RoadDirection direction) {
    final chunk = _routeChunks[chunkId];
    final directionalSamples = direction == RoadDirection.forward
        ? chunk.forwardTravelSamples
        : chunk.backwardTravelSamples;
    if (directionalSamples.isEmpty) {
      return _normalSpeedForChunk(chunkId, direction);
    }
    final recentCount = directionalSamples.length < 5
        ? directionalSamples.length
        : 5;
    var sum = 0.0;
    for (
      int i = directionalSamples.length - recentCount;
      i < directionalSamples.length;
      i++
    ) {
      sum += directionalSamples[i];
    }
    final recentTime = sum / recentCount;
    return chunk.lengthMeters / recentTime.clamp(0.1, 1000.0);
  }

  double _confidenceForRange({
    required double fromProgressMeters,
    required double toProgressMeters,
    required String bucket,
    required RoadDirection direction,
  }) {
    final chunkIds = _chunkIdsBetween(fromProgressMeters, toProgressMeters);
    if (chunkIds.isEmpty) {
      return 0;
    }

    int sampleCount = 0;
    double weightedVariance = 0;
    for (final chunkId in chunkIds) {
      final chunk = _routeChunks[chunkId];
      final map = direction == RoadDirection.forward
          ? chunk.forwardSamplesByBucket
          : chunk.backwardSamplesByBucket;
      final samples = map[bucket] ?? <double>[];
      sampleCount += samples.length;
      weightedVariance += _variance(samples);
    }

    final avgVariance = weightedVariance / chunkIds.length;
    final sampleFactor = (sampleCount / 80).clamp(0.0, 1.0);
    final varianceFactor = 1 / (1 + (avgVariance / 80));
    return ((sampleFactor * 0.6) + (varianceFactor * 0.4)) * 100;
  }

  List<int> _chunkIdsBetween(
    double fromProgressMeters,
    double toProgressMeters,
  ) {
    final fromChunk = _chunkIdForProgress(fromProgressMeters);
    final toChunk = _chunkIdForProgress(toProgressMeters);
    if (fromChunk == toChunk) {
      return [fromChunk];
    }

    final ids = <int>[];
    final step = fromChunk < toChunk ? 1 : -1;
    int current = fromChunk;
    while (true) {
      ids.add(current);
      if (current == toChunk) {
        break;
      }
      current += step;
    }
    return ids;
  }

  double _estimatedChunkTravelTimeSeconds({
    required int chunkId,
    required String bucket,
    required RoadDirection direction,
  }) {
    final chunk = _routeChunks[chunkId];
    final bucketMap = direction == RoadDirection.forward
        ? chunk.forwardAverageByBucket
        : chunk.backwardAverageByBucket;
    final bucketAvg = bucketMap[bucket];
    if (bucketAvg != null && bucketAvg > 0) {
      return bucketAvg;
    }
    final directionalAvg = direction == RoadDirection.forward
        ? chunk.forwardAvgTravelTime
        : chunk.backwardAvgTravelTime;
    if (directionalAvg > 0) {
      return directionalAvg;
    }
    return chunk.lengthMeters / _SimulationScreenState._defaultJeepSpeed;
  }

  double _estimatedChunkTravelTimeSecondsByType({
    required int chunkId,
    required String bucket,
    required RoadDirection direction,
    required String jeepType,
  }) {
    final chunk = _routeChunks[chunkId];
    final byType = chunk.avgTravelTimeByType[jeepType];
    if (byType != null && byType > 0) {
      return byType;
    }
    return _estimatedChunkTravelTimeSeconds(
      chunkId: chunkId,
      bucket: bucket,
      direction: direction,
    );
  }

  double _averageArrivalIntervalSeconds(int chunkId) {
    if (chunkId >= 0 && chunkId < _routeChunks.length) {
      final chunkAverage = _routeChunks[chunkId].avgArrivalIntervalAll;
      if (chunkAverage > 0) {
        return chunkAverage;
      }
    }
    final logs = _pinArrivalLogsByChunk[chunkId] ?? <DateTime>[];
    if (logs.length < 2) {
      return 0;
    }
    final intervals = <double>[];
    for (int i = 1; i < logs.length; i++) {
      intervals.add(logs[i].difference(logs[i - 1]).inMilliseconds / 1000);
    }
    return intervals.reduce((a, b) => a + b) / intervals.length;
  }

  double _slowdownMultiplierForChunk(int chunkId) {
    if (!_trafficEnabled) {
      return 1;
    }
    var maxMultiplier = 1.0;
    for (final zone in _trafficZones) {
      if (zone.chunkId == chunkId && zone.slowdownMultiplier > maxMultiplier) {
        maxMultiplier = zone.slowdownMultiplier;
      }
    }
    return maxMultiplier;
  }

  double _variance(List<double> values) {
    if (values.length < 2) {
      return 0;
    }
    final mean = values.reduce((a, b) => a + b) / values.length;
    var sumSq = 0.0;
    for (final value in values) {
      final d = value - mean;
      sumSq += d * d;
    }
    return sumSq / (values.length - 1);
  }
}
