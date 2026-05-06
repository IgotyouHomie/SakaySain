import 'package:flutter/material.dart';

class ChunkPassEvent {
  const ChunkPassEvent({
    required this.time,
    required this.jeepType,
    required this.observed,
  });

  final DateTime time;
  final String jeepType;
  final bool observed;
}

class RoadChunk {
  RoadChunk({
    required this.id,
    required this.roadLabel,
    required this.indexInRoad,
    required this.startPoint,
    required this.endPoint,
    required this.lengthMeters,
    required this.forwardDirectionLabel,
    required this.reverseDirectionLabel,
  });

  final int id;
  final String roadLabel;
  final int indexInRoad;
  final Offset startPoint;
  final Offset endPoint;
  final double lengthMeters;
  final String forwardDirectionLabel;
  final String reverseDirectionLabel;

  String get label => 'Chunk $roadLabel-$indexInRoad';

  final List<ChunkPassEvent> jeepPassEvents = <ChunkPassEvent>[];
  final List<ChunkPassEvent> speculativePassEvents = <ChunkPassEvent>[];
  final Map<String, List<ChunkPassEvent>> jeepTypePassEvents =
      <String, List<ChunkPassEvent>>{};
  final Map<String, List<ChunkPassEvent>> speculativeJeepTypePassEvents =
      <String, List<ChunkPassEvent>>{};

  double avgArrivalIntervalAllObserved = 0;
  double avgArrivalIntervalAllSpeculative = 0;
  final Map<String, double> avgArrivalIntervalByTypeObserved =
      <String, double>{};
  final Map<String, double> avgArrivalIntervalByTypeSpeculative =
      <String, double>{};

  DateTime? lastJeepPassTimeObserved;
  DateTime? lastJeepPassTimeSpeculative;
  final Map<String, DateTime> lastJeepPassTimeByTypeObserved =
      <String, DateTime>{};
  final Map<String, DateTime> lastJeepPassTimeByTypeSpeculative =
      <String, DateTime>{};

  int observedPassCount = 0;
  int speculativePassCount = 0;

  int arrivalIntervalObservedSamples = 0;
  int arrivalIntervalSpeculativeSamples = 0;
  final Map<String, int> arrivalIntervalObservedSamplesByType = <String, int>{};
  final Map<String, int> arrivalIntervalSpeculativeSamplesByType =
      <String, int>{};

  double avgTravelTimeAll = 0;
  double travelTimeVarianceAll = 0;
  int travelTimeSampleCountAll = 0;
  double _travelTimeM2All = 0;
  final Map<String, double> avgTravelTimeByType = <String, double>{};
  final Map<String, double> travelTimeVarianceByType = <String, double>{};
  final Map<String, int> travelTimeSampleCountByType = <String, int>{};
  final Map<String, double> _travelTimeM2ByType = <String, double>{};
  final List<double> observedTravelSamplesAll = <double>[];
  final Map<String, List<double>> observedTravelSamplesByType =
      <String, List<double>>{};

  final Map<String, double> jeepArrivalProbabilityByType = <String, double>{};
  double flowRateJeepsPerMinute = 0;
  final Map<String, double> flowRateJeepsPerMinuteByType = <String, double>{};

  double forwardAvgTravelTime = 0;
  double backwardAvgTravelTime = 0;
  final List<double> forwardTravelSamples = <double>[];
  final List<double> backwardTravelSamples = <double>[];
  final Map<String, List<double>> forwardSamplesByBucket =
      <String, List<double>>{};
  final Map<String, List<double>> backwardSamplesByBucket =
      <String, List<double>>{};
  final Map<String, double> forwardAverageByBucket = <String, double>{};
  final Map<String, double> backwardAverageByBucket = <String, double>{};
  DateTime? lastUpdated;

  double get avgArrivalIntervalAll {
    if (avgArrivalIntervalAllObserved > 0) {
      return avgArrivalIntervalAllObserved;
    }
    return avgArrivalIntervalAllSpeculative;
  }

  Map<String, double> get avgArrivalIntervalByType {
    final merged = <String, double>{};
    for (final entry in avgArrivalIntervalByTypeSpeculative.entries) {
      merged[entry.key] = entry.value;
    }
    for (final entry in avgArrivalIntervalByTypeObserved.entries) {
      merged[entry.key] = entry.value;
    }
    return merged;
  }

  DateTime? get lastJeepPassTime {
    return lastJeepPassTimeObserved ?? lastJeepPassTimeSpeculative;
  }

  void updateTravelTimeAll(double sampleSeconds) {
    travelTimeSampleCountAll += 1;
    final delta = sampleSeconds - avgTravelTimeAll;
    avgTravelTimeAll += delta / travelTimeSampleCountAll;
    final delta2 = sampleSeconds - avgTravelTimeAll;
    _travelTimeM2All += delta * delta2;
    travelTimeVarianceAll = travelTimeSampleCountAll > 1
        ? _travelTimeM2All / (travelTimeSampleCountAll - 1)
        : 0;
  }

  void updateTravelTimeByType(String jeepType, double sampleSeconds) {
    final previousCount = travelTimeSampleCountByType[jeepType] ?? 0;
    final nextCount = previousCount + 1;
    final previousMean = avgTravelTimeByType[jeepType] ?? 0;
    final delta = sampleSeconds - previousMean;
    final nextMean = previousMean + (delta / nextCount);
    final delta2 = sampleSeconds - nextMean;
    final nextM2 = (_travelTimeM2ByType[jeepType] ?? 0) + (delta * delta2);

    travelTimeSampleCountByType[jeepType] = nextCount;
    avgTravelTimeByType[jeepType] = nextMean;
    _travelTimeM2ByType[jeepType] = nextM2;
    travelTimeVarianceByType[jeepType] = nextCount > 1
        ? nextM2 / (nextCount - 1)
        : 0;
  }

  static double updateRollingMean({
    required double currentMean,
    required int currentCount,
    required double sample,
  }) {
    final nextCount = currentCount + 1;
    return currentMean + ((sample - currentMean) / nextCount);
  }

  Map<String, DateTime> get lastJeepPassTimeByType {
    final merged = <String, DateTime>{};
    for (final entry in lastJeepPassTimeByTypeSpeculative.entries) {
      merged[entry.key] = entry.value;
    }
    for (final entry in lastJeepPassTimeByTypeObserved.entries) {
      merged[entry.key] = entry.value;
    }
    return merged;
  }
}
