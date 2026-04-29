class EtaTestRecord {
  const EtaTestRecord({
    required this.timestamp,
    required this.roadChunkId,
    required this.jeepType,
    required this.predictedEtaSeconds,
    required this.actualWaitTimeSeconds,
    required this.predictionErrorSeconds,
    required this.accuracyPercent,
    required this.trafficFactor,
    required this.chunkFlowRate,
    required this.ghostJeepUsed,
    required this.predictionSource,
    required this.predictionMethod,
    required this.confidenceLabel,
    required this.predictionDistanceMeters,
    required this.predictionWindowMinSeconds,
    required this.predictionWindowMaxSeconds,
    required this.predictionAgeSeconds,
    required this.predictionStabilityPercent,
  });

  final DateTime timestamp;
  final int roadChunkId;
  final String jeepType;
  final double predictedEtaSeconds;
  final double actualWaitTimeSeconds;
  final double predictionErrorSeconds;
  final double accuracyPercent;
  final double trafficFactor;
  final double chunkFlowRate;
  final bool ghostJeepUsed;
  final String predictionSource;
  final String predictionMethod;
  final String confidenceLabel;
  final double predictionDistanceMeters;
  final double predictionWindowMinSeconds;
  final double predictionWindowMaxSeconds;
  final double predictionAgeSeconds;
  final double predictionStabilityPercent;
}
