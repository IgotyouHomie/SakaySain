class MovingState {
  MovingState({
    required this.roadIndex,
    required this.segmentIndex,
    required this.t,
    required this.forward,
  });

  int roadIndex;
  int segmentIndex;
  double t;
  bool forward;
}
