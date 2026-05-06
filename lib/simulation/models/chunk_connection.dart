/// Represents a connection between two road chunks (for forks, splits, intersections).
///
/// This enables:
/// - Road chunks to branch into multiple paths (forks)
/// - Routes to follow specific branches through intersections
/// - Realistic road networks with multiple path options
class ChunkConnection {
  final String id;
  final int fromChunkId; // Source chunk
  final int toChunkId; // Destination chunk
  final String roadId; // Which road this connection belongs to
  final DateTime createdAt;

  ChunkConnection({
    required this.id,
    required this.fromChunkId,
    required this.toChunkId,
    required this.roadId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Convert to JSON for persistence
  Map<String, dynamic> toJson() => {
    'id': id,
    'fromChunkId': fromChunkId,
    'toChunkId': toChunkId,
    'roadId': roadId,
    'createdAt': createdAt.toIso8601String(),
  };

  /// Create from JSON
  factory ChunkConnection.fromJson(Map<String, dynamic> json) =>
      ChunkConnection(
        id: json['id'] as String,
        fromChunkId: json['fromChunkId'] as int,
        toChunkId: json['toChunkId'] as int,
        roadId: json['roadId'] as String,
        createdAt: json['createdAt'] != null
            ? DateTime.parse(json['createdAt'] as String)
            : null,
      );

  @override
  String toString() =>
      'ChunkConnection(chunk $fromChunkId -> chunk $toChunkId on road $roadId)';
}
