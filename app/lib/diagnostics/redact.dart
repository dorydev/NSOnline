library;

const _redacted = '[REDACTED]';

const _keyPattern =
    // Bounded affixes: unbounded ones backtrack quadratically on long runs.
    r'[A-Za-z_-]{0,32}(?:token|secret|password|passwd|authorization|api[_-]?key|verifier|cookie)[A-Za-z_-]{0,32}|nsa_?id';

final _rules = <(RegExp, String Function(Match))>[
  // Nintendo login redirect: the fragment holds the session token code.
  (
    RegExp(r'npf[0-9a-f]{16}://auth\S*', caseSensitive: false),
    (_) => 'npf…://auth#$_redacted',
  ),
  (
    RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    (m) => '${m[1]} $_redacted',
  ),
  (
    RegExp(
      '"($_keyPattern)"\\s*:\\s*("(?:[^"\\\\]|\\\\.)*"|[0-9]+)',
      caseSensitive: false,
    ),
    (m) => '"${m[1]}":"$_redacted"',
  ),
  (
    RegExp(
      '\\b($_keyPattern)(\\s*[=:]\\s*)([^\\s&,;"\']+)',
      caseSensitive: false,
    ),
    (m) => '${m[1]}${m[2]}$_redacted',
  ),
  (
    RegExp(
      r'(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}(?:\.[A-Za-z0-9_-]*)?',
    ),
    (_) => '[JWT]',
  ),
  (RegExp(r'\b[0-9a-fA-F]{32,}\b'), (_) => '[HEX]'),
  (RegExp(r'\b[0-9a-f]{16}\b'), (_) => '[NSAID]'),
  (
    RegExp(r'(?<![A-Za-z0-9+/_-])[A-Za-z0-9+/_-]{40,}={0,2}'),
    (m) {
      final v = m[0]!;
      final looksLikePath = v.contains('/') && !RegExp(r'[+=]').hasMatch(v);
      final mixed =
          RegExp(r'[0-9]').hasMatch(v) && RegExp(r'[A-Za-z]').hasMatch(v);
      return mixed && !looksLikePath ? '[SECRET]' : v;
    },
  ),
  (
    RegExp(
      r'(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24}\b',
    ),
    (_) => '[EMAIL]',
  ),
  (
    RegExp(r'(/Users/|/home/|[A-Za-z]:\\Users\\)([^/\\\s]+)'),
    (m) => '${m[1]}[USER]',
  ),
];

String redactSecrets(String input) {
  var s = input;
  for (final (re, replace) in _rules) {
    s = s.replaceAllMapped(re, replace);
  }
  return s;
}
