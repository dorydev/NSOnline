import '../data/http_repository.dart' show playTimeShort;
import '../i18n/i18n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../widgets/live_clock.dart' show sessionDurationLabel;

class TrayEntry {
  const TrayEntry.info(this.label)
    : key = null,
      checked = null,
      separator = false;
  const TrayEntry.action(String this.key, this.label)
    : checked = null,
      separator = false;
  const TrayEntry.check(String this.key, this.label, bool this.checked)
    : separator = false;
  const TrayEntry.separator()
    : key = null,
      label = '',
      checked = null,
      separator = true;

  final String? key;
  final String label;
  final bool? checked;
  final bool separator;

  @override
  bool operator ==(Object other) =>
      other is TrayEntry &&
      other.key == key &&
      other.label == label &&
      other.checked == checked &&
      other.separator == separator;

  @override
  int get hashCode => Object.hash(key, label, checked, separator);

  @override
  String toString() => separator ? '---' : '${key ?? 'info'}: $label';
}

abstract final class TrayAction {
  static const presence = 'presence';
  static const open = 'open';
  static const logout = 'logout';
  static const quit = 'quit';
  static const webServicePrefix = 'ws:';
}

String? webServiceIdOf(String? key) =>
    key != null && key.startsWith(TrayAction.webServicePrefix)
    ? key.substring(TrayAction.webServicePrefix.length)
    : null;

List<TrayEntry> _gameLines(AppState state, DateTime? now) {
  final game = state.currentGameName;
  if (game == null) {
    return [
      TrayEntry.info(switch (state.livePresence?.state) {
        LiveState.idle || LiveState.online => S.trayConsoleOnNoGame,
        LiveState.offline => S.trayOffline,
        _ => state.watched == null ? S.trayNoAccount : S.trayNothingPlaying,
      }),
    ];
  }

  final session = state.sessionElapsed(now);
  final total = state.livePresence?.game?.totalPlayTimeMinutes ?? 0;
  final parts = [
    if (session != null)
      S.traySession(
        duration: sessionDurationLabel(Duration(minutes: session.inMinutes)),
      ),
    if (total > 0) S.trayTotal(duration: playTimeShort(total)),
  ];

  return [
    TrayEntry.info(S.trayPlaying(game: game)),
    if (parts.isNotEmpty) TrayEntry.info(parts.join(' · ')),
  ];
}

// Same layout as nxapi's menu: account, presence toggle, actions, web services.
List<TrayEntry> trayMenuEntries(AppState state, {DateTime? now}) {
  final profile = state.profile;
  final coral = state.coral;
  final services = state.webServices.services;

  return [
    if (profile != null) ...[
      TrayEntry.info(S.trayAccount(name: profile.name)),
      if (profile.subtitle.isNotEmpty) TrayEntry.info(profile.subtitle),
    ],
    ..._gameLines(state, now),
    TrayEntry.info(
      coral.state == CoralState.ok && coral.latencyMs > 0
          ? S.trayCoralWithLatency(status: coral.label, ms: coral.latencyMs)
          : S.trayCoral(status: coral.label),
    ),
    TrayEntry.info(
      !state.presenceEnabled
          ? S.trayDiscordOff
          : state.discordConnected
          ? S.trayDiscordConnected
          : S.trayDiscordNotConnected,
    ),
    const TrayEntry.separator(),
    TrayEntry.check(
      TrayAction.presence,
      S.trayEnablePresence,
      state.presenceEnabled,
    ),
    if (services.isNotEmpty) ...[
      const TrayEntry.separator(),
      TrayEntry.info(S.trayWebServices),
      for (final s in services)
        s.available
            ? TrayEntry.action(
                '${TrayAction.webServicePrefix}${s.id}',
                s.game.isEmpty ? s.name : s.game,
              )
            : TrayEntry.info(s.game.isEmpty ? s.name : s.game),
    ],
    const TrayEntry.separator(),
    TrayEntry.action(TrayAction.open, S.trayOpen),
    TrayEntry.action(TrayAction.logout, S.trayLogout),
    const TrayEntry.separator(),
    TrayEntry.action(TrayAction.quit, S.trayQuit),
  ];
}
