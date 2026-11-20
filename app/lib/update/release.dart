import '../i18n/i18n.dart';
import 'semver.dart';

class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, this.size = 0});

  final String name;
  final Uri url;
  final int size;
}

class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.notes,
    required this.assets,
    this.draft = false,
    this.prerelease = false,
    this.htmlUrl,
  });

  final String tag;
  final SemVer version;
  final String notes;
  final List<ReleaseAsset> assets;
  final bool draft;
  final bool prerelease;
  final Uri? htmlUrl;

  ReleaseAsset? asset(String name) {
    for (final a in assets) {
      if (a.name == name) return a;
    }
    return null;
  }

  static ReleaseInfo? fromGitHubJson(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag_name'];
    if (tag is! String) return null;
    final version = SemVer.tryParse(tag);
    if (version == null) return null;
    final assets = <ReleaseAsset>[];
    final raw = json['assets'];
    if (raw is List) {
      for (final a in raw) {
        if (a is! Map) continue;
        final name = a['name'], url = a['browser_download_url'];
        if (name is! String || url is! String) continue;
        final uri = Uri.tryParse(url);
        if (uri == null || !isTrustedDownloadUrl(uri)) continue;
        assets.add(
          ReleaseAsset(
            name: name,
            url: uri,
            size: a['size'] is int ? a['size'] as int : 0,
          ),
        );
      }
    }
    final html = json['html_url'];
    return ReleaseInfo(
      tag: tag,
      version: version,
      notes: json['body'] is String ? json['body'] as String : '',
      assets: assets,
      draft: json['draft'] == true,
      prerelease: json['prerelease'] == true || version.isPrerelease,
      htmlUrl: html is String ? Uri.tryParse(html) : null,
    );
  }
}

bool isTrustedDownloadUrl(Uri uri) =>
    uri.scheme == 'https' &&
    (uri.host == 'github.com' ||
        uri.host == 'objects.githubusercontent.com' ||
        uri.host == 'release-assets.githubusercontent.com');

sealed class InstallType {
  const InstallType();
}

class MacAppBundle extends InstallType {
  const MacAppBundle(this.bundlePath);

  final String bundlePath;
}

class WindowsInstaller extends InstallType {
  const WindowsInstaller();
}

class LinuxAppImage extends InstallType {
  const LinuxAppImage(this.path);

  final String path;
}

class LinuxDeb extends InstallType {
  const LinuxDeb();
}

class UnsupportedInstall extends InstallType {
  const UnsupportedInstall(this.reason);
  final String reason;
}

InstallType detectInstallType({
  required String os,
  required String resolvedExecutable,
  required Map<String, String> env,
  bool Function(String path)? exists,
}) {
  final has = exists ?? (_) => false;
  switch (os) {
    case 'macos':
      final i = resolvedExecutable.indexOf('.app/Contents/MacOS/');
      if (i < 0) return UnsupportedInstall(S.installNotInApp);
      final bundle = resolvedExecutable.substring(0, i + 4);
      if (bundle.contains('/build/macos/') ||
          bundle.contains('/DerivedData/')) {
        return UnsupportedInstall(S.installDevBuild);
      }
      if (bundle.startsWith('/Volumes/')) {
        return UnsupportedInstall(S.installFromDiskImage);
      }
      return MacAppBundle(bundle);
    case 'windows':
      final dir = resolvedExecutable.substring(
        0,
        resolvedExecutable.lastIndexOf(RegExp(r'[\\/]')).clamp(0, 1 << 30),
      );
      // Inno Setup leaves its uninstaller next to the app.
      if (has('$dir\\unins000.exe')) return const WindowsInstaller();
      return UnsupportedInstall(S.installNoInstaller);
    case 'linux':
      final appImage = env['APPIMAGE'];
      if (appImage != null && appImage.isNotEmpty) {
        return LinuxAppImage(appImage);
      }
      if (resolvedExecutable.startsWith('/opt/nsonline/')) {
        return const LinuxDeb();
      }
      return UnsupportedInstall(S.installManual);
    default:
      return UnsupportedInstall(S.installUnsupportedOs(os: os));
  }
}

String? assetNameFor({
  required SemVer version,
  required String os,
  required String arch,
  required InstallType install,
}) {
  final v = version.toString();
  final a = arch.toLowerCase();
  final x64 = a == 'x64' || a == 'x86_64' || a == 'amd64';
  return switch ((os, install)) {
    ('macos', MacAppBundle()) => 'NSOnline-$v-macos-universal.zip',
    // x64 installer: also runs on Windows on ARM (emulation).
    ('windows', WindowsInstaller()) when x64 || a == 'arm64' =>
      'NSOnline-$v-windows-x64-setup.exe',
    ('linux', LinuxAppImage()) when x64 => 'NSOnline-$v-linux-x86_64.AppImage',
    ('linux', LinuxDeb()) when x64 => 'NSOnline-$v-linux-amd64.deb',
    _ => null,
  };
}

ReleaseAsset? selectAsset(
  ReleaseInfo release, {
  required String os,
  required String arch,
  required InstallType install,
}) {
  final name = assetNameFor(
    version: release.version,
    os: os,
    arch: arch,
    install: install,
  );
  return name == null ? null : release.asset(name);
}

Map<String, String> parseSha256Sums(String text) {
  final out = <String, String>{};
  final re = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$');
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final m = re.firstMatch(line);
    if (m == null) continue;
    var name = m[2]!.trim();
    if (name.startsWith('./')) name = name.substring(2);
    out[name] = m[1]!.toLowerCase();
  }
  return out;
}

String archFromVersionString(String dartVersion) {
  final m = RegExp(r'on "\w+_(\w+)"').firstMatch(dartVersion);
  return m?[1] ?? 'x64';
}
