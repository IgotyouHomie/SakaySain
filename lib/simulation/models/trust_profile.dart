class TrustProfile {
  TrustProfile({
    required this.userId,
    this.score = 0.65,
    this.totalVotes = 0,
    this.correctVotes = 0,
  });

  final String userId;
  double score;
  int totalVotes;
  int correctVotes;

  double get reliabilityPercent => (score * 100).clamp(0, 100);
}
