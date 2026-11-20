import 'dart:io';

const _keyFiles = ['settings.json', 'nso-auth.json', 'app_prefs.json'];

// Folders of older versions, newest first: before the dev.dorydev.nsonline →
// dev.nsonline.app rename, then before the nso_rpc → nsonline rename.
List<String> legacyDataDirs(String newDir, String os) {
  final sep = os == 'windows' ? r'\' : '/';
  String parentOf(String p) {
    final i = p.lastIndexOf(sep);
    return i < 0 ? '' : p.substring(0, i);
  }

  final parent = parentOf(newDir);
  final name = newDir.substring(parent.length + 1);
  return switch ((os, name)) {
    ('macos', 'dev.nsonline.app') => [
      '$parent${sep}dev.dorydev.nsonline',
      '$parent${sep}dev.dorydev.nsoRpc',
    ],
    ('linux', 'dev.nsonline.app') => [
      '$parent${sep}dev.dorydev.nsonline',
      '$parent${sep}dev.dorydev.nso_rpc',
    ],
    ('windows', 'nsonline') => [
      '${parentOf(parent)}${sep}dorydev${sep}nsonline',
      '${parentOf(parent)}${sep}dorydev${sep}nso_rpc',
    ],
    _ => const [],
  };
}

bool _hasData(Directory dir) => _keyFiles.any(
  (f) => File('${dir.path}${Platform.pathSeparator}$f').existsSync(),
);

// Copies the old folder into the new one while the new one has no data yet.
bool migrateLegacyData(String newDir, String? oldDir) {
  if (oldDir == null) return false;
  final from = Directory(oldDir);
  final to = Directory(newDir);
  if (!from.existsSync() || _hasData(to)) return false;

  to.createSync(recursive: true);
  for (final e in from.listSync(recursive: true, followLinks: false)) {
    final rel = e.path.substring(from.path.length);
    final target = '${to.path}$rel';
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File &&
        !e.path.endsWith('backend.lock') &&
        !File(target).existsSync()) {
      File(target).parent.createSync(recursive: true);
      e.copySync(target);
    }
  }
  return true;
}
