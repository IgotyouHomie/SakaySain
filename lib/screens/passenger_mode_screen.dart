import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../services/passenger_service.dart';
import '../services/ghost_jeep_service.dart';
import '../services/road_intelligence_service.dart';

/// ╔══════════════════════════════════════════════════════════════════════════╗
/// ║  PASSENGER VALIDATION SCREEN — Feature 9                                 ║
/// ║  Shows 5-minute countdown and validation status                         ║
/// ╚══════════════════════════════════════════════════════════════════════════╝

class PassengerValidationScreen extends StatefulWidget {
  final String jeepId;
  final String jeepType;
  final LatLng currentLocation;
  final VoidCallback onValidationComplete;

  const PassengerValidationScreen({
    super.key,
    required this.jeepId,
    required this.jeepType,
    required this.currentLocation,
    required this.onValidationComplete,
  });

  @override
  State<PassengerValidationScreen> createState() =>
      _PassengerValidationScreenState();
}

class _PassengerValidationScreenState extends State<PassengerValidationScreen> {
  final PassengerService _passengerService = PassengerService();
  StreamSubscription<Position>? _positionStream;
  late LatLng _currentLocation;

  @override
  void initState() {
    super.initState();
    _currentLocation = widget.currentLocation;

    // Start validation
    _passengerService.startValidation(
      widget.jeepId,
      widget.jeepType,
      widget.currentLocation,
    );

    // Listen to passenger status changes
    _passengerService.addStatusListener(_onStatusChanged);

    // Track location during validation
    _startLocationTracking();
  }

  void _startLocationTracking() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen((Position position) {
      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
      });

      // Update passenger journey location
      if (_passengerService.isValidating) {
        _passengerService.updatePassengerLocation(
          _currentLocation,
          position.speed,
        );
      }
    });
  }

  void _onStatusChanged(PassengerStatus status) {
    if (status == PassengerStatus.passenger) {
      // Validation complete - switch to passenger mode
      Navigator.pop(context);
      widget.onValidationComplete();
    }
  }

  void _cancelValidation() {
    _passengerService.cancelValidation();
    _positionStream?.cancel();
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _passengerService.removeStatusListener(_onStatusChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E7A76),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: _cancelValidation,
        ),
        title: const Text(
          'Passenger Validation',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Icon
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                  child: const Icon(
                    Icons.directions_bus,
                    color: Colors.white,
                    size: 60,
                  ),
                ),
                const SizedBox(height: 30),

                // Status
                Text(
                  'Validating Your Boarding',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Conditions met:\n✓ Near snapzone\n✓ Confirmed jeep\n✓ Moving at vehicle speed',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 40),

                // Countdown timer
                StreamBuilder<void>(
                  stream: Stream.periodic(const Duration(seconds: 1)),
                  builder: (context, snapshot) {
                    final remaining = _passengerService.validationSecondsRemaining;
                    final formattedTime =
                        _passengerService.getValidationTimeFormatted();
                    final progressValue = remaining / 300.0; // 0 to 1

                    return Column(
                      children: [
                        // Circular progress
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 160,
                              height: 160,
                              child: CircularProgressIndicator(
                                value: progressValue,
                                strokeWidth: 6,
                                backgroundColor: Colors.white.withValues(alpha: 0.2),
                                valueColor:
                                    const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF2E9E99),
                                ),
                              ),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  formattedTime,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 36,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Seconds remaining',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 30),

                        // Info cards
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Jeep Type:',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.7),
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    widget.jeepType,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Jeep ID:',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.7),
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    widget.jeepId,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.red.withValues(alpha: 0.8),
        onPressed: _cancelValidation,
        label: const Text('Cancel Validation'),
        icon: const Icon(Icons.cancel),
      ),
    );
  }
}

/// ╔══════════════════════════════════════════════════════════════════════════╗
/// ║  PASSENGER MODE SCREEN — Feature 10                                      ║
/// ║  Shows user as green square, displays live tracking                     ║
/// ╚══════════════════════════════════════════════════════════════════════════╝

class PassengerModeScreen extends StatefulWidget {
  final String jeepId;
  final String jeepType;
  final LatLng startLocation;
  final VoidCallback onExitTrip;

  const PassengerModeScreen({
    super.key,
    required this.jeepId,
    required this.jeepType,
    required this.startLocation,
    required this.onExitTrip,
  });

  @override
  State<PassengerModeScreen> createState() => _PassengerModeScreenState();
}

class _PassengerModeScreenState extends State<PassengerModeScreen> {
  final PassengerService _passengerService = PassengerService();
  final GhostJeepService _ghostJeepService = GhostJeepService();
  final RoadIntelligenceService _roadIntelligence = RoadIntelligenceService();

  StreamSubscription<Position>? _positionStream;
  late LatLng _currentLocation;
  int _tripDurationSeconds = 0;
  Timer? _tripTimer;

  @override
  void initState() {
    super.initState();
    _currentLocation = widget.startLocation;
    _startTripTimer();
    _startLocationTracking();
  }

  void _startTripTimer() {
    _tripTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _tripDurationSeconds++);
    });
  }

  void _startLocationTracking() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen((Position position) {
      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
      });

      // Record chunk pass
      _passengerService.recordChunkPass(DateTime.now());

      // Update passenger location
      _passengerService.updatePassengerLocation(
        _currentLocation,
        position.speed,
      );
    });
  }

  Future<void> _exitPassenger() async {
    _tripTimer?.cancel();
    _positionStream?.cancel();

    // Get journey data
    final journeyData = await _passengerService.exitPassengerMode();

    if (journeyData != null) {
      // Register with ghost jeep service
      _ghostJeepService.registerPassengerExit(journeyData, 1.0);

      // Record activity
      _roadIntelligence.recordJeepActivity(
        journeyData.jeepId,
        journeyData.jeepType,
        _currentLocation,
        _positionStream == null ? 0 : 0, // Would get from position stream
      );
    }

    widget.onExitTrip();
    if (mounted) Navigator.pop(context);
  }

  String _formatDuration(int seconds) {
    int minutes = seconds ~/ 60;
    int secs = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _tripTimer?.cancel();
    _positionStream?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E7A76),
        title: const Text('In Transit as Passenger'),
        centerTitle: true,
        elevation: 0,
      ),
      body: Stack(
        children: [
          // Trip stats
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Green square indicator
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green.withValues(alpha: 0.5),
                        blurRadius: 20,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.person,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Live Passenger',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'You are being tracked on the map',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 30),

                // Trip info card
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E7A76).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFF2E9E99).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      _TripInfoRow(
                        label: 'Jeep ID',
                        value: widget.jeepId,
                      ),
                      const SizedBox(height: 12),
                      _TripInfoRow(
                        label: 'Jeep Type',
                        value: widget.jeepType,
                      ),
                      const SizedBox(height: 12),
                      _TripInfoRow(
                        label: 'Trip Duration',
                        value: _formatDuration(_tripDurationSeconds),
                      ),
                      const SizedBox(height: 12),
                      _TripInfoRow(
                        label: 'Current Location',
                        value:
                            '${_currentLocation.latitude.toStringAsFixed(4)}, ${_currentLocation.longitude.toStringAsFixed(4)}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Exit button
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _exitPassenger,
              icon: const Icon(Icons.exit_to_app),
              label: const Text(
                'Exit Trip',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TripInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _TripInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF2E9E99),
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}



