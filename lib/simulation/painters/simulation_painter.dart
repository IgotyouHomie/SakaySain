import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/cluster_info.dart';
import '../models/user.dart';

class SimulationPainter extends CustomPainter {
  const SimulationPainter({
    required this.worldRadius,
    required this.roads,
    required this.roadChunks,
    required this.maxChunkFlowRate,
    required this.users,
    required this.trafficZones,
    required this.viewportScale,
    required this.frame,
    required this.phoneUserId,
    required this.selectedUserId,
    required this.visibleToPhoneIds,
    required this.phoneVisibilityRadius,
    required this.showRoadSnapZone,
    required this.roadSnapThreshold,
    required this.showClusterDebugRadii,
    required this.clusterDistanceThresholdPx,
    required this.clusters,
    required this.showTrails,
    required this.roadWaiterPin,
    required this.roadWaiterDirectionIsForward,
    required this.highlightedJeepId,
    required this.pausedUserIds,
    required this.ghostMarkers,
    required this.topFlowChunkBadges,
    required this.showFlowHeatOverlay,
    required this.showRoadChunkDirections,
  });

  final double worldRadius;
  final List<List<Offset>> roads;
  final List<({Offset start, Offset end, double flowRate})> roadChunks;
  final double maxChunkFlowRate;
  final List<User> users;
  final List<({Offset start, Offset end})> trafficZones;
  final double viewportScale;
  final int frame;
  final int phoneUserId;
  final int selectedUserId;
  final Set<int> visibleToPhoneIds;
  final double phoneVisibilityRadius;
  final bool showRoadSnapZone;
  final double roadSnapThreshold;
  final bool showClusterDebugRadii;
  final double clusterDistanceThresholdPx;
  final List<ClusterInfo> clusters;
  final bool showTrails;
  final Offset? roadWaiterPin;
  final bool? roadWaiterDirectionIsForward;
  final int? highlightedJeepId;
  final Set<int> pausedUserIds;
  final List<
      ({int sourceUserId, String jeepType, Offset position, double confidence})
  >
  ghostMarkers;
  final List<({Offset position, String label, double flowRate})>
  topFlowChunkBadges;
  final bool showFlowHeatOverlay;
  final bool showRoadChunkDirections;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = math.min(size.width, size.height) / ((worldRadius * 2) + 20);

    Offset toCanvas(Offset p) =>
        Offset(center.dx + p.dx * scale, center.dy + p.dy * scale);

    final strokeCompensation = 1 / math.sqrt(viewportScale);

    final worldPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * strokeCompensation
      ..color = Colors.black54;
    canvas.drawCircle(center, worldRadius * scale, worldPaint);

    final roadPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * strokeCompensation
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.blue;

    final draftRoadPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2 * strokeCompensation
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.orangeAccent;

    final draftPointFill = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.redAccent;

    final draftPointBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * strokeCompensation
      ..color = Colors.white;

    if (showRoadSnapZone) {
      final snapPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = (roadSnapThreshold * 2 * scale)
        ..color = Colors.orange.withValues(alpha: 0.18);

      for (final road in roads) {
        for (int i = 0; i < road.length - 1; i++) {
          canvas.drawLine(
            toCanvas(road[i]),
            toCanvas(road[i + 1]),
            snapPaint,
          );
        }
      }
    }

    // Draft route preview only.
    // Saved route is represented by chunk marks below, so we avoid duplicate lines.
    if (roads.length > 1) {
      final draftRoad = roads.last;
      if (draftRoad.length >= 2) {
        for (int i = 0; i < draftRoad.length - 1; i++) {
          _drawDashedLine(
            canvas,
            toCanvas(draftRoad[i]),
            toCanvas(draftRoad[i + 1]),
            draftRoadPaint,
            dashLength: (16 * strokeCompensation).clamp(10.0, 20.0),
            gapLength: (10 * strokeCompensation).clamp(6.0, 14.0),
          );
        }

        for (final point in draftRoad) {
          final p = toCanvas(point);
          final radius = (4.8 * strokeCompensation).clamp(3.0, 7.0);
          canvas.drawCircle(p, radius, draftPointFill);
          canvas.drawCircle(p, radius, draftPointBorder);
        }
      }
    }

    // One visible segmented mark per chunk only.
    // Example: A-B = one mark, B-C = one mark, C-D = one mark.
    for (final chunk in roadChunks) {
      final start = chunk.start;
      final end = chunk.end;

      final normalizedFlow = maxChunkFlowRate <= 0
          ? 0.0
          : (chunk.flowRate / maxChunkFlowRate).clamp(0.0, 1.0);

      final heatColor = Color.lerp(
        Colors.blue,
        Colors.redAccent,
        normalizedFlow,
      )!;

      final chunkPaint = showFlowHeatOverlay
          ? (Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth =
            (3.2 + (1.8 * normalizedFlow)) * strokeCompensation
        ..strokeCap = StrokeCap.round
        ..color = heatColor)
          : (Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0 * strokeCompensation
        ..strokeCap = StrokeCap.round
        ..color = Colors.blue);

      // Larger inset gives more space between adjacent chunks.
      final segmentStart = Offset.lerp(start, end, 0.26)!;
      final segmentEnd = Offset.lerp(start, end, 0.75)!;

      canvas.drawLine(
        toCanvas(segmentStart),
        toCanvas(segmentEnd),
        chunkPaint,
      );

      if (showRoadChunkDirections) {
        final centerPoint = Offset.lerp(segmentStart, segmentEnd, 0.5)!;
        final vec = segmentEnd - segmentStart;
        final length = vec.distance;
        if (length > 0.001) {
          final dir = vec / length;
          final arrowLen = 8.0 / scale;
          final p1 = toCanvas(centerPoint - (dir * arrowLen));
          final p2 = toCanvas(centerPoint + (dir * arrowLen));
          final arrowPaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2 * strokeCompensation
            ..strokeCap = StrokeCap.round
            ..color = Colors.blueGrey.withValues(alpha: 0.85);
          canvas.drawLine(p1, p2, arrowPaint);
        }
      }
    }

    final trafficPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * strokeCompensation
      ..strokeCap = StrokeCap.round
      ..color = Colors.purpleAccent.withValues(alpha: 0.95);
    for (final zone in trafficZones) {
      canvas.drawLine(toCanvas(zone.start), toCanvas(zone.end), trafficPaint);
    }

    final phoneUser = users.firstWhere(
          (user) => user.id == phoneUserId,
      orElse: () => users.first,
    );

    final phoneVisibilityPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.lightBlue.withValues(alpha: 0.18);
    canvas.drawCircle(
      toCanvas(phoneUser.position),
      phoneVisibilityRadius * scale,
      phoneVisibilityPaint,
    );

    if (roadWaiterPin != null) {
      final pinFill = Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.yellow;
      final pinBorder = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * strokeCompensation
        ..color = Colors.orange.shade800;
      final pinCenter = toCanvas(roadWaiterPin!);
      final pinRadius = (7.5 * strokeCompensation).clamp(4.5, 9.5);
      canvas.drawCircle(pinCenter, pinRadius, pinFill);
      canvas.drawCircle(pinCenter, pinRadius, pinBorder);

      if (roadWaiterDirectionIsForward != null) {
        final arrowText = roadWaiterDirectionIsForward! ? '→' : '←';
        final arrowPainter = TextPainter(
          text: TextSpan(
            text: arrowText,
            style: TextStyle(
              color: Colors.orange.shade900,
              fontSize: 14 * strokeCompensation,
              fontWeight: FontWeight.w900,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        arrowPainter.paint(
          canvas,
          Offset(
            pinCenter.dx - (arrowPainter.width / 2),
            pinCenter.dy - pinRadius - arrowPainter.height - 2,
          ),
        );
      }
    }

    final userSize = (11 * strokeCompensation).clamp(6.5, 15.0);

    final visibleUsers = users.where((user) {
      return user.id == phoneUserId || visibleToPhoneIds.contains(user.id);
    }).toList();

    final clusterDistanceInPainterSpace =
    (clusterDistanceThresholdPx / viewportScale).clamp(8, 120).toDouble();

    final clusteredUserIds = <int>{};
    for (final cluster in clusters) {
      for (final userId in cluster.memberUserIds) {
        clusteredUserIds.add(userId);
      }
    }

    if (showTrails) {
      for (final user in visibleUsers) {
        if (!user.isMoving || user.trailPositions.isEmpty) {
          continue;
        }

        final totalPoints = user.trailPositions.length;
        final baseRadius = user.isPhoneUser
            ? (3.0 * strokeCompensation).clamp(2.0, 5.0)
            : (2.4 * strokeCompensation).clamp(1.6, 4.0);
        final trailColor = user.isPhoneUser ? Colors.blueAccent : Colors.green;

        for (int i = 0; i < user.trailPositions.length; i++) {
          final point = user.trailPositions[i];
          final progress = (i + 1) / totalPoints;
          final alpha = (0.04 + (0.86 * progress * progress)).clamp(0.0, 1.0);
          final radius =
          (baseRadius * (0.55 + (0.70 * progress))).clamp(0.9, 6.0);
          final trailPaint = Paint()
            ..style = PaintingStyle.fill
            ..color = trailColor.withValues(alpha: alpha);
          canvas.drawCircle(toCanvas(point), radius, trailPaint);
        }
      }
    }

    for (final user in visibleUsers) {
      final isVisible =
          user.id == phoneUserId || visibleToPhoneIds.contains(user.id);
      if (!isVisible) {
        continue;
      }

      if (clusteredUserIds.contains(user.id)) {
        continue;
      }

      final userCenter = toCanvas(user.position);

      final visibilityPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = user.isPhoneUser
            ? Colors.lightBlue.withValues(alpha: 0.20)
            : user.isMoving
            ? Colors.lightGreen.withValues(alpha: 0.25)
            : Colors.grey.withValues(alpha: 0.2);
      canvas.drawCircle(
        userCenter,
        user.visibilityRadius * scale,
        visibilityPaint,
      );

      final markerPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = user.isPhoneUser
            ? Colors.blue
            : pausedUserIds.contains(user.id)
            ? Colors.orange.shade700
            : user.isMoving
            ? Colors.green
            : Colors.grey;

      final markerSize = user.isPhoneUser ? userSize + 2 : userSize;
      final markerRect = Rect.fromCenter(
        center: userCenter,
        width: markerSize,
        height: markerSize,
      );
      canvas.drawRect(markerRect, markerPaint);

      if (user.id == selectedUserId && !user.isPhoneUser) {
        final selectedPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * strokeCompensation
          ..color = Colors.amber;
        canvas.drawRect(
          markerRect.inflate(4 * strokeCompensation),
          selectedPaint,
        );
      }

      if (highlightedJeepId != null && user.id == highlightedJeepId) {
        final trackedPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * strokeCompensation
          ..color = Colors.yellowAccent;
        canvas.drawRect(
          markerRect.inflate(7 * strokeCompensation),
          trackedPaint,
        );
      }

      if (pausedUserIds.contains(user.id) && !user.isPhoneUser) {
        final stopPainter = TextPainter(
          text: TextSpan(
            text: 'STOP',
            style: TextStyle(
              color: Colors.orange.shade900,
              fontSize: 10 * strokeCompensation,
              fontWeight: FontWeight.w800,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        stopPainter.paint(
          canvas,
          Offset(
            userCenter.dx - (stopPainter.width / 2),
            userCenter.dy - userSize - stopPainter.height,
          ),
        );
      }
    }

    for (final cluster in clusters) {
      final clusterCenter = toCanvas(cluster.center);

      if (showClusterDebugRadii) {
        final debugClusterRadiusPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 * strokeCompensation
          ..color = Colors.orange.withValues(alpha: 0.55);
        canvas.drawCircle(
          clusterCenter,
          clusterDistanceInPainterSpace,
          debugClusterRadiusPaint,
        );
      }

      final clusterSize = userSize + 10;
      final clusterRect = Rect.fromCenter(
        center: clusterCenter,
        width: clusterSize,
        height: clusterSize,
      );

      final clusterFill = Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.orange;
      final clusterBorder = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * strokeCompensation
        ..color = Colors.deepOrange;

      canvas.drawRect(clusterRect, clusterFill);
      canvas.drawRect(clusterRect, clusterBorder);

      final labelPainter = TextPainter(
        text: TextSpan(
          text: '${cluster.userCount}',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12 * strokeCompensation,
            fontWeight: FontWeight.w700,
            shadows: const [
              Shadow(
                color: Colors.black54,
                blurRadius: 2,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      labelPainter.paint(
        canvas,
        Offset(
          clusterCenter.dx - (labelPainter.width / 2),
          clusterCenter.dy - (labelPainter.height / 2),
        ),
      );
    }

    for (final ghost in ghostMarkers) {
      final confidenceAlpha = ghost.confidence.clamp(0.1, 1.0);
      final centerPoint = toCanvas(ghost.position);

      final visibilityPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.blueGrey.withValues(alpha: 0.10 * confidenceAlpha);
      canvas.drawCircle(centerPoint, 65 * scale, visibilityPaint);

      final ghostPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.grey.shade700.withValues(
          alpha: 0.25 + (0.55 * confidenceAlpha),
        );
      final ghostRect = Rect.fromCenter(
        center: centerPoint,
        width: userSize,
        height: userSize,
      );
      canvas.drawRect(ghostRect, ghostPaint);

      final borderPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * strokeCompensation
        ..color = Colors.grey.shade300.withValues(
          alpha: 0.25 + (0.45 * confidenceAlpha),
        );
      canvas.drawRect(ghostRect, borderPaint);
    }

    if (showFlowHeatOverlay && topFlowChunkBadges.isNotEmpty) {
      for (int i = 0; i < topFlowChunkBadges.length; i++) {
        final badge = topFlowChunkBadges[i];
        final position = toCanvas(badge.position);
        final badgeText =
            '#${i + 1} ${badge.label}  ${badge.flowRate.toStringAsFixed(1)} j/m';

        final textPainter = TextPainter(
          text: TextSpan(
            text: badgeText,
            style: TextStyle(
              color: Colors.white,
              fontSize: 9.5 * strokeCompensation,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final padding = 4.0 * strokeCompensation;
        final rect = Rect.fromLTWH(
          position.dx - (textPainter.width / 2) - padding,
          position.dy - 18 - textPainter.height,
          textPainter.width + (padding * 2),
          textPainter.height + (padding * 2),
        );

        final badgePaint = Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.redAccent.withValues(alpha: 0.90);
        final borderPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0 * strokeCompensation
          ..color = Colors.white.withValues(alpha: 0.75);

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect,
            Radius.circular(5 * strokeCompensation),
          ),
          badgePaint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect,
            Radius.circular(5 * strokeCompensation),
          ),
          borderPaint,
        );
        textPainter.paint(
          canvas,
          Offset(rect.left + padding, rect.top + padding),
        );
      }
    }
  }

  void _drawDashedLine(
      Canvas canvas,
      Offset start,
      Offset end,
      Paint paint, {
        required double dashLength,
        required double gapLength,
      }) {
    final totalLength = (end - start).distance;
    if (totalLength <= 0.001) return;

    final direction = (end - start) / totalLength;
    double distance = 0;

    while (distance < totalLength) {
      final dashStart = start + (direction * distance);
      final dashEnd = start +
          (direction * math.min(distance + dashLength, totalLength));
      canvas.drawLine(dashStart, dashEnd, paint);
      distance += dashLength + gapLength;
    }
  }

  @override
  bool shouldRepaint(covariant SimulationPainter oldDelegate) {
    return oldDelegate.users != users ||
        oldDelegate.worldRadius != worldRadius ||
        oldDelegate.roads != roads ||
        oldDelegate.roadChunks != roadChunks ||
        oldDelegate.trafficZones != trafficZones ||
        oldDelegate.viewportScale != viewportScale ||
        oldDelegate.frame != frame ||
        oldDelegate.phoneVisibilityRadius != phoneVisibilityRadius ||
        oldDelegate.showRoadSnapZone != showRoadSnapZone ||
        oldDelegate.roadSnapThreshold != roadSnapThreshold ||
        oldDelegate.clusterDistanceThresholdPx != clusterDistanceThresholdPx ||
        oldDelegate.showClusterDebugRadii != showClusterDebugRadii ||
        oldDelegate.clusters != clusters ||
        oldDelegate.showTrails != showTrails ||
        oldDelegate.roadWaiterPin != roadWaiterPin ||
        oldDelegate.roadWaiterDirectionIsForward !=
            roadWaiterDirectionIsForward ||
        oldDelegate.highlightedJeepId != highlightedJeepId ||
        oldDelegate.pausedUserIds != pausedUserIds ||
        oldDelegate.ghostMarkers != ghostMarkers ||
        oldDelegate.topFlowChunkBadges != topFlowChunkBadges ||
        oldDelegate.showFlowHeatOverlay != showFlowHeatOverlay ||
        oldDelegate.maxChunkFlowRate != maxChunkFlowRate ||
        oldDelegate.showRoadChunkDirections != showRoadChunkDirections;
  }
}