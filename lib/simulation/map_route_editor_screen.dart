import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MapRouteEditorScreen extends StatefulWidget {
  const MapRouteEditorScreen({
    super.key,
    required this.initialPoints,
  });

  final List<LatLng> initialPoints;

  @override
  State<MapRouteEditorScreen> createState() => _MapRouteEditorScreenState();
}

class _MapRouteEditorScreenState extends State<MapRouteEditorScreen> {
  static const LatLng _defaultCenter = LatLng(13.1391, 123.7438);

  late final List<LatLng> _points;
  GoogleMapController? _controller;

  @override
  void initState() {
    super.initState();
    _points = List<LatLng>.from(widget.initialPoints);
  }

  CameraPosition get _initialCameraPosition {
    if (_points.isNotEmpty) {
      return CameraPosition(target: _points.first, zoom: 15.5);
    }
    return const CameraPosition(target: _defaultCenter, zoom: 14.5);
  }

  Set<Marker> get _markers {
    final markers = <Marker>{};
    for (var i = 0; i < _points.length; i++) {
      markers.add(
        Marker(
          markerId: MarkerId('route_point_$i'),
          position: _points[i],
          infoWindow: InfoWindow(title: 'Point ${i + 1}'),
        ),
      );
    }
    return markers;
  }

  Set<Polyline> get _polylines {
    if (_points.length < 2) return <Polyline>{};
    return {
      Polyline(
        polylineId: const PolylineId('edited_route'),
        points: _points,
        width: 5,
        color: Colors.blue,
      ),
    };
  }

  void _addPoint(LatLng point) {
    setState(() {
      _points.add(point);
    });
  }

  void _undoLastPoint() {
    if (_points.isEmpty) return;
    setState(() {
      _points.removeLast();
    });
  }

  void _clearAllPoints() {
    setState(() {
      _points.clear();
    });
  }

  Future<void> _fitRoute() async {
    if (_controller == null || _points.isEmpty) return;
    if (_points.length == 1) {
      await _controller!.animateCamera(
        CameraUpdate.newLatLngZoom(_points.first, 16),
      );
      return;
    }

    double minLat = _points.first.latitude;
    double maxLat = _points.first.latitude;
    double minLng = _points.first.longitude;
    double maxLng = _points.first.longitude;

    for (final point in _points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    await _controller!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        80,
      ),
    );
  }

  void _saveRoute() {
    Navigator.of(context).pop(List<LatLng>.from(_points));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Map Route Editor'),
        actions: [
          IconButton(
            tooltip: 'Undo last point',
            onPressed: _points.isEmpty ? null : _undoLastPoint,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Clear all',
            onPressed: _points.isEmpty ? null : _clearAllPoints,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: 'Fit route',
            onPressed: _fitRoute,
            icon: const Icon(Icons.center_focus_strong),
          ),
          TextButton(
            onPressed: _saveRoute,
            child: const Text('SAVE'),
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: _initialCameraPosition,
            mapType: MapType.normal,
            myLocationButtonEnabled: true,
            zoomControlsEnabled: true,
            compassEnabled: true,
            markers: _markers,
            polylines: _polylines,
            onMapCreated: (controller) {
              _controller = controller;
              if (_points.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _fitRoute());
              }
            },
            onTap: _addPoint,
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 16,
            child: Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Tap the map to add route points along real roads.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text('Points: ${_points.length}'),
                    const SizedBox(height: 4),
                    const Text(
                      'Use SAVE when the route follows the jeepney road you want.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}