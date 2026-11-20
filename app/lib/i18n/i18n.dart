library;

import 'package:flutter/foundation.dart';

part 'strings.g.dart';

const String kDefaultLocale = 'en';

final ValueNotifier<String> appLocale = ValueNotifier<String>(kDefaultLocale);

String normalizeLocale(String? code) {
  var c = (code ?? '').trim().toLowerCase();
  final i = c.indexOf(RegExp(r'[-_.@]'));
  if (i >= 0) c = c.substring(0, i);
  return _catalogs.containsKey(c) ? c : kDefaultLocale;
}

String setLocale(String? code) => appLocale.value = normalizeLocale(code);

String t(String key, [Map<String, Object?> args = const {}]) =>
    tr(appLocale.value, key, args);

String tr(String locale, String key, [Map<String, Object?> args = const {}]) {
  final msg = _catalogs[locale]?[key] ?? _catalogs[kDefaultLocale]![key];
  if (msg == null) return key;
  var text = msg is Map
      ? (msg[pluralCategory(locale, args['count'])] ?? msg['other']) as String
      : msg as String;
  if (args.isEmpty || !text.contains('{')) return text;
  return text.replaceAllMapped(_placeholder, (m) {
    final name = m[1]!;
    return args.containsKey(name) ? '${args[name]}' : m[0]!;
  });
}

final _placeholder = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');

String pluralCategory(String locale, Object? count) {
  final n = count is num ? count : num.tryParse('$count');
  if (n == null) return 'other';
  return switch (locale) {
    'fr' => n >= 0 && n < 2 ? 'one' : 'other',
    _ => n == 1 ? 'one' : 'other',
  };
}

String localeName(String locale) => tr(locale, 'language.name');
