import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/road_network_engine.dart';
import '../services/passenger_service.dart';
import '../simulation/models/road_chunk.dart';
import '../simulation/models/road_direction.dart';
import '../simulation/models/tracked_eta.dart';
import 'passenger_mode_screen.dart';

// ═══════════════════════════════════════════════════════════════════════════
// FIND JEEP FLOW — Full state machine
//
// ACTIVE STATES (implemented):
//   moving          → Map fullscreen + "APPLY A WAITING PIN" button
//   pickingJeepType → Bottom sheet: jeep type dropdown, Back / Find
//   waiting         → Live timer, confidence/ETA chips, Cancel / Jeep Arrived
//   arrived         → Summary, star rating, Verify your Jeep
//
// ON-HOLD STUBS — wired into enum but NOT yet implemented.
// DO NOT REMOVE. These will be built in future sprints:
//   snapzoneCheck       → checks if user is within a valid snap zone on road
//   placeWaitingPin     → lets user drag a pin to exact waiting spot on road
//   passengerValidation → QR/code scan to verify correct jeep boarded
//   passengerMode       → in-ride tracking screen
//   rideDataCollection  → collects speed, route, stop data during ride
//   exitOrGhostJeep     → handles normal exit vs ghost jeep scenario
//   systemImproves      → feeds anonymized data back to prediction model
// ═══════════════════════════════════════════════════════════════════════════

enum _JeepFlowState {
  // ── ACTIVE ──
  moving,
  pickingJeepType,
  waiting,
  arrived,

  // ── ON-HOLD (future sprints) ──
  snapzoneCheck, // TODO: snap-to-road zone validation
  placeWaitingPin, // TODO: draggable pin placement on road segment
  passengerValidation, // TODO: QR / jeep code verification
  passengerMode, // TODO: in-ride passenger tracking UI
  rideDataCollection, // TODO: speed, route, stop data collection
  exitOrGhostJeep, // TODO: exit flow + ghost jeep detection
  systemImproves, // TODO: post-ride data submission to model
}

class FindJeepFlowScreen extends StatefulWidget {
  final LatLng userLocation;
  const FindJeepFlowScreen({super.key, required this.userLocation});

  @override
  State<FindJeepFlowScreen> createState() => _FindJeepFlowState();
}

class _FindJeepFlowState extends State<FindJeepFlowScreen>
    with TickerProviderStateMixin {
  static const double _maxPinDistanceMeters = 100;

  _JeepFlowState _flowState = _JeepFlowState.moving;

  final Completer<GoogleMapController> _mapController = Completer();

  // ── Road network intelligence ──────────────────────────────────────────
  List<RoadChunk> _allChunks = [];
  RoadChunk? _selectedChunk; // chunk user is in snapzone of
  RoadChunk? _waitingPinChunk; // chunk waiting pin is snapped to
  RoadDirection? _selectedDirection; // forward or backward on road
  bool _isInSnapzone = false;
  String _snapzoneStatus = 'Finding jeep stop locations near you...';
  bool _loadingNetwork = true;
  LatLng _currentUserLocation = const LatLng(0, 0);
  StreamSubscription<Position>? _positionStream;

  // Real ETA data from RoadNetworkEngine (hybrid: historical + traffic + ghost)
  TrackedEta? _realEta;
  List<RoadChunk> _etaPathChunks = []; // chunks between user and waiting pin

  // Waiting pin — snapped to nearest road segment
  late LatLng _waitingPinLocation;

  // Jeep type picker
  String? _selectedJeepType;

  // Live wait timer
  Timer? _waitTimer;
  int _waitSeconds = 0;
  double _waitInitialEtaSeconds = 0;
  double _waitCurrentEtaSeconds = 0;
  double _waitPredictionStabilityAccumulator = 0;
  int _waitPredictionStabilitySamples = 0;
  double? _waitPreviousEtaSample;
  DateTime? _waitPredictionGeneratedAt;

  // Arrived stats (mock values — replace with real backend data)
  int _actualWaitSeconds = 0;
  double _accuracy = 0;
  double _predictedArrival = 0;
  double _initialPrediction = 0;
  int _starRating = 0;

  // Sheet slide animation
  late AnimationController _sheetAnimCtrl;
  late Animation<Offset> _sheetSlide;

  @override
  void initState() {
    super.initState();
    _currentUserLocation = widget.userLocation;

    // Start with user location as fallback
    _waitingPinLocation = widget.userLocation;

    _startLiveUserTracking();

    // Load road network and check snapzone
    _initializeNetwork();

    _sheetAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _sheetSlide = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _sheetAnimCtrl, curve: Curves.easeOutCubic),
        );
  }

  /// Initialize road network and validate user location
  Future<void> _initializeNetwork() async {
    try {
      final network = await RoadNetworkEngine.buildRoadNetwork();
      if (mounted) {
        setState(() {
          _allChunks = network.allChunks;
          _loadingNetwork = false;
        });
      }
      // Check snapzone immediately
      _validateSnapzone();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingNetwork = false;
          _snapzoneStatus = 'Could not load route data';
        });
      }
    }
  }

  Future<void> _startLiveUserTracking() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      _positionStream =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 3,
            ),
          ).listen((position) {
            if (!mounted) return;

            setState(() {
              _currentUserLocation = LatLng(
                position.latitude,
                position.longitude,
              );
            });

            _validateSnapzone();
            _enforceWaitingPinProximity();
          });
    } catch (_) {
      // Keep fallback location when live tracking is unavailable.
    }
  }

  /// Check if user is in a valid snapzone and update UI
  void _validateSnapzone() {
    if (_allChunks.isEmpty) return;

    final snapzone = RoadNetworkEngine.findUserSnapzoneChunk(
      _currentUserLocation,
      _allChunks,
    );

    if (mounted) {
      setState(() {
        _isInSnapzone = snapzone != null;
        _selectedChunk = snapzone?.chunk;

        if (_isInSnapzone) {
          _snapzoneStatus = 'Ready to find jeep • Tap waiting pin button below';
          // Keep waiting pin synced while still in "moving" stage.
          if (_flowState == _JeepFlowState.moving && _waitingPinChunk == null) {
            final snappedPin = RoadNetworkEngine.snapWaitingPinToRoad(
              _currentUserLocation,
              _selectedChunk!,
            );
            _waitingPinLocation = snappedPin;
          }
        } else {
          _snapzoneStatus = 'Move closer to a road to find a jeep';
        }
      });
    }
  }

  bool _enforceWaitingPinProximity() {
    if (_waitingPinChunk == null) return false;

    final distance = _distanceMeters(_currentUserLocation, _waitingPinLocation);
    if (distance <= _maxPinDistanceMeters) return false;

    _waitTimer?.cancel();
    if (mounted) {
      setState(() {
        _flowState = _JeepFlowState.moving;
        _waitingPinChunk = null;
        _selectedDirection = null;
        _realEta = null;
        _etaPathChunks = [];
        _waitSeconds = 0;
        _waitInitialEtaSeconds = 0;
        _waitCurrentEtaSeconds = 0;
        _waitPredictionStabilityAccumulator = 0;
        _waitPredictionStabilitySamples = 0;
        _waitPreviousEtaSample = null;
        _waitPredictionGeneratedAt = null;
        _snapzoneStatus =
            'You moved too far from the waiting pin. Repin on your nearest road.';
      });
      _sheetAnimCtrl.reverse();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Waiting pin removed. Move near your road chunk and apply pin again.',
          ),
          backgroundColor: Color(0xFF2E9E99),
        ),
      );
    }

    return true;
  }

  double _distanceMeters(LatLng a, LatLng b) {
    return Geolocator.distanceBetween(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _positionStream?.cancel();
    _sheetAnimCtrl.dispose();
    super.dispose();
  }

  // ── Transitions ─────────────────────────────────────────────────────────

  /// Image 1 → Image 2: user taps "APPLY A WAITING PIN ON YOUR NEAREST ROAD"
  /// Validates snapzone and road snapping before proceeding to jeep type selection.
  void _onApplyWaitingPin() {
    if (!_isInSnapzone || _selectedChunk == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You must be on or near a road to find a jeep'),
          backgroundColor: Color(0xFF2E9E99),
        ),
      );
      return;
    }

    final snappedPin = RoadNetworkEngine.snapWaitingPinToRoad(
      _currentUserLocation,
      _selectedChunk!,
    );

    // Set waiting pin chunk = selected chunk for now
    setState(() {
      _waitingPinChunk = _selectedChunk;
      _waitingPinLocation = snappedPin;
    });

    // Show direction selector first
    _showDirectionSelector();
  }

  /// Show direction selector to determine forward/backward on road
  Future<void> _showDirectionSelector() async {
    final result = await showDialog<RoadDirection>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Direction'),
        content: const Text('Which direction do you want to go?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, RoadDirection.backward),
            child: const Text('Backward'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, RoadDirection.forward),
            child: const Text('Forward'),
          ),
        ],
      ),
    );

    if (result != null) {
      setState(() => _selectedDirection = result);
      // Now proceed to jeep type picker
      setState(() => _flowState = _JeepFlowState.pickingJeepType);
      _sheetAnimCtrl.forward(from: 0);
    }
  }

  /// Image 2 → Image 3: user picks jeep type and taps Find
  /// Computes real ETA using RoadNetworkEngine before transitioning to waiting.
  void _onFind() {
    if (_selectedJeepType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a jeep type first'),
          backgroundColor: Color(0xFF2E9E99),
        ),
      );
      return;
    }

    // Require direction selection
    if (_selectedDirection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a direction (forward/backward)'),
          backgroundColor: Color(0xFF2E9E99),
        ),
      );
      return;
    }

    // Build path from user chunk to waiting pin chunk
    final pathChunks = _buildEtaPath();
    if (pathChunks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not determine route path'),
          backgroundColor: Color(0xFF2E9E99),
        ),
      );
      return;
    }

    // Compute real ETA
    final eta = RoadNetworkEngine.predictEta(
      fromChunk: _selectedChunk!,
      toChunk: _waitingPinChunk!,
      pathChunks: pathChunks,
      jeepType: _selectedJeepType!,
      trafficSlowdownFactor: 1.0, // TODO: read from traffic zones
      direction: _selectedDirection!,
    );

    setState(() {
      _realEta = eta;
      _etaPathChunks = pathChunks;
      _waitInitialEtaSeconds = eta.etaSeconds;
      _waitCurrentEtaSeconds = eta.etaSeconds;
      _waitPredictionStabilityAccumulator = 0;
      _waitPredictionStabilitySamples = 0;
      _waitPreviousEtaSample = eta.etaSeconds;
      _waitPredictionGeneratedAt = DateTime.now();
      _flowState = _JeepFlowState.waiting;
      _waitSeconds = 0;
    });
    _sheetAnimCtrl.forward(from: 0);
    _startWaitTimer();
  }

  /// Build ETA path from user chunk to waiting pin chunk
  List<RoadChunk> _buildEtaPath() {
    if (_selectedChunk == null || _waitingPinChunk == null) return [];

    // For now, simple approach: if same chunk, return it; else assume adjacent
    // In full implementation, would use RoadGraph to find actual path
    if (_selectedChunk!.id == _waitingPinChunk!.id) {
      return [_selectedChunk!];
    }

    // Collect chunks in sequence (assumes road is sequential)
    final path = <RoadChunk>[];
    final start = _selectedChunk!.id;
    final end = _waitingPinChunk!.id;

    if (start < end) {
      for (int i = start; i <= end; i++) {
        try {
          path.add(_allChunks.firstWhere((c) => c.id == i));
        } catch (_) {}
      }
    } else {
      for (int i = start; i >= end; i--) {
        try {
          path.add(_allChunks.firstWhere((c) => c.id == i));
        } catch (_) {}
      }
    }

    return path.isNotEmpty ? path : [_selectedChunk!];
  }

  /// Image 2 Back button → back to moving state
  void _onBackFromPicking() {
    setState(() => _flowState = _JeepFlowState.moving);
    _sheetAnimCtrl.reverse();
  }

  /// Image 3 Cancel → exit flow entirely
  void _onCancel() {
    _waitTimer?.cancel();
    Navigator.of(context).pop();
  }

  /// Image 3 "Jeep Arrived" → Image 4
  void _onJeepArrived() {
    _waitTimer?.cancel();
    setState(() {
      _actualWaitSeconds = _waitSeconds;
      _predictedArrival = _waitCurrentEtaSeconds;
      _initialPrediction = _waitInitialEtaSeconds;
      _accuracy = _waitInitialEtaSeconds <= 0
          ? 0
          : (100 -
                    (((_waitSeconds - _waitInitialEtaSeconds).abs() /
                            _waitInitialEtaSeconds) *
                        100))
                .clamp(0, 100)
                .toDouble();
      _flowState = _JeepFlowState.arrived;
    });
    _sheetAnimCtrl.forward(from: 0);
  }

  /// Image 4 "Verify your Jeep" → Passenger Validation (Feature 9)
  void _onVerifyJeep() {
    // Get jeep type from selected value (mock jeep ID)
    final jeepType = _selectedJeepType ?? 'Unknown';
    final jeepId = 'JEEP_${DateTime.now().millisecondsSinceEpoch}';

    // Navigate to Passenger Validation screen
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PassengerValidationScreen(
          jeepId: jeepId,
          jeepType: jeepType,
          currentLocation: _currentUserLocation,
          onValidationComplete: _onPassengerValidationComplete,
        ),
      ),
    );
  }

  /// Callback when passenger validation completes (after 5 minutes)
  void _onPassengerValidationComplete() {
    // Validation passed, now show Passenger Mode
    final jeepType = _selectedJeepType ?? 'Unknown';
    final jeepId = 'JEEP_${DateTime.now().millisecondsSinceEpoch}';

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PassengerModeScreen(
          jeepId: jeepId,
          jeepType: jeepType,
          startLocation: _currentUserLocation,
          onExitTrip: _onPassengerExit,
        ),
      ),
    );
  }

  /// Callback when passenger exits the jeep
  void _onPassengerExit() {
    // Return to main screen
    Navigator.of(context).pop();
  }

  void _startWaitTimer() {
    _waitTimer?.cancel();
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        if (_enforceWaitingPinProximity()) {
          return;
        }

        setState(() {
          _waitSeconds++;
          _updateWaitAnalytics();
        });

        // Auto-stop if we've exceeded the predicted ETA window
        if (_realEta != null &&
            _waitSeconds > (_realEta!.predictionMaxSeconds + 30)) {
          _onJeepArrived();
        }
      }
    });
  }

  void _updateWaitAnalytics() {
    final currentRemaining = (_waitInitialEtaSeconds - _waitSeconds)
        .clamp(0, double.infinity)
        .toDouble();

    if (_waitPreviousEtaSample != null) {
      _waitPredictionStabilityAccumulator +=
          (currentRemaining - _waitPreviousEtaSample!).abs();
      _waitPredictionStabilitySamples++;
    }

    _waitPreviousEtaSample = currentRemaining;
    _waitCurrentEtaSeconds = currentRemaining;
  }

  double get _waitPredictionStabilityPercent {
    if (_waitPredictionStabilitySamples == 0) return 100;
    final avgDiff =
        _waitPredictionStabilityAccumulator / _waitPredictionStabilitySamples;
    return (100 - (avgDiff * 10)).clamp(0, 100).toDouble();
  }

  String _buildRouteRelevanceLabel() {
    if (_selectedChunk == null || _waitingPinChunk == null) {
      return 'Route relevance unavailable';
    }

    final pathCount = _etaPathChunks.length;
    final startLabel = _selectedChunk!.label;
    final endLabel = _waitingPinChunk!.label;
    return 'Route relevance: $pathCount chunk${pathCount == 1 ? '' : 's'} from $startLabel to $endLabel';
  }

  // ── Map markers ──────────────────────────────────────────────────────────

  Set<Marker> _buildMarkers() {
    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('user'),
        position: _currentUserLocation,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        zIndex: 2,
      ),
    };

    // Show waiting pin on all states after moving
    if (_flowState != _JeepFlowState.moving) {
      markers.add(
        Marker(
          markerId: const MarkerId('waiting_pin'),
          position: _waitingPinLocation,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            _flowState == _JeepFlowState.arrived
                ? BitmapDescriptor
                      .hueGreen // green square = jeep arrived
                : BitmapDescriptor.hueRose, // red/pink = waiting
          ),
          zIndex: 3,
        ),
      );
    }

    return markers;
  }

  // ── Root build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── MAP ──────────────────────────────────────────────────────
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentUserLocation,
              zoom: 17,
            ),
            markers: _buildMarkers(),
            myLocationEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            minMaxZoomPreference: const MinMaxZoomPreference(12, 19),
            onMapCreated: (ctrl) {
              if (!_mapController.isCompleted) _mapController.complete(ctrl);
            },
          ),

          // ── TOP HEADER ────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xEE1E7A76), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: const Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          'SAKAYSAIN',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 24), // balance arrow_back
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── BOTTOM UI — switches per state ────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              child: _buildBottomUI(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomUI() {
    switch (_flowState) {
      case _JeepFlowState.moving:
        return _MovingBottomBar(
          key: const ValueKey('moving'),
          onTap: _onApplyWaitingPin,
        );
      case _JeepFlowState.pickingJeepType:
        return _PickingSheet(
          key: const ValueKey('picking'),
          slideAnim: _sheetSlide,
          selectedJeepType: _selectedJeepType,
          onChanged: (v) => setState(() => _selectedJeepType = v),
          onBack: _onBackFromPicking,
          onFind: _onFind,
        );
      case _JeepFlowState.waiting:
        return _WaitingSheet(
          key: const ValueKey('waiting'),
          slideAnim: _sheetSlide,
          waitSeconds: _waitSeconds,
          initialEtaSeconds: _waitInitialEtaSeconds,
          currentEtaSeconds: _waitCurrentEtaSeconds,
          etaStabilityPercent: _waitPredictionStabilityPercent,
          predictionSource: _realEta?.predictionSource ?? 'Unknown',
          predictionMethod: _realEta?.predictionMethod ?? 'Unknown',
          predictionAgeSeconds: _waitPredictionGeneratedAt == null
              ? 0
              : DateTime.now()
                    .difference(_waitPredictionGeneratedAt!)
                    .inSeconds
                    .toDouble(),
          realEta: _realEta,
          selectedDirection: _selectedDirection,
          routeRelevance: _buildRouteRelevanceLabel(),
          onCancel: _onCancel,
          onJeepArrived: _onJeepArrived,
        );
      case _JeepFlowState.arrived:
        return _ArrivedSheet(
          key: const ValueKey('arrived'),
          slideAnim: _sheetSlide,
          actualWaitSeconds: _actualWaitSeconds,
          accuracy: _accuracy,
          predictedArrival: _predictedArrival,
          initialPrediction: _initialPrediction,
          starRating: _starRating,
          onStarTap: (s) => setState(() => _starRating = s),
          onVerify: _onVerifyJeep,
        );
      default:
        return const SizedBox.shrink(key: ValueKey('empty'));
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// IMAGE 1 — MOVING STATE
// Full-bleed map, single teal button at bottom
// ═══════════════════════════════════════════════════════════════════════════

class _MovingBottomBar extends StatelessWidget {
  final VoidCallback onTap;
  const _MovingBottomBar({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xBB1E7A76), Color(0xFF1E7A76)],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 70, 24, 44),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xFF2E9E99),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF2E9E99).withOpacity(0.45),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Text(
            'APPLY A WAITING PIN ON YOUR\nNEAREST ROAD',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
              letterSpacing: 0.8,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// IMAGE 2 — PICKING JEEP TYPE
// White bottom sheet, drag handle, dropdown, Back + Find buttons
// ═══════════════════════════════════════════════════════════════════════════

class _PickingSheet extends StatelessWidget {
  final Animation<Offset> slideAnim;
  final String? selectedJeepType;
  final ValueChanged<String?> onChanged;
  final VoidCallback onBack;
  final VoidCallback onFind;

  const _PickingSheet({
    super.key,
    required this.slideAnim,
    required this.selectedJeepType,
    required this.onChanged,
    required this.onBack,
    required this.onFind,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: slideAnim,
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 24,
                offset: Offset(0, -4),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 22),

              const Text(
                'Filter by:',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
              const SizedBox(height: 2),
              const Text(
                'Type of Jeep',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 14),

              // Teal dropdown
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2E9E99), Color(0xFF1E7A76)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: selectedJeepType,
                    hint: const Text(
                      'Type of Jeep',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.white,
                      size: 26,
                    ),
                    dropdownColor: const Color(0xFF2E9E99),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    onChanged: onChanged,
                    items: const ['All Types', 'Type A', 'Type B', 'Type C']
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                  ),
                ),
              ),

              const SizedBox(height: 26),

              Row(
                children: [
                  Expanded(
                    child: _DarkOutlineBtn(label: 'Back', onTap: onBack),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TealFilledBtn(label: 'Find', onTap: onFind),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// IMAGE 3 — WAITING STATE
// Teal bottom sheet, live second counter, stats chips, Cancel + Jeep Arrived
// ═══════════════════════════════════════════════════════════════════════════

class _WaitingSheet extends StatelessWidget {
  final Animation<Offset> slideAnim;
  final int waitSeconds;
  final double initialEtaSeconds;
  final double currentEtaSeconds;
  final double etaStabilityPercent;
  final String predictionSource;
  final String predictionMethod;
  final double predictionAgeSeconds;
  final TrackedEta? realEta;
  final RoadDirection? selectedDirection;
  final String routeRelevance;
  final VoidCallback onCancel;
  final VoidCallback onJeepArrived;

  const _WaitingSheet({
    super.key,
    required this.slideAnim,
    required this.waitSeconds,
    required this.initialEtaSeconds,
    required this.currentEtaSeconds,
    required this.etaStabilityPercent,
    required this.predictionSource,
    required this.predictionMethod,
    required this.predictionAgeSeconds,
    required this.realEta,
    required this.selectedDirection,
    required this.routeRelevance,
    required this.onCancel,
    required this.onJeepArrived,
  });

  String get _confidenceLabel {
    if (realEta == null) return 'N/A';
    return realEta!.confidenceLabel;
  }

  String get _etaDisplay {
    return '${currentEtaSeconds.toStringAsFixed(0)}s';
  }

  String get _confidencePercent {
    if (realEta == null) return '0';
    return '${realEta!.confidencePercent.toStringAsFixed(0)}';
  }

  String get _predictionRange {
    if (realEta == null) return 'N/A';
    final min = realEta!.predictionMinSeconds.toStringAsFixed(0);
    final max = realEta!.predictionMaxSeconds.toStringAsFixed(0);
    return '$min–${max}s';
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: slideAnim,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF37B09E), Color(0xFF1A6B62)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 24,
                offset: Offset(0, -4),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DragHandle(),
              const SizedBox(height: 22),

              const Text(
                'WAITING TIME',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${waitSeconds}s',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 18),

              _StatsPill(
                children: [
                  _PillStat(
                    label: 'Initial ETA:',
                    value: '${initialEtaSeconds.toStringAsFixed(0)}s',
                  ),
                  _PillDivider(),
                  _PillStat(
                    label: 'Current ETA:',
                    value: '${currentEtaSeconds.toStringAsFixed(0)}s',
                  ),
                  _PillDivider(),
                  _PillStat(
                    label: 'Stability:',
                    value: '${etaStabilityPercent.toStringAsFixed(0)}%',
                  ),
                ],
              ),

              const SizedBox(height: 12),

              _StatsPill(
                children: [
                  _PillStat(label: 'Source:', value: predictionSource),
                  _PillDivider(),
                  _PillStat(label: 'Method:', value: predictionMethod),
                  _PillDivider(),
                  _PillStat(
                    label: 'Age:',
                    value: '${predictionAgeSeconds.toStringAsFixed(0)}s',
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Text(
                routeRelevance,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),

              const SizedBox(height: 12),

              // Stats pill with real ETA data
              _StatsPill(
                children: [
                  _PillStat(
                    label: 'Confidence:',
                    value: '$_confidencePercent% $_confidenceLabel',
                  ),
                  _PillDivider(),
                  _PillStat(label: 'ETA', value: _etaDisplay),
                  _PillDivider(),
                  _PillStat(label: 'Range:', value: _predictionRange),
                  if (selectedDirection != null) ...[
                    _PillDivider(),
                    _PillStat(
                      label: 'Direction:',
                      value: selectedDirection == RoadDirection.forward
                          ? 'Forward'
                          : 'Backward',
                    ),
                  ],
                  if (realEta?.isGhost ?? false) ...[
                    _PillDivider(),
                    _PillStat(label: 'Mode:', value: 'Ghost (Low confidence)'),
                  ],
                ],
              ),

              const SizedBox(height: 22),

              Row(
                children: [
                  Expanded(
                    child: _GlassOutlineBtn(label: 'Cancel', onTap: onCancel),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TealFilledBtn(
                      label: 'Jeep Arrived',
                      onTap: onJeepArrived,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// IMAGE 4 — ARRIVED STATE
// Teal sheet, "JEEP ARRIVED!", actual time, accuracy stats, stars, verify
// ═══════════════════════════════════════════════════════════════════════════

class _ArrivedSheet extends StatelessWidget {
  final Animation<Offset> slideAnim;
  final int actualWaitSeconds;
  final double accuracy;
  final double predictedArrival;
  final double initialPrediction;
  final int starRating;
  final ValueChanged<int> onStarTap;
  final VoidCallback onVerify;

  const _ArrivedSheet({
    super.key,
    required this.slideAnim,
    required this.actualWaitSeconds,
    required this.accuracy,
    required this.predictedArrival,
    required this.initialPrediction,
    required this.starRating,
    required this.onStarTap,
    required this.onVerify,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: slideAnim,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF37B09E), Color(0xFF1A6B62)],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 24,
                offset: Offset(0, -4),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DragHandle(),
              const SizedBox(height: 20),

              const Text(
                'JEEP ARRIVED!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Actual Wait Time',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                '${actualWaitSeconds}s',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 16),

              _StatsPill(
                children: [
                  _PillStat(
                    label: 'Predicted ETA:',
                    value: '${predictedArrival.toStringAsFixed(0)}s',
                  ),
                  _PillDivider(),
                  _PillStat(
                    label: 'Actual Wait:',
                    value: '${actualWaitSeconds}s',
                  ),
                  _PillDivider(),
                  _PillStat(
                    label: 'Error:',
                    value:
                        '${(actualWaitSeconds - predictedArrival).abs().toStringAsFixed(0)}s',
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Stats pill
              _StatsPill(
                children: [
                  _PillStat(
                    label: 'Accuracy:',
                    value: '${accuracy.toStringAsFixed(0)}%',
                  ),
                  _PillDivider(),
                  _PillStat(
                    label: 'Predicted Arrival:',
                    value: '${predictedArrival.toStringAsFixed(1)}s',
                  ),
                  _PillDivider(),
                  _PillStat(
                    label: 'Initial Prediction:',
                    value: '${initialPrediction.toStringAsFixed(1)}s',
                  ),
                ],
              ),

              const SizedBox(height: 18),

              const Text(
                'Rate the Accuracy',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 10),

              // Star rating
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  return GestureDetector(
                    onTap: () => onStarTap(i + 1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Icon(
                        i < starRating
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                  );
                }),
              ),

              const SizedBox(height: 20),

              SizedBox(
                width: double.infinity,
                child: _TealFilledBtn(
                  label: 'Verify your Jeep',
                  onTap: onVerify,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHARED MICRO-WIDGETS
// ═══════════════════════════════════════════════════════════════════════════

class _DragHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 44,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.35),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _StatsPill extends StatelessWidget {
  final List<Widget> children;
  const _StatsPill({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: children,
      ),
    );
  }
}

class _PillStat extends StatelessWidget {
  final String label, value;
  const _PillStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 9)),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _PillDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      width: 1,
      color: Colors.white.withOpacity(0.25),
    );
  }
}

// ── Buttons ─────────────────────────────────────────────────────────────────

class _TealFilledBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _TealFilledBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

/// Dark/muted button — used in white sheet (Back button)
class _DarkOutlineBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _DarkOutlineBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: const Color(0xFF4A7A72),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

/// Semi-transparent outline button — used on teal sheets (Cancel)
class _GlassOutlineBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _GlassOutlineBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.35), width: 1),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
