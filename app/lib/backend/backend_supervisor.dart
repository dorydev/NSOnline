import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/http_repository.dart' show isLoopbackApi;
import '../diagnostics/app_logger.dart';
import '../i18n/i18n.dart';

class BackendEndpoint {
  const BackendEndpoint({
    required this.baseUrl,
    required this.token,
    required this.version,
    required this.pid,
  });

  final String baseUrl;

  final String token;
  final String version;
  final int pid;
}

class ReadyInfo {
  const ReadyInfo({
    required this.addr,
    required this.version,
    required this.pid,
  });

  final String addr;
  final String version;
  final int pid;

  String get baseUrl => 'http://$addr';
}

const readyPrefix = 'NSONLINE_READY ';

ReadyInfo? parseReadyLine(String line) {
  final t = line.trim();
  if (!t.startsWith(readyPrefix)) return null;
  final Object? j;
  try {
    j = jsonDecode(t.substring(readyPrefix.length));
  } on FormatException {
    return null;
  }
  if (j is! Map) return null;
  final addr = j['addr'];
  if (addr is! String || addr.isEmpty) return null;
  // host:port, port explicit (Uri would hide a default :80).
  final colon = addr.lastIndexOf(':');
  final port = colon < 0 ? null : int.tryParse(addr.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  final uri = Uri.tryParse('http://$addr');
  if (uri == null || uri.path.isNotEmpty || !isLoopbackApi(uri)) return null;
  final pid = j['pid'];
  return ReadyInfo(
    addr: addr,
    version: j['version'] is String ? j['version'] as String : '',
    pid: pid is num ? pid.toInt() : 0,
  );
}

Duration backoffDelay(
  int attempt, {
  Duration initial = const Duration(seconds: 1),
  Duration max = const Duration(seconds: 60),
}) {
  if (attempt <= 1) return initial;
  final factor = 1 << min(attempt - 1, 20);
  final ms = initial.inMilliseconds * factor;
  return ms >= max.inMilliseconds ? max : Duration(milliseconds: ms);
}

String? resolveBackendExecutable({
  required Map<String, String> env,
  required String resolvedExecutable,
  required bool isWindows,
  required bool Function(String path) exists,
  String? currentDir,
}) {
  final sep = isWindows ? r'\' : '/';
  final ext = isWindows ? '.exe' : '';
  // In the bundle the backend is nsonline-core: the app itself is "nsonline".
  // A dev build of the CLI at the repo root is still "nsonline".
  final names = ['nsonline-core$ext', 'nsonline$ext'];
  final explicit = env['NSO_BACKEND_PATH'];
  if (explicit != null && explicit.isNotEmpty) {
    return exists(explicit) ? explicit : null;
  }
  String dirname(String p) {
    final i = p.lastIndexOf(RegExp(r'[/\\]'));
    return i <= 0 ? p : p.substring(0, i);
  }

  bool usable(String path) =>
      path.toLowerCase() != resolvedExecutable.toLowerCase() && exists(path);

  final bundled = '${dirname(resolvedExecutable)}$sep${names.first}';
  if (exists(bundled)) return bundled;

  for (final start in [?currentDir, dirname(resolvedExecutable)]) {
    var dir = start;
    for (var i = 0; i < 8; i++) {
      for (final name in names) {
        final candidate = '$dir$sep$name';
        if (usable(candidate)) return candidate;
      }
      final parent = dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
  }
  return null;
}

sealed class BackendPhase {
  const BackendPhase();
}

class BackendStopped extends BackendPhase {
  const BackendStopped();
}

class BackendStarting extends BackendPhase {
  const BackendStarting();
}

class BackendReady extends BackendPhase {
  const BackendReady(this.endpoint);
  final BackendEndpoint endpoint;
}

class BackendRestarting extends BackendPhase {
  const BackendRestarting({
    required this.attempt,
    required this.delay,
    required this.reason,
  });
  final int attempt;
  final Duration delay;
  final String reason;
}

class BackendFailed extends BackendPhase {
  const BackendFailed(this.message);
  final String message;
}

typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    });

Future<Process> _startProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) => Process.start(executable, arguments, environment: environment);

String randomApiToken() {
  final r = Random.secure();
  return [
    for (var i = 0; i < 32; i++)
      r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

class BackendSupervisor extends ChangeNotifier {
  BackendSupervisor({
    required this.executable,
    required this.dataDir,
    ProcessStarter? startProcess,
    this.readyTimeout = const Duration(seconds: 15),
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
    this.stableAfter = const Duration(seconds: 60),
    this.shutdownGrace = const Duration(seconds: 3),
    String Function()? tokenGenerator,
    this.requestShutdown,
    AppLogger? logger,
    DateTime Function()? now,
  }) : _start = startProcess ?? _startProcess,
       _newToken = tokenGenerator ?? randomApiToken,
       _log = logger ?? AppLogger.instance,
       _now = now ?? DateTime.now;

  final String executable;
  final String dataDir;
  final Duration readyTimeout;
  final Duration initialBackoff;
  final Duration maxBackoff;

  final Duration stableAfter;
  final Duration shutdownGrace;

  final Future<void> Function(BackendEndpoint endpoint)? requestShutdown;

  final ProcessStarter _start;
  final String Function() _newToken;
  final AppLogger _log;
  final DateTime Function() _now;

  BackendPhase _phase = const BackendStopped();
  BackendPhase get phase => _phase;

  BackendEndpoint? get endpoint => switch (_phase) {
    BackendReady(:final endpoint) => endpoint,
    _ => null,
  };

  int restarts = 0;
  int _failures = 0;
  int _generation = 0;
  bool _stopping = false;
  bool _disposed = false;
  Process? _process;
  Timer? _readyTimer;
  Timer? _restartTimer;
  DateTime? _readyAt;

  Future<void> start() async {
    _stopping = false;
    if (_process != null || _phase is BackendStarting) return;
    await _spawn();
  }

  Future<void> _spawn() async {
    if (_stopping || _disposed) return;
    final gen = ++_generation;
    _readyAt = null;
    _setPhase(const BackendStarting());
    final token = _newToken();
    final Process p;
    try {
      p = await _start(
        executable,
        ['app', '--data-dir', dataDir],
        environment: {
          'NSONLINE_API_TOKEN': token,
          'NSONLINE_LANG': appLocale.value,
        },
      );
    } catch (e) {
      if (gen != _generation) return;
      _log.error('backend: launch failed', e);
      if (e is ProcessException && e.errorCode == 2) {
        _setPhase(BackendFailed(S.errorBackendNotFoundAt(path: executable)));
        return;
      }
      _scheduleRestart('launch failed');
      return;
    }
    if (gen != _generation || _stopping) {
      p.kill();
      return;
    }
    _process = p;
    _readyTimer = Timer(readyTimeout, () {
      if (gen != _generation || _phase is! BackendStarting) return;
      _log.warn('backend: no NSONLINE_READY after $readyTimeout');
      _generation++;
      _process = null;
      p.kill();
      _scheduleRestart('no ready signal');
    });

    var ready = false;
    p.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (gen != _generation) return;
            if (!ready) {
              final info = parseReadyLine(line);
              if (info != null) {
                ready = true;
                _readyTimer?.cancel();
                _readyAt = _now();
                _log.info('backend ${info.version} ready on ${info.addr}');
                _setPhase(
                  BackendReady(
                    BackendEndpoint(
                      baseUrl: info.baseUrl,
                      token: token,
                      version: info.version,
                      pid: info.pid,
                    ),
                  ),
                );
                return;
              }
            }
            _log.debug('backend stdout: $line');
          },
          onError: (Object _) {},
          cancelOnError: false,
        );
    // Drained so a chatty backend never blocks on a full pipe.
    p.stderr.listen((_) {}, onError: (Object _) {});
    unawaited(
      p.exitCode.then((code) {
        if (gen != _generation) return;
        _readyTimer?.cancel();
        _process = null;
        if (_stopping) {
          _setPhase(const BackendStopped());
        } else {
          _log.warn('backend exited (code $code)');
          _scheduleRestart('unexpected exit (code $code)');
        }
      }),
    );
  }

  void _scheduleRestart(String reason) {
    if (_stopping || _disposed) return;
    final readyAt = _readyAt;
    if (readyAt != null && _now().difference(readyAt) >= stableAfter) {
      _failures = 0;
    }
    _failures++;
    final delay = backoffDelay(
      _failures,
      initial: initialBackoff,
      max: maxBackoff,
    );
    _setPhase(
      BackendRestarting(attempt: _failures, delay: delay, reason: reason),
    );
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      restarts++;
      _spawn();
    });
  }

  Future<void> stop() async {
    _stopping = true;
    _restartTimer?.cancel();
    _readyTimer?.cancel();
    final p = _process;
    final ep = endpoint;
    if (p == null) {
      _generation++;
      _setPhase(const BackendStopped());
      return;
    }
    if (ep != null && requestShutdown != null) {
      try {
        await requestShutdown!(ep).timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    try {
      await p.stdin.close();
    } catch (_) {}
    try {
      await p.exitCode.timeout(shutdownGrace);
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
    }
    _process = null;
    _generation++;
    _setPhase(const BackendStopped());
  }

  void _setPhase(BackendPhase p) {
    _phase = p;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopping = true;
    _restartTimer?.cancel();
    _readyTimer?.cancel();
    _process?.kill();
    super.dispose();
  }
}
