import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sakaysain/app.dart';

void main() {
  testWidgets('Simulation screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('2D Mobility Simulation'), findsOneWidget);
    expect(find.textContaining('Users:'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
