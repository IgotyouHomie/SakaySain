import 'package:flutter/material.dart';

class MapLegend extends StatelessWidget {
  const MapLegend({super.key, required this.selectedUserId});

  final int selectedUserId;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const LegendRow(color: Colors.blue, label: 'Phone user'),
            const LegendRow(
              color: Colors.green,
              label: 'Passenger users',
              marker: LegendMarker.square,
            ),
            const LegendRow(
              color: Colors.grey,
              label: 'Ghost jeep (predicted)',
              marker: LegendMarker.square,
            ),
            const LegendRow(color: Colors.grey, label: 'Waiting user'),
            const LegendRow(
              color: Colors.orange,
              label: 'Cluster',
              marker: LegendMarker.cluster,
            ),
            const LegendRow(
              color: Colors.yellow,
              label: 'Road Waiter Pin',
              marker: LegendMarker.circle,
            ),
            const LegendRow(
              color: Colors.blue,
              label: 'Road chunk',
              marker: LegendMarker.dashedLine,
            ),
            const LegendRow(
              color: Colors.redAccent,
              label: 'Flow heat (high)',
              marker: LegendMarker.dashedLine,
            ),
            const LegendRow(
              color: Colors.redAccent,
              label: 'Top flow badge (#1-#3)',
              marker: LegendMarker.stop,
            ),
            const LegendRow(
              color: Colors.orange,
              label: 'Paused user (STOP)',
              marker: LegendMarker.stop,
            ),
            const LegendRow(
              color: Colors.purpleAccent,
              label: 'Traffic line',
              marker: LegendMarker.line,
            ),
            const LegendRow(color: Colors.orange, label: 'Road snap zone'),
            const SizedBox(height: 4),
            Text(
              'Selected user: $selectedUserId',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class LegendRow extends StatelessWidget {
  const LegendRow({
    super.key,
    required this.color,
    required this.label,
    this.marker = LegendMarker.square,
  });

  final Color color;
  final String label;
  final LegendMarker marker;

  @override
  Widget build(BuildContext context) {
    Widget icon;
    switch (marker) {
      case LegendMarker.circle:
        icon = Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black26),
          ),
        );
        break;
      case LegendMarker.line:
        icon = Container(width: 14, height: 3, color: color);
        break;
      case LegendMarker.dashedLine:
        icon = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 4, height: 3, color: color),
            const SizedBox(width: 2),
            Container(width: 4, height: 3, color: color),
            const SizedBox(width: 2),
            Container(width: 4, height: 3, color: color),
          ],
        );
        break;
      case LegendMarker.cluster:
        icon = Container(
          width: 10,
          height: 10,
          color: color,
          alignment: Alignment.center,
          child: const Text(
            'C',
            style: TextStyle(
              fontSize: 7,
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        break;
      case LegendMarker.stop:
        icon = Container(
          width: 14,
          height: 10,
          color: color,
          alignment: Alignment.center,
          child: const Text(
            'S',
            style: TextStyle(
              fontSize: 7,
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        break;
      case LegendMarker.square:
        icon = Container(width: 10, height: 10, color: color);
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 16, child: Center(child: icon)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

enum LegendMarker { square, circle, line, dashedLine, cluster, stop }
