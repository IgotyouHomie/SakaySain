import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui';

class RouteProfile {
  final String id;
  final String name;
  final List<Offset> worldPoints;
  final List<LatLng> mapPoints;

  RouteProfile({
    required this.id,
    required this.name,
    required this.worldPoints,
    required this.mapPoints,
  });

  // Getter for backward compatibility if needed
  List<LatLng> get points => mapPoints;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'world': worldPoints
          .map((e) => {'x': e.dx, 'y': e.dy})
          .toList(),
      'map': mapPoints
          .map((e) => {'lat': e.latitude, 'lng': e.longitude})
          .toList(),
    };
  }

  factory RouteProfile.fromJson(Map<String, dynamic> json) {
    return RouteProfile(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      worldPoints: (json['world'] as List? ?? [])
          .map((p) => Offset(
                (p['x'] as num).toDouble(),
                (p['y'] as num).toDouble(),
              ))
          .toList(),
      mapPoints: (json['map'] as List? ?? json['points'] as List? ?? [])
          .map((e) => LatLng(
                (e['lat'] as num).toDouble(),
                (e['lng'] as num).toDouble(),
              ))
          .toList(),
    );
  }
}
