library;

import 'package:characters/characters.dart';

import '../i18n/i18n.dart';

String initialOf(String name) {
  final trimmed = name.replaceAll(RegExp(r'[\[\]]'), '').trim();
  return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
}

enum PresenceState { offline, online, playing }

class Friend {
  const Friend({
    required this.name,
    required this.state,
    this.nsaId = '',
    this.game,
    this.lastSeen,
    this.avatarUrl,
    this.gameImageUrl,
  });

  final String name;
  final String nsaId;
  final PresenceState state;

  final String? game;

  final String? lastSeen;

  final String? avatarUrl;
  final String? gameImageUrl;

  bool get isOnline => state != PresenceState.offline;
  String get initial => initialOf(name);

  String get statusLine => switch (state) {
    PresenceState.playing => game ?? S.presenceInGame,
    PresenceState.online => S.presenceOnline,
    PresenceState.offline => S.presenceOffline,
  };

  String get details => state == PresenceState.offline && lastSeen != null
      ? S.presenceOfflineSince(name: name, lastSeen: lastSeen!)
      : S.presenceNameStatus(name: name, status: statusLine);
}

class RecentGame {
  const RecentGame({required this.name, required this.detail, this.imageUrl});

  final String name;

  final String detail;
  final String? imageUrl;
}

class Profile {
  const Profile({
    required this.name,
    required this.avatarInitial,
    required this.subtitle,
    required this.currentGame,
    required this.currentSessionMinutes,
    this.recentGames = const [],
    this.avatarUrl,
    this.gameImageUrl,
  });

  final String name;
  final String avatarInitial;

  final String subtitle;
  final String? currentGame;
  final int currentSessionMinutes;
  final List<RecentGame> recentGames;
  final String? avatarUrl;
  final String? gameImageUrl;
}

enum ZncaAuthMode { clientSecret, sharedSecret, none }

class TokenStatus {
  const TokenStatus({
    required this.sessionSaved,
    required this.accountExpiresIn,
    required this.coralExpiresIn,
    required this.zncaValid,
  });

  static const empty = TokenStatus(
    sessionSaved: false,
    accountExpiresIn: null,
    coralExpiresIn: null,
    zncaValid: false,
  );

  final bool sessionSaved;
  final Duration? accountExpiresIn;
  final Duration? coralExpiresIn;
  final bool zncaValid;
}

class WatchedAccount {
  const WatchedAccount({required this.name, required this.nsaId});

  final String name;
  final String nsaId;

  String get label => S.watchedLabel(name: name, nsaId: nsaId);

  @override
  bool operator ==(Object other) =>
      other is WatchedAccount && other.nsaId == nsaId && other.name == name;

  @override
  int get hashCode => Object.hash(name, nsaId);
}

class BackendConfig {
  const BackendConfig({
    this.discordSwitch2Id = '',
    this.discordSwitchId = '',
    this.discordDefaultId = '',
    this.interval = const Duration(seconds: 15),
    this.idleInterval = const Duration(seconds: 15),
    this.zncaClientId = '',
    this.zncaAuthMode = ZncaAuthMode.none,
    this.zncaHasSecret = false,
    this.contact = '',
    this.appVersion = '',
  });

  final String discordSwitch2Id;
  final String discordSwitchId;
  final String discordDefaultId;
  final Duration interval;
  final Duration idleInterval;
  final String zncaClientId;
  final ZncaAuthMode zncaAuthMode;
  final bool zncaHasSecret;
  final String contact;
  final String appVersion;
}

class Dashboard {
  const Dashboard({
    required this.friends,
    required this.profile,
    required this.tokens,
    required this.observerConnected,
    required this.observerName,
    required this.discordEnabled,
    required this.discordConnected,
    required this.watchableAccounts,
    required this.watched,
    required this.config,
    this.error,
    this.friendsFromMain = false,
    this.mainAccountName,
    this.setup = SetupStatus.legacy,
    this.coral = CoralStatus.unknown,
    this.presence,
    this.backendVersion,
    this.mainConnected = false,
  });

  final List<Friend> friends;
  final Profile? profile;
  final TokenStatus tokens;
  final bool observerConnected;
  final String observerName;
  final bool discordEnabled;
  final bool discordConnected;
  final List<WatchedAccount> watchableAccounts;
  final WatchedAccount? watched;
  final BackendConfig config;

  final String? error;

  final bool friendsFromMain;
  final String? mainAccountName;

  final SetupStatus setup;
  final CoralStatus coral;

  final LivePresence? presence;
  final String? backendVersion;
  final bool mainConnected;
}

class SetupStatus {
  const SetupStatus({
    required this.thirdPartyAck,
    required this.observerLoggedIn,
    required this.mainLoggedIn,
    required this.targetSet,
    required this.complete,
    this.known = true,
  });

  static const legacy = SetupStatus(
    thirdPartyAck: true,
    observerLoggedIn: true,
    mainLoggedIn: false,
    targetSet: true,
    complete: true,
    known: false,
  );

  final bool thirdPartyAck;
  final bool observerLoggedIn;
  final bool mainLoggedIn;
  final bool targetSet;
  final bool complete;

  final bool known;
}

enum CoralState { ok, degraded, down, unknown }

class CoralStatus {
  const CoralStatus({
    required this.state,
    this.latencyMs = 0,
    this.lastSuccess,
    this.lastError = '',
    this.lastErrorCode = 0,
    this.consecutiveFailures = 0,
    this.retryAfterSeconds = 0,
  });

  static const unknown = CoralStatus(state: CoralState.unknown);

  final CoralState state;
  final int latencyMs;
  final DateTime? lastSuccess;
  final String lastError;
  final int lastErrorCode;
  final int consecutiveFailures;
  final int retryAfterSeconds;

  String get label => switch (state) {
    CoralState.ok => S.coralOk,
    CoralState.degraded => S.coralDegraded,
    CoralState.down => S.coralDown,
    CoralState.unknown => S.coralUnknown,
  };
}

enum LiveState { offline, online, playing, idle }

class LiveGame {
  const LiveGame({
    required this.name,
    this.imageUrl,
    this.totalPlayTimeMinutes = 0,
    this.sysDescription = '',
  });

  final String name;
  final String? imageUrl;
  final int totalPlayTimeMinutes;
  final String sysDescription;

  @override
  bool operator ==(Object other) =>
      other is LiveGame && other.name == name && other.imageUrl == imageUrl;

  @override
  int get hashCode => Object.hash(name, imageUrl);
}

class LivePresence {
  const LivePresence({
    required this.state,
    this.game,
    this.startedAt,
    this.platform = 0,
    this.discordApp = 'default',
  });

  final LiveState state;
  final LiveGame? game;

  final DateTime? startedAt;

  final int platform;
  final String discordApp;

  bool get playing => state == LiveState.playing && game != null;
}

class BackendSettings {
  const BackendSettings({
    this.watchTarget = '',
    this.intervalSeconds = 15,
    this.idleIntervalSeconds = 15,
    this.friendsIntervalSeconds = 60,
    this.showIdle = true,
    this.discordEnabled = true,
  });

  final String watchTarget;
  final int intervalSeconds;
  final int idleIntervalSeconds;
  final int friendsIntervalSeconds;
  final bool showIdle;
  final bool discordEnabled;

  BackendSettings copyWith({
    String? watchTarget,
    int? intervalSeconds,
    int? idleIntervalSeconds,
    int? friendsIntervalSeconds,
    bool? showIdle,
    bool? discordEnabled,
  }) => BackendSettings(
    watchTarget: watchTarget ?? this.watchTarget,
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
    idleIntervalSeconds: idleIntervalSeconds ?? this.idleIntervalSeconds,
    friendsIntervalSeconds:
        friendsIntervalSeconds ?? this.friendsIntervalSeconds,
    showIdle: showIdle ?? this.showIdle,
    discordEnabled: discordEnabled ?? this.discordEnabled,
  );

  Map<String, Object> toJson() => {
    'watchTarget': watchTarget,
    'intervalSeconds': intervalSeconds,
    'idleIntervalSeconds': idleIntervalSeconds,
    'friendsIntervalSeconds': friendsIntervalSeconds,
    'showIdle': showIdle,
    'discordEnabled': discordEnabled,
  };

  @override
  bool operator ==(Object other) =>
      other is BackendSettings &&
      other.watchTarget == watchTarget &&
      other.intervalSeconds == intervalSeconds &&
      other.idleIntervalSeconds == idleIntervalSeconds &&
      other.friendsIntervalSeconds == friendsIntervalSeconds &&
      other.showIdle == showIdle &&
      other.discordEnabled == discordEnabled;

  @override
  int get hashCode => Object.hash(
    watchTarget,
    intervalSeconds,
    idleIntervalSeconds,
    friendsIntervalSeconds,
    showIdle,
    discordEnabled,
  );
}

class LoginStart {
  const LoginStart({required this.url, required this.redirectPrefix});

  static const defaultRedirectPrefix = 'npf71b963c1b7b6d119://auth';

  final Uri url;
  final String redirectPrefix;
}

enum NsoAccount { observer, main }

class DiagnosticCheck {
  const DiagnosticCheck({
    required this.name,
    required this.ok,
    this.latencyMs = 0,
    this.detail = '',
  });

  final String name;
  final bool ok;
  final int latencyMs;
  final String detail;

  String get label => switch (name) {
    'nintendo' => S.checkNintendo,
    'coral' => S.checkCoral,
    'znca' => S.checkZnca,
    'discord' => S.checkDiscord,
    'backend' => S.checkBackend,
    _ => name,
  };
}

class DiagnosticsResult {
  const DiagnosticsResult({required this.checks, this.at});

  final List<DiagnosticCheck> checks;
  final DateTime? at;

  bool get allOk => checks.isNotEmpty && checks.every((c) => c.ok);
}

class DiscordTestResult {
  const DiscordTestResult({
    required this.ok,
    required this.discordRunning,
    this.error = '',
  });

  final bool ok;
  final bool discordRunning;
  final String error;
}

class WebServiceInfo {
  const WebServiceInfo({
    required this.id,
    required this.name,
    this.game = '',
    this.imageUrl,
    this.available = true,
    this.reason = '',
  });

  final String id;
  final String name;
  final String game;
  final String? imageUrl;
  final bool available;
  final String reason;
}

class WebServiceList {
  const WebServiceList({this.account = 'none', this.services = const []});

  static const empty = WebServiceList();

  final String account;
  final List<WebServiceInfo> services;
}

class WebServiceCookie {
  const WebServiceCookie({
    required this.name,
    required this.value,
    this.domain = '',
  });

  final String name;
  final String value;
  final String domain;
}

class WebServiceSession {
  const WebServiceSession({
    required this.url,
    this.userAgent = '',
    this.cookies = const [],
    this.headers = const {},
  });

  final Uri url;
  final String userAgent;
  final List<WebServiceCookie> cookies;
  final Map<String, String> headers;
}
