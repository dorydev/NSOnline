import 'dart:convert';
import 'dart:io';

class JsonFileStore {
  const JsonFileStore(this.file);

  final File file;

  Map<String, dynamic>? read() {
    try {
      if (!file.existsSync()) return null;
      final j = jsonDecode(file.readAsStringSync());
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  void write(Map<String, Object?> value) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeStringSync(jsonEncode(value));
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    tmp.renameSync(file.path);
  }

  void delete() {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}

class MemoryJsonStore implements JsonFileStore {
  MemoryJsonStore([this.value]);

  Map<String, Object?>? value;
  int writes = 0;

  @override
  File get file => File('memory');

  @override
  Map<String, dynamic>? read() => value == null
      ? null
      : jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  @override
  void write(Map<String, Object?> v) {
    writes++;
    value = jsonDecode(jsonEncode(v)) as Map<String, Object?>;
  }

  @override
  void delete() => value = null;
}
