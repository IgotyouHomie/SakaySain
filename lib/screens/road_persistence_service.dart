import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../simulation/models/jeep_type.dart';
import '../simulation/models/chunk_connection.dart';

// ═══════════════════════════════════════════════════════════════════════════
// DATA MODELS
// ═══════════════════════════════════════════════════════════════════════════

/// A Road is a set of LatLng points forming a path any jeep can travel.
/// Displayed as a blue dashed polyline.
class SakayRoad {
  final String id;
  final String name;
  final List<LatLng> points;

  const SakayRoad({required this.id, required this.name, required this.points});

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'points': points
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList(),
  };

  factory SakayRoad.fromJson(Map<String, dynamic> json) => SakayRoad(
    id: json['id'] as String,
    name: json['name'] as String,
    points: RoadPersistenceService._decodePoints(json['points']),
  );
}

/// A Route is a colored overlay on a Road indicating which jeep type uses it.
/// Displayed as a translucent colored polyline over the road.
/// Routes now support chunk-by-chunk connectivity and cross-road forks.
class SakayRoute {
  final String id;
  final String jeepName; // e.g. "Route 1", "Jeep A"
  final Color color;
  final String roadId; // starting SakayRoad
  final List<LatLng>
  points; // computed points for rendering (deprecated, kept for backward compat)

  /// Chunk-based path: sequence of chunk IDs following the road graph.
  /// Format: List of segment objects, each defining start chunk, end chunk, and road ID.
  /// This allows routes to span multiple roads via forks.
  final List<Map<String, dynamic>>?
  chunkPath; // [{'roadId': '...', 'startChunkId': 1, 'endChunkId': 5}, ...]

  const SakayRoute({
    required this.id,
    required this.jeepName,
    required this.color,
    required this.roadId,
    required this.points,
    this.chunkPath,
  });

  /// Create a route from chunk-based path information
  static SakayRoute fromChunkPath({
    required String id,
    required String jeepName,
    required Color color,
    required List<Map<String, dynamic>> chunkPath,
  }) {
    return SakayRoute(
      id: id,
      jeepName: jeepName,
      color: color,
      roadId: chunkPath.isNotEmpty ? (chunkPath.first['roadId'] as String) : '',
      points: [], // Will be computed when needed
      chunkPath: chunkPath,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'jeepName': jeepName,
    'colorValue': color.value,
    'roadId': roadId,
    'points': points
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList(),
    'chunkPath': chunkPath, // Store new chunk-based path
  };

  factory SakayRoute.fromJson(Map<String, dynamic> json) => SakayRoute(
    id: json['id'] as String,
    jeepName: json['jeepName'] as String,
    color: Color(json['colorValue'] as int),
    roadId: json['roadId'] as String,
    points: RoadPersistenceService._decodePoints(json['points']),
    chunkPath: json['chunkPath'] != null
        ? List<Map<String, dynamic>>.from(json['chunkPath'] as List)
        : null,
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// PERSISTENCE SERVICE
// ═══════════════════════════════════════════════════════════════════════════

class RoadPersistenceService {
  static const String _roadsKey = 'sakaysain_roads_v1';
  static const String _routesKey = 'sakaysain_routes_v1';
  static const String _jeepTypesKey = 'sakaysain_jeep_types_v1';
  static const String _chunkConnectionsKey = 'sakaysain_chunk_connections_v1';

  static List<LatLng> _decodePoints(dynamic rawPoints) {
    final decoded = <LatLng>[];
    if (rawPoints is! List) return decoded;

    for (final rawPoint in rawPoints) {
      if (rawPoint is Map) {
        final latValue = rawPoint['lat'];
        final lngValue = rawPoint['lng'];
        if (latValue is num && lngValue is num) {
          decoded.add(LatLng(latValue.toDouble(), lngValue.toDouble()));
        }
        continue;
      }

      if (rawPoint is List && rawPoint.length >= 2) {
        final latValue = rawPoint[0];
        final lngValue = rawPoint[1];
        if (latValue is num && lngValue is num) {
          decoded.add(LatLng(latValue.toDouble(), lngValue.toDouble()));
        }
      }
    }

    return decoded;
  }

  // ── Roads ────────────────────────────────────────────────────────────────

  static Future<void> saveRoads(List<SakayRoad> roads) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(roads.map((r) => r.toJson()).toList());
    await prefs.setString(_roadsKey, encoded);
  }

  static Future<List<SakayRoad>> loadRoads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_roadsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SakayRoad.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Routes ───────────────────────────────────────────────────────────────

  static Future<void> saveRoutes(List<SakayRoute> routes) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(routes.map((r) => r.toJson()).toList());
    await prefs.setString(_routesKey, encoded);
  }

  static Future<List<SakayRoute>> loadRoutes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_routesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => SakayRoute.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Jeep Types ───────────────────────────────────────────────────────────

  static Future<void> saveJeepTypes(List<JeepType> jeepTypes) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(jeepTypes.map((j) => j.toJson()).toList());
    await prefs.setString(_jeepTypesKey, encoded);
  }

  static Future<List<JeepType>> loadJeepTypes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_jeepTypesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => JeepType.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Chunk Connections (for forks/splits) ─────────────────────────────────

  static Future<void> saveChunkConnections(
    List<ChunkConnection> connections,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(connections.map((c) => c.toJson()).toList());
    await prefs.setString(_chunkConnectionsKey, encoded);
  }

  static Future<List<ChunkConnection>> loadChunkConnections() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_chunkConnectionsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => ChunkConnection.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Clear ────────────────────────────────────────────────────────────────

  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_roadsKey);
    await prefs.remove(_routesKey);
    await prefs.remove(_jeepTypesKey);
    await prefs.remove(_chunkConnectionsKey);
  }
}
