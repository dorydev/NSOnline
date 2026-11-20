import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'diagnostics/app_logger.dart';

Future<void> main(List<String> args) async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      final boot = await bootstrap(args);
      runApp(
        NsoRpcApp(
          state: boot.state,
          services: boot.services,
          navigatorKey: boot.navigatorKey,
          splash: true,
        ),
      );
    },
    (error, stack) =>
        AppLogger.instance.error('Uncaught error (zone)', error, stack),
  );
}
