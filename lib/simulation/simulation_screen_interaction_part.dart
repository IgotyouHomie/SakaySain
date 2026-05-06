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

    final wasPlacingMock = _isPlacingMockUser;
    _applyState(() {
      if (_isPlacingTrafficZone) {
        _placeTrafficZoneAt(insideWorldPoint);
        _isPlacingTrafficZone = false;
      } else if (_isPlacingMockUser) {
        // defer opening modal until after state update to avoid build-time dialog
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

    if (wasPlacingMock) {
      _openMockJeepPlacementPanel(insideWorldPoint);
    }
  }

  User? _pickUserNearPoint(Offset point) {
    User? closest;
    var minDistance = double.infinity;

    final thresholdWorld =
        (_SimulationScreenState._selectionTapThreshold / _zoom).clamp(
          6.0,
          40.0,
        );

    for (final user in _users) {
      final distance = _distanceBetween(point, user.position);
      if (distance <= thresholdWorld && distance < minDistance) {
        minDistance = distance;
        closest = user;
      }
    }

    return closest;
  }

  String _routeLabelForId(String routeId) {
    for (final route in _availableRoutes) {
      if (route.id == routeId) {
        return route.jeepName;
      }
    }
    return routeId;
  }

  ({Offset point, int segmentIndex, double t}) _nearestPointOnPath(
    List<Offset> path,
    Offset point,
  ) {
    var closestPoint = path.first;
    var closestSegmentIndex = 0;
    var closestT = 0.0;
    var minDistance = double.infinity;

    for (int segmentIndex = 0; segmentIndex < path.length - 1; segmentIndex++) {
      final projection = _projectPointToSegment(
        point,
        path[segmentIndex],
        path[segmentIndex + 1],
      );
      final distance = _distanceBetween(point, projection.point);
      if (distance < minDistance) {
        minDistance = distance;
        closestPoint = projection.point;
        closestSegmentIndex = segmentIndex;
        closestT = projection.t;
      }
    }

    return (
      point: closestPoint,
      segmentIndex: closestSegmentIndex,
      t: closestT,
    );
  }

  Future<void> _openMockJeepPlacementPanel(Offset worldPoint) async {
    if (_availableJeepTypes.isEmpty || _availableRoutes.isEmpty) {
      _placeMockUserAt(worldPoint);
      return;
    }

    final firstJeepType = _availableJeepTypes.first;
    String selectedJeepType = firstJeepType.name;
    String selectedRouteId = firstJeepType.assignedRouteId;

    final result = await showModalBottomSheet<({String jeepType, String routeId})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final selectedJeep = _availableJeepTypes.firstWhere(
              (jt) => jt.name == selectedJeepType,
              orElse: () => firstJeepType,
            );
            final assignedRouteId = selectedJeep.assignedRouteId;
            final isRouteMatch = selectedRouteId == assignedRouteId;
            final assignedRouteLabel = _routeLabelForId(assignedRouteId);

            return SafeArea(
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF164E4A),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Place Jeep',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Choose a jeep type and the route it is allowed to run on.',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedJeepType,
                      dropdownColor: const Color(0xFF0D3D3B),
                      decoration: const InputDecoration(
                        labelText: 'Jeep Type',
                        labelStyle: TextStyle(color: Colors.white70),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF2E9E99)),
                        ),
                      ),
                      items: _availableJeepTypes
                          .map(
                            (jt) => DropdownMenuItem(
                              value: jt.name,
                              child: Text(
                                '${jt.name}  •  ${_routeLabelForId(jt.assignedRouteId)}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        final jeep = _availableJeepTypes.firstWhere(
                          (jt) => jt.name == value,
                          orElse: () => firstJeepType,
                        );
                        setModalState(() {
                          selectedJeepType = jeep.name;
                          selectedRouteId = jeep.assignedRouteId;
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: selectedRouteId,
                      dropdownColor: const Color(0xFF0D3D3B),
                      decoration: const InputDecoration(
                        labelText: 'Route',
                        labelStyle: TextStyle(color: Colors.white70),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF2E9E99)),
                        ),
                      ),
                      items: _availableRoutes
                          .map(
                            (route) => DropdownMenuItem(
                              value: route.id,
                              child: Text(
                                route.jeepName,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setModalState(() => selectedRouteId = value);
                      },
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isRouteMatch
                            ? Colors.green.withValues(alpha: 0.14)
                            : Colors.redAccent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isRouteMatch
                              ? Colors.green.withValues(alpha: 0.5)
                              : Colors.redAccent.withValues(alpha: 0.6),
                        ),
                      ),
                      child: Text(
                        isRouteMatch
                            ? 'Ready: $selectedJeepType will run on $assignedRouteLabel.'
                            : 'Route mismatch: $selectedJeepType must use $assignedRouteLabel.',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: isRouteMatch
                                ? () => Navigator.pop(context, (
                                    jeepType: selectedJeepType,
                                    routeId: selectedRouteId,
                                  ))
                                : null,
                            child: const Text('Place Jeep'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (result == null || !mounted) {
      return;
    }

    final selectedJeep = _availableJeepTypes.firstWhere(
      (jt) => jt.name == result.jeepType,
      orElse: () => firstJeepType,
    );
    if (selectedJeep.assignedRouteId != result.routeId) {
      _showSnack(
        'Route mismatch: ${selectedJeep.name} must use ${_routeLabelForId(selectedJeep.assignedRouteId)}.',
      );
      return;
    }

    _placeMockUserAt(
      worldPoint,
      jeepType: selectedJeep.name,
      routeId: result.routeId,
    );
  }

  void _showRoadChunkStatsPanel(RoadChunk chunk) {
    if (!mounted) return;

    final allTypes = <String>{
      ...chunk.avgArrivalIntervalByType.keys,
      ...chunk.lastJeepPassTimeByType.keys,
      ...chunk.avgTravelTimeByType.keys,
      ...chunk.jeepArrivalProbabilityByType.keys,
    }.toList()..sort();

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
                  Text(
                    'All Jeeps: ${formatSeconds(chunk.avgArrivalIntervalAll)}',
                  ),
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
                      final interval =
                          chunk.avgArrivalIntervalByType[type] ?? 0;
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
                      final flow =
                          chunk.flowRateJeepsPerMinuteByType[type] ?? 0;
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
      _isPlacingTrafficZone = false;
      _isPlacingMockUser = false;
      _isPlacingRoadWaiterPin = false;
      _isRoadEditorMode = false;
      _isAddingRoadPoints = false;
      _draftRoutePoints.clear();
    });
    _randomizeTrafficZones();
  }

  /// Computes the actual compass-like label for a road chunk direction.
  /// Uses the vector angle of the chunk segment — not hardcoded L/R.
  String _directionLabel(Offset from, Offset to, bool isForward) {
    final dx = isForward ? (to.dx - from.dx) : (from.dx - to.dx);
    final dy = isForward ? (to.dy - from.dy) : (from.dy - to.dy);
    // atan2: y-axis is inverted in canvas space (dy positive = down)
    final angle = math.atan2(-dy, dx) * 180 / math.pi;
    // Map angle to cardinal/intercardinal
    if (angle >= -22.5 && angle < 22.5) return 'East →';
    if (angle >= 22.5 && angle < 67.5) return 'North-East ↗';
    if (angle >= 67.5 && angle < 112.5) return 'North ↑';
    if (angle >= 112.5 && angle < 157.5) return 'North-West ↖';
    if (angle >= 157.5 || angle < -157.5) return '← West';
    if (angle >= -157.5 && angle < -112.5) return 'South-West ↙';
    if (angle >= -112.5 && angle < -67.5) return 'South ↓';
    return 'South-East ↘';
  }

  Future<void> _openDirectionSelectionPanel() async {
    // Derive real direction labels from the pinned road chunk angle
    String forwardLabel = 'Forward direction';
    String backwardLabel = 'Backward direction';

    if (_roadWaiterPin != null) {
      final pin = _roadWaiterPin!;
      if (pin.chunkId >= 0 && pin.chunkId < _routeChunks.length) {
        final chunk = _routeChunks[pin.chunkId];
        forwardLabel = _directionLabel(chunk.startPoint, chunk.endPoint, true);
        backwardLabel = _directionLabel(
          chunk.startPoint,
          chunk.endPoint,
          false,
        );
      } else {
        // Use generic labels for chunks with no intelligence yet
        forwardLabel = 'Forward direction (new)';
        backwardLabel = 'Backward direction (new)';
      }
    }

    final result = await showModalBottomSheet<RoadDirection>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1E7A76),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Which direction are you waiting for jeeps from?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                'Direction is based on the road chunk angle.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              // Backward = jeeps coming FROM that direction toward user
              GestureDetector(
                onTap: () => Navigator.pop(context, RoadDirection.backward),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.3)),
                  ),
                  child: Text(
                    backwardLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Forward = jeeps coming from forward direction
              GestureDetector(
                onTap: () => Navigator.pop(context, RoadDirection.forward),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E9E99),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2E9E99).withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Text(
                    forwardLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => Navigator.pop(context, null),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  alignment: Alignment.center,
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white60, fontSize: 14),
                  ),
                ),
              ),
            ],
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

  void _placeMockUserAt(
    Offset worldPoint, {
    String? jeepType,
    String? routeId,
  }) {
    final nextId = (_users.map((user) => user.id).fold<int>(0, math.max)) + 1;
    final nearest = _findNearestRoadPoint(worldPoint);
    final resolvedJeepType = jeepType ?? _assignJeepType(nextId);

    // If a specific routeId is given, find the matching route profile path
    List<Offset>? routePath;
    if (routeId != null) {
      final profile = _routeProfilesByJeepType[resolvedJeepType];
      if (profile != null && profile.worldPath.length >= 2) {
        routePath = profile.worldPath;
      }
    }

    if (nearest.distanceToRoad <= _SimulationScreenState._roadSnapThreshold) {
      final movingUser = User(
        id: nextId,
        position: nearest.point,
        speed: _SimulationScreenState._defaultJeepSpeed,
        direction: const Offset(1, 0),
        visibilityRadius: 100,
        jeepType: resolvedJeepType,
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
          jeepType: resolvedJeepType,
          isMockUser: true,
        ),
      );
    }

    _controlUserId = nextId;
    // routePath stored for future per-jeep route isolation feature
    if (routePath != null && routePath.length >= 2) {
      // Future: constrain this jeep to its own route path
    }
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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  RoadChunk? _pickRoadChunkAtPoint(Offset point) {
    RoadChunk? closest;
    var minDistance = double.infinity;

    final thresholdWorld =
        (_SimulationScreenState._selectionTapThreshold / _zoom).clamp(
          4.0,
          30.0,
        );

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
    final topFlowChunks =
        _routeChunks.where((c) => c.flowRateJeepsPerMinute > 0).toList()..sort(
          (a, b) =>
              b.flowRateJeepsPerMinute.compareTo(a.flowRateJeepsPerMinute),
        );
    final top3 = topFlowChunks.take(3).toList();

    final threshold = (_SimulationScreenState._selectionTapThreshold / _zoom)
        .clamp(8.0, 40.0);

    for (final chunk in top3) {
      final center = Offset(
        (chunk.startPoint.dx + chunk.endPoint.dx) / 2,
        (chunk.startPoint.dy + chunk.endPoint.dy) / 2,
      );
      if (_distanceBetween(point, center) <= threshold) {
        return chunk;
      }
    }
    return null;
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
