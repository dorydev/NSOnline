import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

class StartupLauncher {
  bool _ready = false;

  void _setup() {
    if (_ready) return;
    _ready = true;
    launchAtStartup.setup(
      appName: 'NSOnline',
      appPath: Platform.environment['APPIMAGE'] ?? Platform.resolvedExecutable,
      args: const ['--minimized'],
    );
  }

  Future<void> apply(bool enabled) async {
    _setup();
    if (enabled) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }
}
