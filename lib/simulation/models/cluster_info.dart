import 'package:flutter/material.dart';

class ClusterInfo {
  const ClusterInfo({
    required this.center,
    required this.userCount,
    required this.memberUserIds,
    required this.jeepTypes,
  });

  final Offset center;
  final int userCount;
  final Set<int> memberUserIds;
  final Set<String> jeepTypes;
}
