import 'road_direction.dart';

class ChunkTraversalState {
  ChunkTraversalState({
    required this.chunkId,
    required this.entryTime,
    required this.direction,
  });

  int chunkId;
  DateTime entryTime;
  RoadDirection direction;
  double accumulatedStopSeconds = 0;
}
