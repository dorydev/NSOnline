import '../i18n/i18n.dart';
import 'json_store.dart';

class LocalPrefs {
  const LocalPrefs({
    this.launchAtLogin = false,
    this.startMinimized = false,
    this.setupSeen = false,
    this.trayNoticeShown = false,
    this.language = kDefaultLocale,
  });

  final bool launchAtLogin;
  final bool startMinimized;

  final bool setupSeen;

  final bool trayNoticeShown;

  final String language;

  LocalPrefs copyWith({
    bool? launchAtLogin,
    bool? startMinimized,
    bool? setupSeen,
    bool? trayNoticeShown,
    String? language,
  }) => LocalPrefs(
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    startMinimized: startMinimized ?? this.startMinimized,
    setupSeen: setupSeen ?? this.setupSeen,
    trayNoticeShown: trayNoticeShown ?? this.trayNoticeShown,
    language: language ?? this.language,
  );

  Map<String, Object> toJson() => {
    'launchAtLogin': launchAtLogin,
    'startMinimized': startMinimized,
    'setupSeen': setupSeen,
    'trayNoticeShown': trayNoticeShown,
    'language': language,
  };

  factory LocalPrefs.fromJson(Map<String, dynamic>? j) => LocalPrefs(
    launchAtLogin: j?['launchAtLogin'] == true,
    startMinimized: j?['startMinimized'] == true,
    setupSeen: j?['setupSeen'] == true,
    trayNoticeShown: j?['trayNoticeShown'] == true,
    language: normalizeLocale(
      j?['language'] is String ? j!['language'] as String : null,
    ),
  );
}

class PrefsStore {
  PrefsStore(this._store);

  PrefsStore.memory([LocalPrefs initial = const LocalPrefs(setupSeen: true)])
    : _store = MemoryJsonStore(initial.toJson());

  final JsonFileStore _store;

  LocalPrefs read() => LocalPrefs.fromJson(_store.read());

  void write(LocalPrefs prefs) {
    try {
      _store.write(prefs.toJson());
    } catch (_) {}
  }

  LocalPrefs update(LocalPrefs Function(LocalPrefs) change) {
    final next = change(read());
    write(next);
    return next;
  }
}
