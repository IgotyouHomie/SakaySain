import 'package:flutter/material.dart';

/// Represents a Jeep Type with an assigned route.
/// Each jeep type follows ONE specific route, even if multiple jeeps of different types
/// traverse the same roads. This enables route-specific jeep behavior.
class JeepType {
  final String id;
  final String name;
  final String assignedRouteId; // Routes by ID to specific route
  final Color color;
  final DateTime createdAt;

  JeepType({
    required this.id,
    required this.name,
    required this.assignedRouteId,
    required this.color,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Convert to JSON for persistence
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'assignedRouteId': assignedRouteId,
    'colorValue': color.value, // Store as int
    'createdAt': createdAt.toIso8601String(),
  };

  /// Create from JSON
  factory JeepType.fromJson(Map<String, dynamic> json) => JeepType(
    id: json['id'] as String,
    name: json['name'] as String,
    assignedRouteId: json['assignedRouteId'] as String,
    color: Color(json['colorValue'] as int? ?? 0xFF2196F3),
    createdAt: json['createdAt'] != null
        ? DateTime.parse(json['createdAt'] as String)
        : null,
  );

  @override
  String toString() => 'JeepType($name -> Route $assignedRouteId)';
}
