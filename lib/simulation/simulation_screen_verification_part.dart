part of 'simulation_screen.dart';

extension _SimulationScreenVerificationPart on _SimulationScreenState {
  TrustProfile _trustProfileFor(int userId) {
    return _trustProfilesByUser.putIfAbsent(
      userId,
      () => TrustProfile(userId: userId),
    );
  }

  void _openVerificationPanelForChunk(int chunkId) {
    if (chunkId < 0 || chunkId >= _routeChunks.length) return;
    final chunk = _routeChunks[chunkId];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Verify Route Accuracy: Chunk ${chunk.forwardDirectionLabel}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text('Is the jeep route timing/location accurate here?'),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        _submitCommunityVote(
                          chunkId: chunkId,
                          choice: CommunityVoteChoice.accurate,
                        );
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.check_circle),
                      label: const Text('Accurate'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade100),
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        _submitCommunityVote(
                          chunkId: chunkId,
                          choice: CommunityVoteChoice.inaccurate,
                        );
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.error),
                      label: const Text('Inaccurate'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade100),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _submitCommunityVote({
    required int chunkId,
    required CommunityVoteChoice choice,
  }) {
    final voterId = _SimulationScreenState._phoneUserId;
    final trust = _trustProfileFor(voterId);

    final vote = CommunityVote(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      voterUserId: voterId,
      targetType: CommunityVoteTargetType.routeAccuracy,
      targetId: chunkId.toString(),
      choice: choice,
      role: _isPassengerUser ? CommunityVoteRole.passenger : CommunityVoteRole.pedestrian,
      weight: trust.score,
      createdAt: DateTime.now(),
    );

    _applyState(() {
      _communityVotes.add(vote);
      // Simulate trust update logic
      trust.totalVotes++;
      // In a real app, accuracy would be verified against ground truth or consensus
      if (choice == CommunityVoteChoice.accurate) {
        trust.correctVotes++;
        trust.score = (trust.score + 0.05).clamp(0.0, 1.0);
      } else {
        trust.score = (trust.score - 0.02).clamp(0.0, 1.0);
      }
    });
  }
}
