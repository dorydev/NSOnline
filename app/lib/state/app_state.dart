import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';

import '../backend/backend_supervisor.dart';
import '../data/repository.dart';
import '../i18n/i18n.dart';
import '../models/models.dart';
import '../storage/json_store.dart';
import '../storage/local_prefs.dart';
import 'settings_controller.dart';

enum ConnectionStatus { connecting, connected, reconnecting, failed }

class AppState extends ChangeNotifier {
  AppState(
    this.repository, {
    BackendApi? api,
    SettingsController? settings,
    PrefsStore? prefs,
    JsonFileStore? draftStore,
    this.supervisor,
    this.embedded = false,
    this.webServicesOn = webServicesEnabled,
    DateTime Function()? now,
    Future<void> Function({
      required bool launchAtLogin,
      required bool startMinimized,
    })?
    applyStartup,
  }) : api =
           api ?? (repository is BackendApi ? repository as BackendApi : null),
       prefs = prefs ?? PrefsStore.memory(),
       _now = now ?? DateTime.now {
    this.settings =
        settings ??
        SettingsController(
          api: this.api,
          store: draftStore ?? MemoryJsonStore(),
          readLocal: () {
            final p = this.prefs.read();
            return (
              launchAtLogin: p.launchAtLogin,
              startMinimized: p.startMinimized,
            );
          },
          applyLocal: applyStartup ?? _saveStartupPrefs,
          fallback: () => BackendSettings(
            watchTarget: watched?.nsaId ?? '',
            intervalSeconds: interval.inSeconds,
            idleIntervalSeconds: idleInterval.inSeconds,
            discordEnabled: presenceEnabled,
          ),
          now: _now,
        );
    setLocale(this.prefs.read().language);
    if (supervisor != null) {
      connection = ConnectionStatus.connecting;
      supervisor!.addListener(_onBackendPhase);
      _onBackendPhase();
    }
  }

  String get language => appLocale.value;

  void setLanguage(String code) {
    final l = setLocale(code);
    prefs.update((p) => p.copyWith(language: l));
    _notify();
    unawaited(refresh());
  }

  final NsoRepository repository;
  final BackendApi? api;
  final PrefsStore prefs;
  late final SettingsController settings;

  final BackendSupervisor? supervisor;

  final bool embedded;
  final bool webServicesOn;
  final DateTime Function() _now;
  Timer? _timer;

  bool loading = true;

  String? backendError;

  String? presenceError;
  DateTime? lastUpdated;

  ConnectionStatus connection = ConnectionStatus.connected;

  List<Friend> friends = const [];
  Profile? profile;
  TokenStatus tokens = TokenStatus.empty;

  bool observerConnected = false;
  String observerName = '';
  String get observerInitial => initialOf(observerName);
  bool mainConnected = false;

  bool discordConnected = false;
  bool presenceEnabled = false;

  List<WatchedAccount> watchableAccounts = const [];
  bool friendsFromMain = false;
  String? mainAccountName;
  WatchedAccount? watched;

  Duration interval = const Duration(seconds: 15);
  Duration idleInterval = const Duration(seconds: 15);

  SetupStatus setup = SetupStatus.legacy;
  CoralStatus coral = CoralStatus.unknown;
  LivePresence? livePresence;
  String? backendVersion;

  int get onlineCount => friends.where((f) => f.isOnline).length;

  String get sharingLabel {
    if (!presenceEnabled) return S.sharingOff;
    final game = profile?.currentGame;
    return game == null ? S.sharingNothing : S.sharingGame(game: game);
  }

  bool get needsSetup =>
      lastUpdated != null &&
      setup.known &&
      (!setup.complete || !prefs.read().setupSeen);

  String? get currentGameName => livePresence?.playing == true
      ? livePresence!.game!.name
      : profile?.currentGame;

  String? get currentGameImage => livePresence?.playing == true
      ? livePresence!.game!.imageUrl
      : profile?.gameImageUrl;

  Duration? sessionElapsed([DateTime? at]) {
    final lp = livePresence;
    if (lp != null && lp.playing && lp.startedAt != null) {
      final d = (at ?? _now()).difference(lp.startedAt!);
      return d.isNegative ? Duration.zero : d;
    }
    final p = profile;
    if (p?.currentGame == null) return null;
    return Duration(minutes: p!.currentSessionMinutes);
  }

  void startAutoRefresh({Duration every = const Duration(seconds: 5)}) {
    refresh();
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => refresh());
  }

  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _disposed = false;

  int _epoch = 0;

  bool? _pendingPresence;

  bool _backendPresence = false;

  WatchedAccount? _watchedOverride;
  bool _observerDisconnected = false;

  Future<void> refresh() async {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    final epoch = _epoch;

    try {
      final d = await repository.load();
      if (_disposed) return;
      if (epoch != _epoch) {
        _refreshAgain = true;
        return;
      }

      _apply(d);
      backendError = null;
      lastUpdated = _now();
      _maybeLoadWebServices();
      if (supervisor == null || supervisor!.phase is BackendReady) {
        connection = ConnectionStatus.connected;
      }
    } on BackendException catch (e) {
      backendError = e.message;
      if (e.isConnectionError) settings.connectionLost();
    } catch (e) {
      backendError = S.errorUnexpectedBackend(error: e);
    } finally {
      _refreshing = false;
      loading = false;
      _notify();
      if (_refreshAgain && !_disposed) {
        _refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  void _apply(Dashboard d) {
    friends = d.friends;
    profile = d.profile;
    tokens = d.tokens;
    observerConnected = d.observerConnected && !_observerDisconnected;
    observerName = d.observerName;
    mainConnected = d.mainConnected;
    _backendPresence = d.discordEnabled;
    presenceEnabled = _pendingPresence ?? d.discordEnabled;
    discordConnected = d.discordConnected;
    watchableAccounts = d.watchableAccounts;
    watched = _watchedOverride ?? d.watched;
    friendsFromMain = d.friendsFromMain;
    mainAccountName = d.mainAccountName;
    presenceError = d.error;
    interval = d.config.interval;
    idleInterval = d.config.idleInterval;
    setup = d.setup;
    coral = d.coral;
    livePresence = d.presence;
    backendVersion = d.backendVersion;
  }

  Future<void> setPresenceEnabled(bool on) async {
    _pendingPresence = on;
    _set(() => presenceEnabled = on);

    try {
      await repository.setPresenceEnabled(on);
      if (_pendingPresence == on) _backendPresence = on;
    } catch (e) {
      // The backend is up: show the reason, not the unreachable banner.
      presenceError = S.errorPresenceNotChanged(
        error: e is BackendException ? e.message : e,
      );
      if (_pendingPresence == on) presenceEnabled = _backendPresence;
    } finally {
      if (_pendingPresence == on) _pendingPresence = null;
      _notify();
    }
  }

  void setWatched(WatchedAccount v) =>
      _set(() => watched = _watchedOverride = v);

  void disconnectObserver() => _set(() {
    _observerDisconnected = true;
    observerConnected = false;
  });

  BackendApi get _api =>
      api ?? (throw BackendException(S.errorActionUnavailable));

  Future<T> _mutate<T>(Future<T> Function(BackendApi api) action) async {
    _epoch++;
    try {
      return await action(_api);
    } finally {
      _epoch++;
      unawaited(refresh());
    }
  }

  Future<void> acknowledgeTerms() => _mutate((a) => a.acknowledgeTerms());

  Future<LoginStart> startLogin(NsoAccount account) => _api.startLogin(account);

  Future<void> completeLogin(NsoAccount account, String redirect) =>
      _mutate((a) async {
        await a.completeLogin(account, redirect);
        if (account == NsoAccount.observer) _observerDisconnected = false;
      });

  Future<void> logout(NsoAccount? account) => _mutate((a) async {
    await a.logout(account);
    if (account != NsoAccount.main) disconnectObserver();
    if (account == null) {
      prefs.update((p) => p.copyWith(setupSeen: false));
      mainConnected = false;
    }
  });

  Future<void> setWatchTarget(String nsaId) => _mutate((a) async {
    BackendSettings current;
    try {
      current = await a.getSettings();
    } on BackendException catch (e) {
      if (e.statusCode != 404) rethrow;
      current = const BackendSettings();
    }
    await a.putSettings(current.copyWith(watchTarget: nsaId));
    _watchedOverride = null;
  });

  void finishSetup() {
    prefs.update((p) => p.copyWith(setupSeen: true));
    _notify();
  }

  WebServiceList webServices = WebServiceList.empty;
  String? openingService;
  String? webServiceError;
  String? _webServicesFor;
  DateTime? _webServicesAt;
  bool _webServicesLoading = false;

  // The backend fetches the card images in the background: reload the list
  // every 20 s until they're all there.
  bool get _webImagesMissing =>
      webServices.services.any((s) => s.available && s.imageUrl == null);

  void _maybeLoadWebServices() {
    final api = this.api;
    if (!webServicesOn || api == null || _webServicesLoading) return;

    final key = '$observerConnected|$mainConnected';
    final at = _webServicesAt;
    final due =
        at == null || _now().difference(at) >= const Duration(seconds: 20);
    if (key == _webServicesFor && !(due && _webImagesMissing)) return;

    _webServicesFor = key;
    _webServicesAt = _now();
    _webServicesLoading = true;
    api
        .webServices()
        .then((list) {
          webServices = list;
          _notify();
        })
        .catchError((_) {})
        .whenComplete(() => _webServicesLoading = false);
  }

  Future<WebServiceSession?> openWebService(WebServiceInfo service) async {
    if (openingService != null) return null;
    _set(() {
      openingService = service.id;
      webServiceError = null;
    });

    try {
      return await _api.openWebService(service.id);
    } on BackendException catch (e) {
      webServiceError = switch (e.code) {
        'not_owned' => S.homeServicesNotOwned(name: service.name),
        'not_logged_in' => S.homeServicesNoAccount,
        _ => S.homeServicesFailed(name: service.name, error: e.message),
      };
      return null;
    } finally {
      openingService = null;
      _notify();
    }
  }

  DiscordTestResult? discordTest;
  bool discordTesting = false;
  Future<DiscordTestResult?>? _discordTest;

  Future<DiscordTestResult?> testDiscord() =>
      _discordTest ??= _testDiscord().whenComplete(() => _discordTest = null);

  Future<DiscordTestResult?> _testDiscord() async {
    _set(() => discordTesting = true);

    try {
      discordTest = await _api.testDiscord();
    } on BackendException catch (e) {
      discordTest = DiscordTestResult(
        ok: false,
        discordRunning: false,
        error: e.message,
      );
    } finally {
      discordTesting = false;
      _notify();
    }
    return discordTest;
  }

  DiagnosticsResult? diagnostics;
  bool diagnosticsRunning = false;
  String? diagnosticsError;
  DateTime? _diagnosticsRetryAt;
  Future<void>? _diagnostics;

  int diagnosticsCooldown([DateTime? at]) {
    final r = _diagnosticsRetryAt;
    if (r == null) return 0;
    final s = r.difference(at ?? _now()).inMilliseconds / 1000;
    return s <= 0 ? 0 : s.ceil();
  }

  Future<void> runDiagnostics() => _diagnostics ??= _runDiagnostics()
      .whenComplete(() => _diagnostics = null);

  Future<void> _runDiagnostics() async {
    final wait = diagnosticsCooldown();
    if (wait > 0) {
      _set(() => diagnosticsError = S.errorRetryIn(seconds: wait));
      return;
    }

    _set(() {
      diagnosticsRunning = true;
      diagnosticsError = null;
    });

    try {
      diagnostics = await _api.runDiagnostics();
      _diagnosticsRetryAt = null;
    } on BackendException catch (e) {
      if (e.isRateLimited) {
        final retry = e.retryAfter ?? const Duration(seconds: 10);
        _diagnosticsRetryAt = _now().add(retry);
        diagnosticsError = S.errorTestTooSoon(seconds: retry.inSeconds);
      } else {
        diagnosticsError = e.message;
      }
    } finally {
      diagnosticsRunning = false;
      _notify();
    }
  }

  ConnectionStatus? _lastPhaseStatus;

  void _onBackendPhase() {
    final s = supervisor;
    if (s == null || _disposed) return;
    switch (s.phase) {
      case BackendReady():
        connection = ConnectionStatus.connected;
        if (_lastPhaseStatus != null) unawaited(refresh());
      case BackendRestarting():
        connection = ConnectionStatus.reconnecting;
        settings.connectionLost();
      case BackendStarting():
        connection =
            _lastPhaseStatus == null ||
                _lastPhaseStatus == ConnectionStatus.connecting
            ? ConnectionStatus.connecting
            : ConnectionStatus.reconnecting;
      case BackendFailed(:final message):
        connection = ConnectionStatus.failed;
        backendError = message;
      case BackendStopped():
        break;
    }
    _lastPhaseStatus = connection;
    _notify();
  }

  Future<void> _saveStartupPrefs({
    required bool launchAtLogin,
    required bool startMinimized,
  }) async {
    prefs.update(
      (p) => p.copyWith(
        launchAtLogin: launchAtLogin,
        startMinimized: startMinimized,
      ),
    );
  }

  void _set(VoidCallback change) {
    change();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    supervisor?.removeListener(_onBackendPhase);
    settings.dispose();
    repository.close();
    super.dispose();
  }
}
