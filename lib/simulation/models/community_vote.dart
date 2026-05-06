enum CommunityVoteTargetType { jeepSighting, routeAccuracy }

enum CommunityVoteRole { passenger, pedestrian }

enum CommunityVoteChoice { confirm, reject, accurate, inaccurate }

class CommunityVote {
  CommunityVote({
    required this.id,
    required this.voterUserId,
    required this.targetType,
    required this.targetId,
    required this.choice,
    required this.role,
    required this.weight,
    required this.createdAt,
    this.jeepType,
  });

  final String id;
  final String voterUserId;
  final CommunityVoteTargetType targetType;
  final String targetId;
  final CommunityVoteChoice choice;
  final CommunityVoteRole role;
  final double weight;
  final DateTime createdAt;
  final String? jeepType;
}
