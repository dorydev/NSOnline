import 'dart:convert';
import 'dart:io';

import 'redact.dart';

enum LogLevel { debug, info, warn, error }

class AppLogger {
  AppLogger(
    this.file, {
    this.maxBytes = 1 << 20,
    this.keep = 3,
    DateTime Function()? now,
    this.echo = false,
  }) : _now = now ?? DateTime.now;

  AppLogger.disabled()
    : file = null,
      maxBytes = 0,
      keep = 0,
      echo = false,
      _now = DateTime.now;

  final File? file;
  final int maxBytes;

  final int keep;
  final bool echo;
  final DateTime Function() _now;

  static AppLogger instance = AppLogger.disabled();

  void debug(String m) => log(LogLevel.debug, m);
  void info(String m) => log(LogLevel.info, m);
  void warn(String m, [Object? error]) => log(LogLevel.warn, m, error);
  void error(String m, [Object? error, StackTrace? stack]) =>
      log(LogLevel.error, m, error, stack);

  void log(LogLevel level, String message, [Object? error, StackTrace? st]) {
    final f = file;
    if (f == null && !echo) return;
    final b = StringBuffer()
      ..write(_now().toUtc().toIso8601String())
      ..write(' ')
      ..write(level.name.toUpperCase().padRight(5))
      ..write(' ')
      ..write(message);
    if (error != null) b.write(' · $error');
    if (st != null) b.write('\n$st');
    final line = '${redactSecrets(b.toString())}\n';
    if (echo) stderr.write(line);
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      _rotateIfNeeded(f, utf8.encode(line).length);
      f.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  void _rotateIfNeeded(File f, int incoming) {
    if (!f.existsSync() || f.lengthSync() + incoming <= maxBytes) return;
    for (var i = keep - 1; i >= 1; i--) {
      final src = File(i == 1 ? f.path : '${f.path}.${i - 1}');
      final dst = File('${f.path}.$i');
      if (src.existsSync()) {
        if (dst.existsSync()) dst.deleteSync();
        src.renameSync(dst.path);
      }
    }
    if (keep <= 1 && f.existsSync()) f.deleteSync();
  }
}

List<String> tailLines(File file, {int lines = 80, int maxBytes = 64 * 1024}) {
  try {
    if (!file.existsSync()) return const [];
    final raf = file.openSync();
    try {
      final len = raf.lengthSync();
      final start = len > maxBytes ? len - maxBytes : 0;
      raf.setPositionSync(start);
      final text = utf8.decode(raf.readSync(len - start), allowMalformed: true);
      final all = const LineSplitter().convert(text);
      final usable = start > 0 && all.isNotEmpty ? all.sublist(1) : all;
      return usable.length <= lines
          ? usable
          : usable.sublist(usable.length - lines);
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return const [];
  }
}
