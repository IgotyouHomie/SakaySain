class TrackedEta {
  const TrackedEta({
    required this.userId,
    required this.jeepType,
    required this.etaSeconds,
    required this.confidencePercent,
    required this.distanceMeters,
    this.etaRealTimeSeconds = 0,
    this.etaHistoricalSeconds = 0,
    this.etaTrafficSeconds = 0,
    this.trafficFactor = 1,
    this.isGhost = false,
    this.predictionSource = 'Unknown',
    this.predictionMethod = 'Unknown',
    this.confidenceLabel = 'LOW',
    this.predictionMinSeconds = 0,
    this.predictionMaxSeconds = 0,
    this.predictionAgeSeconds = 0,
  });

  final int userId;
  final String jeepType;
  final double etaSeconds;
  final double confidencePercent;
  final double distanceMeters;
  final double etaRealTimeSeconds;
  final double etaHistoricalSeconds;
  final double etaTrafficSeconds;
  final double trafficFactor;
  final bool isGhost;
  final String predictionSource;
  final String predictionMethod;
  final String confidenceLabel;
  final double predictionMinSeconds;
  final double predictionMaxSeconds;
  final double predictionAgeSeconds;
}
