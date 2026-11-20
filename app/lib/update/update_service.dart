import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../i18n/i18n.dart';
import 'release.dart';

const latestReleaseUrl =
    'https://api.github.com/repos/dorydev/NSOnline/releases/latest';

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef DetachedStarter =
    Future<void> Function(String executable, List<String> arguments);
typedef ProcessRunnerFn =
    Future<ProcessResult> Function(String executable, List<String> arguments);

Future<void> _defaultStartDetached(String exe, List<String> args) async {
  await Process.start(exe, args, mode: ProcessStartMode.detached);
}

class UpdateService {
  UpdateService({
    http.Client? client,
    required this.tempDir,
    DetachedStarter? startDetached,
    ProcessRunnerFn? run,
    this.pid,
  }) : _client = client ?? http.Client(),
       _startDetached = startDetached ?? _defaultStartDetached,
       _run = run ?? Process.run;

  final http.Client _client;

  final Future<Directory> Function() tempDir;
  final DetachedStarter _startDetached;
  final ProcessRunnerFn _run;

  final int? pid;

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'NSOnline-updater',
  };

  Future<ReleaseInfo?> fetchLatest() async {
    final res = await _client
        .get(Uri.parse(latestReleaseUrl), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw UpdateException(S.updateErrorGithub(status: res.statusCode));
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw UpdateException(S.updateErrorGithubUnreadable);
    }
    final r = ReleaseInfo.fromGitHubJson(json);
    if (r == null || r.draft || r.prerelease) return null;
    return r;
  }

  Future<Map<String, String>> fetchSums(ReleaseInfo release) async {
    final asset = release.asset('SHA256SUMS');
    if (asset == null) {
      throw UpdateException(S.updateErrorNoSums(tag: release.tag));
    }
    final res = await _client
        .get(asset.url, headers: {'User-Agent': 'NSOnline-updater'})
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw UpdateException(S.updateErrorSumsHttp(status: res.statusCode));
    }
    return parseSha256Sums(utf8.decode(res.bodyBytes, allowMalformed: true));
  }

  Future<File> download(
    ReleaseAsset asset,
    Map<String, String> sums, {
    void Function(double progress)? onProgress,
  }) async {
    final expected = sums[asset.name];
    if (expected == null) {
      throw UpdateException(S.updateErrorNoSum(name: asset.name));
    }
    final dir = await tempDir();
    final file = File('${dir.path}${Platform.pathSeparator}${asset.name}');
    final req = http.Request('GET', asset.url)
      ..headers['User-Agent'] = 'NSOnline-updater';
    final res = await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw UpdateException(S.updateErrorDownloadHttp(status: res.statusCode));
    }
    final total = res.contentLength ?? asset.size;
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    final out = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in res.stream.timeout(
        const Duration(seconds: 60),
      )) {
        hasher.add(chunk);
        out.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0, 1));
      }
    } on TimeoutException {
      await out.close();
      await _delete(file);
      throw UpdateException(S.updateErrorInterrupted);
    }
    await out.close();
    hasher.close();
    final actual = digestSink.value.toString();
    if (!sha256Matches(expected, actual)) {
      await _delete(file);
      throw UpdateException(S.updateErrorBadSum(name: asset.name));
    }
    onProgress?.call(1);
    return file;
  }

  Future<void> apply(File file, InstallType install) async {
    final me = pid ?? 0;
    switch (install) {
      case MacAppBundle(:final bundlePath):
        final dir = await tempDir();
        final unpack = '${dir.path}/unpacked';
        // ditto keeps the code signature, symlinks and extended attributes.
        final r = await _run('/usr/bin/ditto', ['-x', '-k', file.path, unpack]);
        if (r.exitCode != 0) {
          throw UpdateException(S.updateErrorBadArchive(code: r.exitCode));
        }
        final app = Directory(unpack)
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.endsWith('.app'))
            .firstOrNull;
        if (app == null) throw UpdateException(S.updateErrorNoApp);
        final script = File('${dir.path}/nsonline-update.sh')
          ..writeAsStringSync(macUpdateScript);
        await _startDetached('/bin/sh', [
          script.path,
          '$me',
          app.path,
          bundlePath,
        ]);
      case WindowsInstaller():
        await _startDetached(file.path, windowsInstallerArgs);
      case LinuxAppImage(:final path):
        final dir = await tempDir();
        final script = File('${dir.path}/nsonline-update.sh')
          ..writeAsStringSync(appImageUpdateScript);
        await _startDetached('/bin/sh', [script.path, '$me', file.path, path]);
      case LinuxDeb():
        final r = await _run('pkexec', ['apt', 'install', '-y', file.path]);
        if (r.exitCode != 0) {
          throw UpdateException(S.updateErrorInstallRefused(code: r.exitCode));
        }
        final dir = await tempDir();
        final script = File('${dir.path}/nsonline-relaunch.sh')
          ..writeAsStringSync(relaunchScript);
        await _startDetached('/bin/sh', [
          script.path,
          '$me',
          '/usr/bin/nsonline-app',
        ]);
      case UnsupportedInstall(:final reason):
        throw UpdateException(S.updateErrorUnavailable(reason: reason));
    }
  }

  static Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }

  void close() => _client.close();
}

const windowsInstallerArgs = [
  '/VERYSILENT',
  '/SUPPRESSMSGBOXES',
  '/CLOSEAPPLICATIONS',
  '/NORESTART',
];

bool sha256Matches(String expected, String actual) {
  final a = expected.trim().toLowerCase(), b = actual.trim().toLowerCase();
  if (a.length != 64 || a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

const macUpdateScript = r'''#!/bin/sh
PID="$1"; NEW="$2"; DEST="$3"
while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
rm -rf "$DEST.old"
if mv "$DEST" "$DEST.old"; then
  if mv "$NEW" "$DEST"; then
    rm -rf "$DEST.old"
  else
    mv "$DEST.old" "$DEST"
  fi
fi
open "$DEST"
''';

const appImageUpdateScript = r'''#!/bin/sh
PID="$1"; NEW="$2"; DEST="$3"
while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
chmod +x "$NEW"
if mv -f "$NEW" "$DEST"; then :; else cp -f "$NEW" "$DEST"; fi
chmod +x "$DEST"
nohup "$DEST" >/dev/null 2>&1 &
''';

const relaunchScript = r'''#!/bin/sh
PID="$1"; APP="$2"
while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
nohup "$APP" >/dev/null 2>&1 &
''';

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
