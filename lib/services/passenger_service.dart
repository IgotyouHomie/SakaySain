import 'dart:async';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// ╔══════════════════════════════════════════════════════════════════════════╗
/// ║  PASSENGER SERVICE — Manages passenger lifecycle                         ║
/// ║  Features 9-11: Validation, Mode, and Exit                              ║
/// ╚══════════════════════════════════════════════════════════════════════════╝

enum PassengerStatus {
  bystander,           // Not a passenger
  validating,          // Waiting 5 minutes for validation
  passenger,           // Active passenger
  exiting,             // Transitioning to ghost
}

/// Data collected during passenger trip
class PassengerJourneyData {
  final String jeepId;
  final String jeepType;
  final LatLng startLocation;
  final DateTime startTime;
  final List<LatLng> routePoints = [];
  final List<double> speeds = [];
  final List<DateTime> chunkPassTimes = [];
  final int stopCount = 0;
  final double? confidence;
  final String purpose; // crowdsourced data purpose

  PassengerJourneyData({
    required this.jeepId,
    required this.jeepType,
    required this.startLocation,
    required this.startTime,
    this.confidence,
    this.purpose = 'Crowdsourced live jeep data',
  });

  /// Serialize for backend submission
  Map<String, dynamic> toJson() => {
    'jeepId': jeepId,
    'jeepType': jeepType,
    'startLocation': {'lat': startLocation.latitude, 'lng': startLocation.longitude},
    'startTime': startTime.toIso8601String(),
    'routePoints': routePoints.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
    'speeds': speeds,
    'chunkPassTimes': chunkPassTimes.map((t) => t.toIso8601String()).toList(),
    'stopCount': stopCount,
    'confidence': confidence,
    'purpose': purpose,
  };
}

/// Main passenger service
class PassengerService {
  static final PassengerService _instance = PassengerService._internal();

  factory PassengerService() => _instance;
  PassengerService._internal();

  // ── State ────────────────────────────────────────────────────────────────
  PassengerStatus _status = PassengerStatus.bystander;
  PassengerJourneyData? _currentJourney;
  Timer? _validationTimer;
  int _validationSecondsRemaining = 0;

  final List<Function(PassengerStatus)> _statusListeners = [];
  final List<Function(int)> _validationTimerListeners = [];

  // ── Getters ──────────────────────────────────────────────────────────────
  PassengerStatus get status => _status;
  PassengerJourneyData? get currentJourney => _currentJourney;
  int get validationSecondsRemaining => _validationSecondsRemaining;
  bool get isPassenger => _status == PassengerStatus.passenger;
  bool get isValidating => _status == PassengerStatus.validating;

  // ── Status Changes ───────────────────────────────────────────────────────
  void addStatusListener(Function(PassengerStatus) listener) {
    _statusListeners.add(listener);
  }

  void removeStatusListener(Function(PassengerStatus) listener) {
    _statusListeners.remove(listener);
  }

  void addValidationTimerListener(Function(int) listener) {
    _validationTimerListeners.add(listener);
  }

  void removeValidationTimerListener(Function(int) listener) {
    _validationTimerListeners.remove(listener);
  }

  void _notifyStatusChange() {
    for (var listener in _statusListeners) {
      listener(_status);
    }
  }

  void _notifyValidationTimer() {
    for (var listener in _validationTimerListeners) {
      listener(_validationSecondsRemaining);
    }
  }

  // ╔══════════════════════════════════════════════════════════════════════════╗
  // ║ FEATURE 9: PASSENGER VALIDATION                                         ║
  // ╚══════════════════════════════════════════════════════════════════════════╝

  /// Start passenger validation (5 minute countdown)
  /// Conditions: User near snapzone, confirmed jeep, moving at vehicle speed
  void startValidation(
    String jeepId,
    String jeepType,
    LatLng currentLocation,
  ) {
    if (_status == PassengerStatus.passenger) return; // Already passenger

    _status = PassengerStatus.validating;
    _validationSecondsRemaining = 300; // 5 minutes = 300 seconds

    // Initialize journey data
    _currentJourney = PassengerJourneyData(
      jeepId: jeepId,
      jeepType: jeepType,
      startLocation: currentLocation,
      startTime: DateTime.now(),
    );

    _notifyStatusChange();

    // Start 5-minute countdown
    _validationTimer?.cancel();
    _validationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _validationSecondsRemaining--;
      _notifyValidationTimer();

      if (_validationSecondsRemaining <= 0) {
        _validationTimer?.cancel();
        _becomePassenger();
      }
    });
  }

  /// Cancel validation (fake report)
  void cancelValidation() {
    _validationTimer?.cancel();
    _status = PassengerStatus.bystander;
    _currentJourney = null;
    _validationSecondsRemaining = 0;
    _notifyStatusChange();
  }

  void _becomePassenger() {
    _validationTimer?.cancel();
    _status = PassengerStatus.passenger;
    _notifyStatusChange();
  }

  // ╔══════════════════════════════════════════════════════════════════════════╗
  // ║ FEATURE 10: PASSENGER MODE                                              ║
  // ╚══════════════════════════════════════════════════════════════════════════╝

  /// Update passenger location and add to journey data
  void updatePassengerLocation(LatLng newLocation, double speed) {
    if (_status != PassengerStatus.passenger || _currentJourney == null) return;

    _currentJourney!.routePoints.add(newLocation);
    _currentJourney!.speeds.add(speed);
  }

  /// Record chunk pass time (track chunk traversal)
  void recordChunkPass(DateTime passTime) {
    if (_status != PassengerStatus.passenger || _currentJourney == null) return;
    _currentJourney!.chunkPassTimes.add(passTime);
  }

  // ╔══════════════════════════════════════════════════════════════════════════╗
  // ║ FEATURE 11: PASSENGER EXIT                                              ║
  // ╚══════════════════════════════════════════════════════════════════════════╝

  /// Exit passenger mode when user:
  /// - Stops
  /// - Leaves road
  /// - Ends trip
  Future<PassengerJourneyData?> exitPassengerMode() async {
    if (_status != PassengerStatus.passenger) return null;

    _validationTimer?.cancel();
    _status = PassengerStatus.exiting;
    _notifyStatusChange();

    // Save journey data for ghost jeep system and backend submission
    final journeyData = _currentJourney;

    // Reset state after short delay for UI transition
    await Future.delayed(const Duration(milliseconds: 500));
    _status = PassengerStatus.bystander;
    _currentJourney = null;
    _notifyStatusChange();

    return journeyData;
  }

  /// Get formatted validation time remaining (MM:SS format)
  String getValidationTimeFormatted() {
    int minutes = _validationSecondsRemaining ~/ 60;
    int seconds = _validationSecondsRemaining % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void dispose() {
    _validationTimer?.cancel();
    _statusListeners.clear();
    _validationTimerListeners.clear();
  }
}

