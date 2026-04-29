class VerificationSummary {
  VerificationSummary({
    required this.targetId,
    required this.confirmWeight,
    required this.rejectWeight,
    required this.totalVotes,
  });

  final String targetId;
  final double confirmWeight;
  final double rejectWeight;
  final int totalVotes;

  double get netScore => confirmWeight - rejectWeight;

  double get confidencePercent {
    final total = confirmWeight + rejectWeight;
    if (total <= 0) return 0;
    return ((confirmWeight / total) * 100).clamp(0, 100);
  }

  String get statusLabel {
    if (totalVotes == 0) return 'No votes';
    if (netScore >= 1.5) return 'Verified';
    if (netScore <= -1.5) return 'Disputed';
    return 'Pending';
  }
}