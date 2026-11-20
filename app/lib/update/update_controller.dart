import 'dart:async';

import 'package:flutter/foundation.dart';

import '../i18n/i18n.dart';
import 'release.dart';
import 'semver.dart';
import 'update_service.dart';

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,
  error,
}

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.currentVersion,
    required this.service,
    required this.os,
    required this.arch,
    required this.install,
    required this.quit,
    this.every = const Duration(hours: 6),
  });

  final String currentVersion;
  final UpdateService service;
  final String os;
  final String arch;
  final InstallType install;

  final Future<void> Function() quit;
  final Duration every;

  UpdatePhase phase = UpdatePhase.idle;
  ReleaseInfo? release;
  double progress = 0;
  String? error;
  Timer? _timer;
  Future<void>? _checking;
  bool _disposed = false;

  bool get updateAvailable => release != null;

  ReleaseAsset? get asset => release == null
      ? null
      : selectAsset(release!, os: os, arch: arch, install: install);

  bool get canInstall => asset != null && install is! UnsupportedInstall;

  void start() {
    unawaited(check());
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => check());
  }

  Future<void> check() =>
      _checking ??= _check().whenComplete(() => _checking = null);

  Future<void> _check() async {
    if (phase == UpdatePhase.downloading || phase == UpdatePhase.installing) {
      return;
    }
    _set(UpdatePhase.checking);
    try {
      final r = await service.fetchLatest();
      if (r != null && isNewerVersion(r.version.toString(), currentVersion)) {
        release = r;
        error = null;
        _set(UpdatePhase.available);
      } else {
        release = null;
        _set(UpdatePhase.upToDate);
      }
    } catch (e) {
      error = null;
      _set(release == null ? UpdatePhase.idle : UpdatePhase.available);
    }
  }

  Future<void> installUpdate() async {
    final r = release, a = asset;
    if (r == null || a == null || !canInstall) return;
    if (phase == UpdatePhase.downloading || phase == UpdatePhase.installing) {
      return;
    }
    progress = 0;
    error = null;
    _set(UpdatePhase.downloading);
    try {
      final sums = await service.fetchSums(r);
      final file = await service.download(
        a,
        sums,
        onProgress: (p) {
          progress = p;
          _notify();
        },
      );
      _set(UpdatePhase.installing);
      await service.apply(file, install);
      await quit();
    } catch (e) {
      error = e is UpdateException ? e.message : S.updateErrorFailed(error: e);
      _set(UpdatePhase.error);
    }
  }

  void _set(UpdatePhase p) {
    phase = p;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    service.close();
    super.dispose();
  }
}
