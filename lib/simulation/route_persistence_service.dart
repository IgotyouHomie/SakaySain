import 'dart:convert';
import 'dart:ui';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/route_profile.dart';

class RoutePersistenceService {
  static const String _mapRouteKey = 'sakaysain_saved_map_route_v1';
  static const String _worldRouteKey = 'sakaysain_saved_world_route_v1';

  static Future<void> saveMapRoute(List<LatLng> points) async {
    final prefs = await SharedPreferences.getInstance();
    final data = points
        .map((point) => {'lat': point.latitude, 'lng': point.longitude})
        .toList();
    await prefs.setString(_mapRouteKey, jsonEncode(data));
  }

  static Future<List<LatLng>> loadMapRoute() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_mapRouteKey);
    if (raw == null || raw.isEmpty) return <LatLng>[];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((item) {
        final map = item as Map<String, dynamic>;
        return LatLng(
          (map['lat'] as num).toDouble(),
          (map['lng'] as num).toDouble(),
        );
      }).toList();
    } catch (_) {
      return <LatLng>[];
    }
  }

  static Future<void> saveWorldRoute(List<Offset> points) async {
    final prefs = await SharedPreferences.getInstance();
    final data = points
        .map((point) => {'dx': point.dx, 'dy': point.dy})
        .toList();
    await prefs.setString(_worldRouteKey, jsonEncode(data));
  }

  static Future<List<Offset>> loadWorldRoute() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_worldRouteKey);
    if (raw == null || raw.isEmpty) return <Offset>[];

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((item) {
        final map = item as Map<String, dynamic>;
        return Offset(
          (map['dx'] as num).toDouble(),
          (map['dy'] as num).toDouble(),
        );
      }).toList();
    } catch (_) {
      return <Offset>[];
    }
  }

  static Future<void> clearAllRoutes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_mapRouteKey);
    await prefs.remove(_worldRouteKey);
  }

  // --- LEGACY PROFILE PERSISTENCE (kept as requested) ---
  static const String _profilesKeyLegacy = 'route_profiles_v1';

  static Future<void> saveRouteProfileLegacy(RouteProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadRouteProfiles();
    existing.removeWhere((p) => p.name == profile.name);
    existing.add(profile);
    final encoded = existing.map((p) => p.toJson()).toList();
    await prefs.setString(_profilesKeyLegacy, jsonEncode(encoded));
  }

  static Future<List<RouteProfile>> loadRouteProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesKeyLegacy);
    if (raw == null) return [];
    final decoded = jsonDecode(raw) as List;
    return decoded.map((e) => RouteProfile.fromJson(e)).toList();
  }

  // --- NEW PROFILE PERSISTENCE (Added from snippet) ---
  static const String _profilesKey = "route_profiles";

  // SAVE PROFILE
  static Future<void> saveRouteProfile(RouteProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_profilesKey) ?? [];

    final encoded = jsonEncode({
      "id": profile.id,
      "name": profile.name,
      "world": profile.worldPoints.map((e) => {"x": e.dx, "y": e.dy}).toList(),
      "map": profile.mapPoints
          .map((e) => {"lat": e.latitude, "lng": e.longitude})
          .toList(),
    });

    existing.add(encoded);
    await prefs.setStringList(_profilesKey, existing);
  }

  // LOAD ALL
  static Future<List<RouteProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_profilesKey) ?? [];

    return raw.map((e) {
      final data = jsonDecode(e);

      return RouteProfile(
        id: data["id"],
        name: data["name"],
        worldPoints: (data["world"] as List)
            .map((p) => Offset(p["x"], p["y"]))
            .toList(),
        mapPoints: (data["map"] as List)
            .map((p) => LatLng(p["lat"], p["lng"]))
            .toList(),
      );
    }).toList();
  }
}
