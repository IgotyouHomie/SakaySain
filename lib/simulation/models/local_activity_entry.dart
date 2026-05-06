class LocalActivityEntry {
  const LocalActivityEntry({
    required this.chunkId,
    required this.label,
    required this.flowRate,
    required this.lastActivity,
    required this.jeepTypes,
    required this.observedPassCount,
    required this.speculativePassCount,
    required this.avgArrivalInterval,
    required this.avgTravelTime,
    required this.accuracyPercent,
  });

  final int chunkId;
  final String label;
  final double flowRate;
  final DateTime? lastActivity;
  final Set<String> jeepTypes;
  final int observedPassCount;
  final int speculativePassCount;
  final double avgArrivalInterval;
  final double avgTravelTime;
  final double accuracyPercent;
}
