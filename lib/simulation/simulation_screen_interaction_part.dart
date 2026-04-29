part of 'simulation_screen.dart';

extension _SimulationScreenInteractionPart on _SimulationScreenState {
  void _handleMapTap(TapUpDetails details) {
    final scenePoint = _transformationController.toScene(details.localPosition);
    final worldPoint = _sceneToWorld(scenePoint);
    final insideWorldPoint = _clampToWorld(worldPoint);

    // V4 ROAD EDITOR MODE: tap to create route points
    if (_isRoadEditorMode && _isAddingRoadPoints) {
      _applyState(() {
        _draftRoutePoints.add(insideWorldPoint);
        _frame++;
      });
      return;
    }

    // Place road waiter pin
    if (_isPlacingRoadWaiterPin) {
      _applyState(() {
        _roadWaiterPin = _findNearestRoadPoint(insideWorldPoint);
        _selectedPinDirection = null;
        _isPlacingRoadWaiterPin = false;
        _frame++;
      });
      _openDirectionSelectionPanel();
      return;
    }

    final visibilityByUser = _buildVisibilityByUser(_users);
    final visibleToPhone =
        visibilityByUser[_SimulationScreenState._phoneUserId] ?? <int>{};
    final clusterInfos = _buildVisibleMovingClusters(visibleToPhone);

    final tappedCluster = _pickClusterAtPoint(insideWorldPoint, clusterInfos);
    if (tappedCluster != null) {
      _showClusterInfoPanel(tappedCluster);
      return;
    }

    final tappedTopFlowChunk = _pickTopFlowBadgeChunkAtPoint(insideWorldPoint);
    if (_devShowChunkStats && tappedTopFlowChunk != null) {
      _showRoadChunkStatsPanel(tappedTopFlowChunk);
      return;
    }

    final tappedChunk = _pickRoadChunkAtPoint(insideWorldPoint);
    if (_devShowChunkStats && tappedChunk != null) {
      _showRoadChunkStatsPanel(tappedChunk);
      return;
    }

    if (!_isDeveloperMode) {
      return;
    }

    _applyState(() {
      if (_isPlacingTrafficZone) {
        _placeTrafficZoneAt(insideWorldPoint);
        _isPlacingTrafficZone = false;
      } else if (_isPlacingMockUser) {
        _placeMockUserAt(insideWorldPoint);
        _isPlacingMockUser = false;
      } else {
        final selectedFromTap = _pickUserNearPoint(insideWorldPoint);
        if (selectedFromTap != null && selectedFromTap.isMockUser) {
          _controlUserId = selectedFromTap.id;
        } else {
          _phoneUser.position = insideWorldPoint;
          _lastManualPhoneRepositionAt = DateTime.now();
          _controlUserId = _SimulationScreenState._phoneUserId;
        }
      }

      _frame++;
    });
  }

  User? _pickUserNearPoint(Offset point) {
    User? closest;
    var minDistance = double.infinity;

    for (final user in _users) {
      final distance = _distanceBetween(point, user.position);
      if (distance <= _SimulationScreenState._selectionTapThreshold &&
          distance < minDistance) {
        closest = user;
        minDistance = distance;
      }
    }
    return closest;
  }

  RoadChunk? _pickRoadChunkAtPoint(Offset point) {
    final thresholdWorld = (20 / _zoom).clamp(8.0, 26.0);
    RoadChunk? closest;
    var minDistance = double.infinity;

    for (final chunk in _routeChunks) {
      final distance = _distancePointToSegment(
        point,
        chunk.startPoint,
        chunk.endPoint,
      );
      if (distance <= thresholdWorld && distance < minDistance) {
        minDistance = distance;
        closest = chunk;
      }
    }
    return closest;
  }

  RoadChunk? _pickTopFlowBadgeChunkAtPoint(Offset point) {
    if (!_showFlowHeatOverlay || _routeChunks.isEmpty) {
      return null;
    }

    final topFlowChunks =
    _routeChunks.where((chunk) => chunk.flowRateJeepsPerMinute > 0).toList()
      ..sort(
            (a, b) =>
            b.flowRateJeepsPerMinute.compareTo(a.flowRateJeepsPerMinute),
      );

    final top3 = topFlowChunks.take(3);
    final thresholdWorld = (28 / _zoom).clamp(10.0, 38.0);

    RoadChunk? closest;
    var minDistance = double.infinity;

    for (final chunk in top3) {
      final center = Offset(
        (chunk.startPoint.dx + chunk.endPoint.dx) / 2,
        (chunk.startPoint.dy + chunk.endPoint.dy) / 2,
      );
      final distance = _distanceBetween(point, center);
      if (distance <= thresholdWorld && distance < minDistance) {
        minDistance = distance;
        closest = chunk;
      }
    }

    return closest;
  }

  void _showRoadChunkStatsPanel(RoadChunk chunk) {
    if (!mounted) return;

    final allTypes = <String>{
      ...chunk.avgArrivalIntervalByType.keys,
      ...chunk.lastJeepPassTimeByType.keys,
      ...chunk.avgTravelTimeByType.keys,
      ...chunk.jeepArrivalProbabilityByType.keys,
    }.toList()
      ..sort();

    String formatSeconds(double value) {
      if (value <= 0) return 'N/A';
      return '${value.toStringAsFixed(1)}s';
    }

    String formatTime(DateTime? value) {
      if (value == null) return 'N/A';
      final h = value.hour.toString().padLeft(2, '0');
      final m = value.minute.toString().padLeft(2, '0');
      final s = value.second.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'ROAD CHUNK ${chunk.forwardDirectionLabel.replaceAll(' -> ', '-')}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Forward: ${chunk.forwardDirectionLabel}'),
                  Text('Reverse: ${chunk.reverseDirectionLabel}'),
                  const SizedBox(height: 10),
                  const Text(
                    'Average Arrival Interval',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text('All Jeeps: ${formatSeconds(chunk.avgArrivalIntervalAll)}'),
                  Text(
                    'Observed: ${formatSeconds(chunk.avgArrivalIntervalAllObserved)}',
                  ),
                  Text(
                    'Speculative: ${formatSeconds(chunk.avgArrivalIntervalAllSpeculative)}',
                  ),
                  const SizedBox(height: 8),
                  if (allTypes.isEmpty)
                    const Text('No per-type interval data yet')
                  else
                    ...allTypes.map((type) {
                      final interval = chunk.avgArrivalIntervalByType[type] ?? 0;
                      final observed =
                          chunk.avgArrivalIntervalByTypeObserved[type] ?? 0;
                      final speculative =
                          chunk.avgArrivalIntervalByTypeSpeculative[type] ?? 0;
                      return Text(
                        '$type: ${formatSeconds(interval)} (obs ${formatSeconds(observed)}, spec ${formatSeconds(speculative)})',
                      );
                    }),
                  const SizedBox(height: 10),
                  const Text(
                    'Average Travel Time',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text('All Jeeps: ${formatSeconds(chunk.avgTravelTimeAll)}'),
                  const SizedBox(height: 8),
                  if (allTypes.isEmpty)
                    const Text('No per-type travel-time data yet')
                  else
                    ...allTypes.map((type) {
                      final value = chunk.avgTravelTimeByType[type] ?? 0;
                      return Text('$type: ${formatSeconds(value)}');
                    }),
                  const SizedBox(height: 10),
                  const Text(
                    'Last Jeep Pass',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text('All Jeeps: ${formatTime(chunk.lastJeepPassTime)}'),
                  Text(
                    'Observed: ${formatTime(chunk.lastJeepPassTimeObserved)}',
                  ),
                  Text(
                    'Speculative: ${formatTime(chunk.lastJeepPassTimeSpeculative)}',
                  ),
                  const SizedBox(height: 8),
                  if (allTypes.isEmpty)
                    const Text('No per-type pass times yet')
                  else
                    ...allTypes.map((type) {
                      final observed =
                      chunk.lastJeepPassTimeByTypeObserved[type];
                      final speculative =
                      chunk.lastJeepPassTimeByTypeSpeculative[type];
                      final merged = chunk.lastJeepPassTimeByType[type];
                      return Text(
                        '$type: ${formatTime(merged)} (obs ${formatTime(observed)}, spec ${formatTime(speculative)})',
                      );
                    }),
                  const SizedBox(height: 10),
                  Text('Observed pass count: ${chunk.observedPassCount}'),
                  Text('Speculative pass count: ${chunk.speculativePassCount}'),
                  const SizedBox(height: 10),
                  const Text(
                    'Jeep Probability Map',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (allTypes.isEmpty)
                    const Text('No probability data yet')
                  else
                    ...allTypes.map((type) {
                      final probability =
                          chunk.jeepArrivalProbabilityByType[type] ?? 0;
                      return Text('$type: ${probability.toStringAsFixed(0)}%');
                    }),
                  const SizedBox(height: 10),
                  const Text(
                    'Jeep Flow Estimation',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'All Jeeps: ${chunk.flowRateJeepsPerMinute.toStringAsFixed(2)} jeeps/min',
                  ),
                  if (allTypes.isEmpty)
                    const Text('No per-type flow data yet')
                  else
                    ...allTypes.map((type) {
                      final flow = chunk.flowRateJeepsPerMinuteByType[type] ?? 0;
                      return Text(
                        '$type: ${flow.toStringAsFixed(2)} jeeps/min',
                      );
                    }),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _startAddMockUser() {
    if (!_isDeveloperMode) return;
    _applyState(() {
      _isPlacingMockUser = true;
      _isPlacingTrafficZone = false;
      _isPlacingRoadWaiterPin = false;
      _isRoadEditorMode = false;
      _isAddingRoadPoints = false;
      _draftRoutePoints.clear();
    });
  }

  void _togglePlaceTrafficZone() {
    if (!_isDeveloperMode) return;
    _applyState(() {
      _isPlacingTrafficZone = !_isPlacingTrafficZone;
      if (_isPlacingTrafficZone) {
        _isPlacingMockUser = false;
        _isPlacingRoadWaiterPin = false;
        _isRoadEditorMode = false;
        _isAddingRoadPoints = false;
        _draftRoutePoints.clear();
      }
    });
  }

  Future<void> _openDirectionSelectionPanel() async {
    final result = await showModalBottomSheet<RoadDirection>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Choose jeep arrival direction',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, RoadDirection.backward),
                  child: const Text('← From Left Direction (BACKWARD)'),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, RoadDirection.forward),
                  child: const Text('From Right Direction → (FORWARD)'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (result != null && mounted) {
      _applyState(() {
        _selectedPinDirection = result;
        _startRoadWaitMeasurement();
      });
    }
  }

  double _resolvePredictedEtaSeconds({
    required DateTime now,
    required TrackedEta? initialEta,
  }) {
    if (initialEta != null) {
      return initialEta.etaSeconds;
    }
    final pin = _roadWaiterPin;
    final dir = _selectedPinDirection;
    if (pin != null && dir != null) {
      return _flowOnlyEtaForPin(pin: pin, direction: dir);
    }
    return 0;
  }

  void _startRoadWaitMeasurement() {
    final pin = _roadWaiterPin;
    final direction = _selectedPinDirection;
    if (pin == null || direction == null) {
      return;
    }

    final candidateIds = _users
        .where((user) => !user.isPhoneUser && user.isMoving)
        .map((user) => user.id)
        .toSet();

    final eta = _computeNearestIncomingEta(
      roadWaiterPin: pin,
      selectedDirection: direction,
      candidateUserIds: candidateIds,
    );

    final predictedEtaSeconds = _resolvePredictedEtaSeconds(
      now: DateTime.now(),
      initialEta: eta,
    );

    _isWaitingForJeep = true;
    _waitStartAt = DateTime.now();
    _waitPredictedEtaSeconds = predictedEtaSeconds;
    _waitPredictedEtaSamples
      ..clear()
      ..add(predictedEtaSeconds);
    _lastWaitPredictionSampleAt = DateTime.now();
    _waitPredictionStabilityAccumulator = 0;
    _waitPredictionStabilitySamples = 0;
    _waitPreviousPredictionSample = predictedEtaSeconds;
    _waitPredictedTrafficFactor = eta?.trafficFactor ?? 1;
    _waitUsedGhostCandidate = eta?.isGhost ?? false;
    _waitPredictionSource = eta?.predictionSource ?? 'Unknown';
    _waitPredictionMethod = eta?.predictionMethod ?? 'Unknown';
    _waitConfidenceLabel = eta?.confidenceLabel ?? 'LOW';
    _waitPredictionDistanceMeters = eta?.distanceMeters ?? 0;
    _waitPredictionWindowMinSeconds = eta?.predictionMinSeconds ?? 0;
    _waitPredictionWindowMaxSeconds = eta?.predictionMaxSeconds ?? 0;
    _waitPredictionGeneratedAt = DateTime.now();
    _pendingFoundJeepVerification = false;
    _pendingFoundJeepAt = null;
    _pendingFoundJeepMaxSpeed = 0;
    _isPassengerUser = false;
  }

  Future<void> _openJeepTypeSelectionPanel() async {
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      builder: (context) {
        final tempSelection = Set<String>.from(_selectedJeepTypes);
        return StatefulBuilder(
          builder: (context, setModalState) {
            final isAllSelected = tempSelection.length == 3;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select jeep types',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Select All'),
                      value: isAllSelected,
                      onChanged: (value) {
                        setModalState(() {
                          if (value == true) {
                            tempSelection
                              ..clear()
                              ..addAll(['Jeep A', 'Jeep B', 'Jeep C']);
                          } else {
                            tempSelection.clear();
                          }
                        });
                      },
                    ),
                    ...['Jeep A', 'Jeep B', 'Jeep C'].map((type) {
                      return CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(type),
                        value: tempSelection.contains(type),
                        onChanged: (value) {
                          setModalState(() {
                            if (value == true) {
                              tempSelection.add(type);
                            } else {
                              tempSelection.remove(type);
                            }
                          });
                        },
                      );
                    }),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(context, tempSelection),
                        child: const Text('Apply'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (result != null && mounted) {
      _applyState(() {
        _selectedJeepTypes = result;
      });
    }
  }

  void _placeMockUserAt(Offset worldPoint) {
    final nextId = (_users.map((user) => user.id).fold<int>(0, math.max)) + 1;
    final nearest = _findNearestRoadPoint(worldPoint);

    if (nearest.distanceToRoad <= _SimulationScreenState._roadSnapThreshold) {
      final movingUser = User(
        id: nextId,
        position: nearest.point,
        speed: _SimulationScreenState._defaultJeepSpeed,
        direction: const Offset(1, 0),
        visibilityRadius: 100,
        jeepType: _assignJeepType(nextId),
        isMockUser: true,
      );
      _users.add(movingUser);
      _movingStates[nextId] = MovingState(
        roadIndex: nearest.roadIndex,
        segmentIndex: nearest.segmentIndex,
        t: nearest.t,
        forward: true,
      );
      _recordTrailPoint(movingUser, movingUser.position);
      _initializeChunkTraversalFor(movingUser);
      _initializeKalmanStateFor(movingUser, DateTime.now());
    } else {
      _users.add(
        User(
          id: nextId,
          position: worldPoint,
          speed: 0,
          direction: const Offset(0, 0),
          visibilityRadius: 100,
          jeepType: _assignJeepType(nextId),
          isMockUser: true,
        ),
      );
    }

    _controlUserId = nextId;
  }

  void _placeTrafficZoneAt(Offset worldPoint) {
    final nearest = _findNearestRoadPoint(worldPoint);
    final road = _roadNetwork[nearest.roadIndex];
    final start = road[nearest.segmentIndex];
    final end = road[nearest.segmentIndex + 1];
    final roadVector = end - start;
    final roadDirection = _normalizeOffset(roadVector);

    final center = nearest.point;
    const halfLength = 20.0;
    final chunkId = _chunkIdForProgress(
      _progressAlongRoad(_routePath, nearest.segmentIndex, nearest.t),
    );

    final zone = TrafficZone(
      chunkId: chunkId,
      slowdownMultiplier: 1.5,
      start: Offset(
        center.dx - (roadDirection.dx * halfLength),
        center.dy - (roadDirection.dy * halfLength),
      ),
      end: Offset(
        center.dx + (roadDirection.dx * halfLength),
        center.dy + (roadDirection.dy * halfLength),
      ),
    );

    _trafficZones.insert(0, zone);
    if (_trafficZones.length > _maxTrafficLines) {
      _trafficZones.removeLast();
    }
  }

  void _randomizeTrafficZones() {
    _applyState(() {
      _trafficZones
        ..clear()
        ..addAll(_generateRandomTrafficZones(_maxTrafficLines));
    });
  }

  List<TrafficZone> _generateRandomTrafficZones(int count) {
    final zones = <TrafficZone>[];
    for (int i = 0; i < count; i++) {
      final roadIndex = _random.nextInt(_roadNetwork.length);
      final road = _roadNetwork[roadIndex];
      if (road.length < 2) {
        continue;
      }

      final segmentIndex = _random.nextInt(road.length - 1);
      final t = _random.nextDouble();
      final point = Offset.lerp(road[segmentIndex], road[segmentIndex + 1], t)!;
      final segment = road[segmentIndex + 1] - road[segmentIndex];
      final direction = _normalizeOffset(segment);

      const halfLength = 20.0;
      final progress = _progressAlongRoad(_routePath, segmentIndex, t);

      zones.add(
        TrafficZone(
          chunkId: _chunkIdForProgress(progress),
          slowdownMultiplier: 1.5,
          start: Offset(
            point.dx - (direction.dx * halfLength),
            point.dy - (direction.dy * halfLength),
          ),
          end: Offset(
            point.dx + (direction.dx * halfLength),
            point.dy + (direction.dy * halfLength),
          ),
        ),
      );
    }
    return zones;
  }

  ClusterInfo? _pickClusterAtPoint(Offset point, List<ClusterInfo> clusters) {
    final thresholdWorld =
    (_SimulationScreenState._clusterDistanceThresholdPx / _zoom)
        .clamp(8, 120)
        .toDouble();

    ClusterInfo? closest;
    var minDistance = double.infinity;
    for (final cluster in clusters) {
      final distance = _distanceBetween(point, cluster.center);
      if (distance <= thresholdWorld && distance < minDistance) {
        closest = cluster;
        minDistance = distance;
      }
    }

    return closest;
  }

  void _showClusterInfoPanel(ClusterInfo cluster) {
    if (!mounted) {
      return;
    }

    final sortedJeepTypes = cluster.jeepTypes.toList()..sort();
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Cluster Information',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text('Users detected: ${cluster.userCount}'),
                const SizedBox(height: 10),
                const Text(
                  'Jeep types nearby:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                if (sortedJeepTypes.isEmpty)
                  const Text('None')
                else
                  ...sortedJeepTypes.map((type) => Text('• $type')),
              ],
            ),
          ),
        );
      },
    );
  }
}
