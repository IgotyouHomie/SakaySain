import 'dart:async';
import 'package:flutter/material.dart';

import 'app.dart';

void main() {
  // Capture uncaught Flutter errors and Zone errors to help debugging
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
  };

  runZonedGuarded(
    () {
      runApp(const MyApp());
    },
    (error, stack) {
      // Print to console so `flutter run` / logcat will capture the stack.
      // Keep this minimal to avoid changing app behavior.
      // ignore: avoid_print
      print('Unhandled exception: $error');
      // ignore: avoid_print
      print(stack);
    },
  );
}
