// Pure helpers shared by tool/gen_i18n.dart and the tests: load the shared
// catalogs (../shared/i18n/<locale>.json), check them, and render the Dart
// file lib/i18n/strings.g.dart. No Flutter import: runs with plain `dart`.
import 'dart:convert';
import 'dart:io';

const defaultLocale = 'en';

/// One locale's messages: key -> String, or key -> {"one": .., "other": ..}.
typedef Catalog = Map<String, Object>;

final _placeholder = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');

/// Reads every `<locale>.json` in [dir], sorted by locale.
Map<String, Catalog> loadCatalogs(Directory dir) {
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final f in files)
      _basename(f.path).replaceAll('.json', ''): parseCatalog(
        f.readAsStringSync(),
        f.path,
      ),
  };
}

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

Catalog parseCatalog(String source, [String name = 'catalog']) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('$name: top level must be a JSON object');
  }
  final out = <String, Object>{};
  decoded.forEach((k, v) {
    if (v is String) {
      out[k] = v;
    } else if (v is Map && v.values.every((f) => f is String)) {
      out[k] = Map<String, String>.from(v);
    } else {
      throw FormatException(
        '$name: key "$k": want a string or {"one": ..., "other": ...}',
      );
    }
  });
  return out;
}

/// Sorted placeholder names of a message (all plural forms together).
List<String> placeholdersOf(Object message) {
  final text = message is Map ? message.values.join(' ') : message as String;
  return _placeholder.allMatches(text).map((m) => m[1]!).toSet().toList()
    ..sort();
}

/// Same rules as the Go checker (shared/i18n Check): every locale has the
/// keys of en.json, with the same kind and placeholders; plurals have an
/// "other" form and only one/other. Returns one line per problem.
List<String> checkCatalogs(Map<String, Catalog> cats) {
  final problems = <String>[];
  final ref = cats[defaultLocale];
  if (ref == null) return ['missing $defaultLocale.json'];
  for (final loc in cats.keys.toList()..sort()) {
    final cat = cats[loc]!;
    for (final e in cat.entries) {
      final v = e.value;
      if (v is Map) {
        if ((v['other'] ?? '') == '') {
          problems.add('$loc: "${e.key}": plural without an "other" form');
        }
        for (final f in v.keys) {
          if (f != 'one' && f != 'other') {
            problems.add(
              '$loc: "${e.key}": unknown plural form "$f" (use one/other)',
            );
          }
        }
      }
    }
    if (loc == defaultLocale) continue;
    for (final k in ref.keys.toList()..sort()) {
      final v = cat[k];
      if (v == null) {
        problems.add('$loc: missing key "$k"');
        continue;
      }
      final r = ref[k]!;
      if ((r is Map) != (v is Map)) {
        problems.add(
          '$loc: "$k": plural in one file, plain string in the other',
        );
        continue;
      }
      final want = placeholdersOf(r).join(','),
          got = placeholdersOf(v).join(',');
      if (want != got) {
        problems.add('$loc: "$k": placeholders {$got}, en.json has {$want}');
      }
    }
    for (final k in cat.keys.toList()..sort()) {
      if (!ref.containsKey(k)) {
        problems.add('$loc: extra key "$k" (not in $defaultLocale.json)');
      }
    }
  }
  return problems;
}

const _reserved = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
};

/// "home.friends.count" -> "homeFriendsCount".
String identifierOf(String key) {
  final parts = key
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((p) => p.isNotEmpty)
      .toList();
  final b = StringBuffer(parts.first);
  for (final p in parts.skip(1)) {
    b.write(p[0].toUpperCase() + p.substring(1));
  }
  var id = b.toString();
  if (RegExp(r'^[0-9]').hasMatch(id)) id = 'k$id';
  if (_reserved.contains(id)) id = '${id}Text';
  return id;
}

String _lit(String s) {
  final b = StringBuffer("'");
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    switch (c) {
      case r'\':
        b.write(r'\\');
      case "'":
        b.write(r"\'");
      case r'$':
        b.write(r'\$');
      case '\n':
        b.write(r'\n');
      case '\r':
        b.write(r'\r');
      case '\t':
        b.write(r'\t');
      default:
        b.write(c);
    }
  }
  b.write("'");
  return b.toString();
}

String _doc(Object message) {
  final text = message is Map
      ? (message['other'] as String)
      : message as String;
  final line = text.split('\n').first;
  final short = line.length > 70 ? '${line.substring(0, 70)}…' : line;
  return short.replaceAll('*/', '* /');
}

/// Renders lib/i18n/strings.g.dart (a `part of 'i18n.dart'`).
String generateDart(Map<String, Catalog> cats) {
  final problems = checkCatalogs(cats);
  if (problems.isNotEmpty) {
    throw StateError('catalogs are inconsistent:\n${problems.join('\n')}');
  }
  final ref = cats[defaultLocale]!;
  final keys = ref.keys.toList()..sort();
  final ids = <String, String>{};
  for (final k in keys) {
    final id = identifierOf(k);
    if (ids.containsKey(id)) {
      throw StateError('keys "${ids[id]}" and "$k" both map to S.$id');
    }
    ids[id] = k;
  }
  final out = StringBuffer()
    ..writeln('// GENERATED by tool/gen_i18n.dart from shared/i18n/*.json.')
    ..writeln('// Do not edit: change the JSON files, then run `make i18n`.')
    ..writeln('// ignore_for_file: type=lint')
    ..writeln('// dart format off')
    ..writeln()
    ..writeln("part of 'i18n.dart';")
    ..writeln()
    ..writeln('/// Locale codes with a catalog, default first.')
    ..writeln(
      'const List<String> kLocales = [${[defaultLocale, ...cats.keys.where((l) => l != defaultLocale).toList()..sort()].map(_lit).join(', ')}];',
    )
    ..writeln()
    ..writeln('const Map<String, Map<String, Object>> _catalogs = {');
  for (final loc in cats.keys.toList()..sort()) {
    out.writeln('  ${_lit(loc)}: {');
    final cat = cats[loc]!;
    for (final k in cat.keys.toList()..sort()) {
      final v = cat[k]!;
      if (v is Map) {
        final forms = (v.keys.toList()..sort())
            .map((f) => '${_lit(f as String)}: ${_lit(v[f] as String)}')
            .join(', ');
        out.writeln('    ${_lit(k)}: {$forms},');
      } else {
        out.writeln('    ${_lit(k)}: ${_lit(v as String)},');
      }
    }
    out.writeln('  },');
  }
  out
    ..writeln('};')
    ..writeln()
    ..writeln(
      '/// Typed accessors, one per key, in the current locale ([appLocale]).',
    )
    ..writeln('abstract final class S {');
  for (final k in keys) {
    final v = ref[k]!;
    final id = identifierOf(k);
    final ph = placeholdersOf(v);
    out.writeln('  /// ${_doc(v)}');
    if (ph.isEmpty) {
      out.writeln('  static String get $id => t(${_lit(k)});');
    } else {
      final params = ph
          .map((p) => 'required ${p == 'count' ? 'num' : 'Object'} $p')
          .join(', ');
      final args = ph.map((p) => '${_lit(p)}: $p').join(', ');
      out.writeln('  static String $id({$params}) => t(${_lit(k)}, {$args});');
    }
  }
  out.writeln('}');
  return out.toString();
}
