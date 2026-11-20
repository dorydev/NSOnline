import '../i18n/i18n.dart';
import '../models/models.dart';
import 'repository.dart';

abstract final class MockData {
  static const friends = <Friend>[
    Friend(
      name: 'Léa',
      state: PresenceState.playing,
      game: 'Mario Kart 8 Deluxe',
    ),
    Friend(name: 'Hugo', state: PresenceState.playing, game: 'Zelda: TotK'),
    Friend(name: 'Nathan', state: PresenceState.playing, game: 'Splatoon 3'),
    Friend(name: 'Camille', state: PresenceState.online),
    Friend(name: 'Sarah', state: PresenceState.online),
    Friend(name: 'Inès', state: PresenceState.offline, lastSeen: '3 h ago'),
    Friend(name: 'Théo', state: PresenceState.offline, lastSeen: 'Yesterday'),
    Friend(name: 'Jules', state: PresenceState.offline, lastSeen: '4 days ago'),
  ];

  static const profile = Profile(
    name: 'John Doe',
    avatarInitial: 'J',
    subtitle: 'SW-9999-9999-9999',
    currentGame: 'Mario Kart 8 Deluxe',
    currentSessionMinutes: 42,
    recentGames: [
      RecentGame(name: 'Mario Kart 8 Deluxe', detail: 'Today · 86 h'),
      RecentGame(
        name: 'Animal Crossing: New Horizons',
        detail: 'Yesterday · 212 h',
      ),
      RecentGame(name: 'Splatoon 3', detail: '3 days ago · 41 h'),
      RecentGame(
        name: 'Super Smash Bros. Ultimate',
        detail: '1 week ago · 128 h',
      ),
      RecentGame(name: 'Pikmin 4', detail: '2 weeks ago · 19 h'),
    ],
  );

  static const watchableAccounts = <WatchedAccount>[
    WatchedAccount(name: 'John Doe', nsaId: '[ID]'),
    WatchedAccount(name: 'Léa', nsaId: 'a1b2c3d4e5f60718'),
    WatchedAccount(name: 'Hugo', nsaId: '0f1e2d3c4b5a6978'),
  ];

  static const dashboard = Dashboard(
    friends: friends,
    profile: profile,
    tokens: TokenStatus(
      sessionSaved: true,
      accountExpiresIn: Duration(minutes: 12),
      coralExpiresIn: Duration(hours: 1, minutes: 48),
      zncaValid: true,
    ),
    observerConnected: true,
    observerName: 'John Doe',
    friendsFromMain: true,
    mainAccountName: 'John Doe',
    discordEnabled: true,
    discordConnected: true,
    watchableAccounts: watchableAccounts,
    watched: WatchedAccount(name: 'John Doe', nsaId: '[ID]'),
    config: BackendConfig(
      zncaClientId: '[CLIENT ID]',
      zncaAuthMode: ZncaAuthMode.clientSecret,
      zncaHasSecret: true,
      appVersion: '3.6.0',
    ),
  );
}

class MockRepository implements NsoRepository, BackendApi {
  const MockRepository();

  @override
  String get description => S.mockDescription;

  @override
  Future<Dashboard> load() async => MockData.dashboard;

  @override
  Future<void> setPresenceEnabled(bool enabled) async {}

  @override
  Future<BackendSettings> getSettings() async =>
      const BackendSettings(watchTarget: '[ID]');

  @override
  Future<BackendSettings> putSettings(BackendSettings settings) async =>
      settings;

  @override
  Future<BackendSettings> rollbackSettings() async =>
      const BackendSettings(watchTarget: '[ID]');

  @override
  Future<void> acknowledgeTerms() async {}

  @override
  Future<LoginStart> startLogin(NsoAccount account) async => LoginStart(
    url: Uri.parse('https://accounts.nintendo.com/connect/1.0.0/authorize'),
    redirectPrefix: LoginStart.defaultRedirectPrefix,
  );

  @override
  Future<void> completeLogin(NsoAccount account, String redirect) async {}

  @override
  Future<void> logout(NsoAccount? account) async {}

  @override
  Future<DiscordTestResult> testDiscord() async =>
      const DiscordTestResult(ok: true, discordRunning: true);

  @override
  Future<DiagnosticsResult> runDiagnostics() async => const DiagnosticsResult(
    checks: [
      DiagnosticCheck(name: 'backend', ok: true, latencyMs: 1),
      DiagnosticCheck(name: 'nintendo', ok: true, latencyMs: 180),
      DiagnosticCheck(name: 'coral', ok: true, latencyMs: 240),
      DiagnosticCheck(name: 'znca', ok: true, latencyMs: 310),
      DiagnosticCheck(name: 'discord', ok: true, latencyMs: 4),
    ],
  );

  @override
  Future<WebServiceList> webServices() async => const WebServiceList(
    account: 'main',
    services: [
      WebServiceInfo(
        id: '4834290508791808',
        name: 'SplatNet 3',
        game: 'Splatoon 3',
      ),
      WebServiceInfo(
        id: '4953919198265344',
        name: 'NookLink',
        game: 'Animal Crossing: New Horizons',
      ),
      WebServiceInfo(
        id: '5598642853249024',
        name: 'Smash World',
        game: 'Super Smash Bros. Ultimate',
      ),
    ],
  );

  @override
  Future<WebServiceSession> openWebService(String id) async =>
      WebServiceSession(url: Uri.parse('https://www.nintendo.com/'));

  @override
  Future<void> shutdown() async {}

  @override
  void close() {}
}
