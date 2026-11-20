class SemVer implements Comparable<SemVer> {
  const SemVer(
    this.major,
    this.minor,
    this.patch, [
    this.prerelease = const [],
  ]);

  final int major;
  final int minor;
  final int patch;

  final List<String> prerelease;

  bool get isPrerelease => prerelease.isNotEmpty;

  static final _re = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  static SemVer? tryParse(String input) {
    final m = _re.firstMatch(input.trim());
    if (m == null) return null;
    return SemVer(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      m[4] == null ? const [] : m[4]!.split('.'),
    );
  }

  @override
  int compareTo(SemVer o) {
    for (final (a, b) in [
      (major, o.major),
      (minor, o.minor),
      (patch, o.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    if (prerelease.isEmpty && o.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (o.prerelease.isEmpty) return -1;
    for (var i = 0; i < prerelease.length && i < o.prerelease.length; i++) {
      final a = prerelease[i], b = o.prerelease[i];
      final na = int.tryParse(a), nb = int.tryParse(b);
      final c = switch ((na, nb)) {
        (int x, int y) => x.compareTo(y),
        (int _, null) => -1,
        (null, int _) => 1,
        _ => a.compareTo(b),
      };
      if (c != 0) return c;
    }
    return prerelease.length.compareTo(o.prerelease.length);
  }

  bool operator >(SemVer o) => compareTo(o) > 0;
  bool operator <(SemVer o) => compareTo(o) < 0;

  @override
  bool operator ==(Object other) => other is SemVer && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease.join('.'));

  @override
  String toString() =>
      '$major.$minor.$patch${prerelease.isEmpty ? '' : '-${prerelease.join('.')}'}';
}

bool isNewerVersion(
  String candidate,
  String current, {
  bool allowPrerelease = false,
}) {
  final c = SemVer.tryParse(candidate);
  final cur = SemVer.tryParse(current);
  if (c == null || cur == null) return false;
  if (c.isPrerelease && !allowPrerelease) return false;
  return c > cur;
}
