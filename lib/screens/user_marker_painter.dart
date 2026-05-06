import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Builds a Google Maps [BitmapDescriptor] showing a direction arrow.
///
/// The arrow points in the direction of [headingDegrees] (0 = north,
/// clockwise). The marker is a filled circle with an arrowhead on top so it
/// looks like the Google Maps blue dot with a directional wedge.
///
/// Call [UserMarkerPainter.buildIcon] once per heading update and pass the
/// result to [Marker.icon].
///
/// When heading is unavailable (null) a plain filled circle is drawn instead.
class UserMarkerPainter {
  UserMarkerPainter._();

  static const double _size = 96; // canvas size in logical pixels

  /// Generates a [BitmapDescriptor] asynchronously.
  static Future<BitmapDescriptor> buildIcon({
    double? headingDegrees,
    Color dotColor = const Color(0xFF2196F3), // blue dot
    Color arrowColor = const Color(0xFF1565C0), // darker blue arrow
    Color borderColor = Colors.white,
    bool isDevUser = false, // dev user gets teal colour
  }) async {
    if (isDevUser) {
      dotColor = const Color(0xFF00897B);
      arrowColor = const Color(0xFF004D40);
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, _size, _size));

    final centre = Offset(_size / 2, _size / 2);
    final radius = _size * 0.28;

    // ── Accuracy halo ──────────────────────────────────────────────────
    final haloPaint = Paint()
      ..color = dotColor.withOpacity(0.18)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(centre, _size * 0.44, haloPaint);

    // ── Direction wedge / arrow ────────────────────────────────────────
    if (headingDegrees != null) {
      final rad = headingDegrees * math.pi / 180.0;

      // Rotate the canvas so the wedge always points forward
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(rad);
      canvas.translate(-centre.dx, -centre.dy);

      final wedgePaint = Paint()
        ..color = arrowColor.withOpacity(0.85)
        ..style = PaintingStyle.fill;

      // Triangle pointing upward (north before rotation)
      final path = Path()
        ..moveTo(centre.dx, centre.dy - radius - 14) // tip
        ..lineTo(centre.dx - 10, centre.dy - radius + 4) // left base
        ..lineTo(centre.dx + 10, centre.dy - radius + 4) // right base
        ..close();

      canvas.drawPath(path, wedgePaint);
      canvas.restore();
    }

    // ── White border circle ────────────────────────────────────────────
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(centre, radius + 3, borderPaint);

    // ── Blue filled dot ────────────────────────────────────────────────
    final dotPaint = Paint()
      ..color = dotColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(centre, radius, dotPaint);

    // ── Inner white highlight ─────────────────────────────────────────
    final highlightPaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(centre.dx - radius * 0.25, centre.dy - radius * 0.25),
      radius * 0.3,
      highlightPaint,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(_size.round(), _size.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }
}
