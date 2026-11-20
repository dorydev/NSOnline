import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../i18n/i18n.dart';
import '../models/models.dart';
import 'repository.dart';

String? _str(Object? v) => switch (v) {
  String s => s,
  num n => n.toString(),
  _ => null,
};

num? _num(Object? v) => switch (v) {
  num n => n,
  String s => num.tryParse(s.trim()),
  _ => null,
};

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

List<Object?> _list(Object? v) => v is List ? v : const [];

int _int(Object? v) => _num(v)?.toInt() ?? 0;

String? _nonEmpty(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

DateTime? _time(Object? iso) => iso is String ? DateTime.tryParse(iso) : null;

DateTime? _fromUnix(Object? secs) {
  final v = _num(secs);
  if (v == null || v <= 0 || v > 95617584000) return null;
  return DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
}

Duration? _until(Object? iso, DateTime now) {
  if (iso is! String) return null;
  final t = DateTime.tryParse(iso);
  return t?.difference(now);
}

class HttpRepository implements NsoRepository, BackendApi {
  HttpRepository({
    String baseUrl = 'http://127.0.0.1:7878',
    String? token,
    http.Client? client,
    DateTime Function()? now,
    bool connected = true,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now {
    setEndpoint(baseUrl, token: token);
    if (!connected) _baseUrl = null;
  }

  String? _baseUrl;
  String _lastBaseUrl = '';
  String? _token;
  final http.Client _client;
  final DateTime Function() _now;

  static const _headers = {'X-NSO-RPC': '1', 'Accept': 'application/json'};
  static const timeout = Duration(seconds: 4);

  static const slowTimeout = Duration(seconds: 30);

  String get baseUrl => _baseUrl ?? _lastBaseUrl;

  bool get hasEndpoint => _baseUrl != null;

  void setEndpoint(String baseUrl, {String? token}) {
    if (!isLoopbackApi(Uri.tryParse(baseUrl))) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be a loopback address (127.0.0.1, localhost or [::1])',
      );
    }
    _baseUrl = _lastBaseUrl = baseUrl;
    _token = token;
  }

  void clearEndpoint() => _baseUrl = null;

  @override
  String get description => Uri.parse(baseUrl).authority;

  @override
  Future<Dashboard> load() async {
    final [status, friends, config] = await Future.wait([
      _getJson('/api/status'),
      _getJson('/api/friends'),
      _getJson('/api/config'),
    ]);
    return dashboardFromApi(
      status: status,
      friends: friends,
      config: config,
      now: _now(),
    );
  }

  @override
  Future<void> setPresenceEnabled(bool enabled) async {
    final res = await _send(
      'PUT',
      '/api/presence',
      body: jsonEncode({'enabled': enabled}),
    );
    _checkStatus(res, '/api/presence');
  }

  @override
  Future<BackendSettings> getSettings() async =>
      settingsFromJson(await _getJson('/api/settings'));

  @override
  Future<BackendSettings> putSettings(BackendSettings settings) async =>
      settingsFromJson(
        await _sendJson('PUT', '/api/settings', settings.toJson()),
      );

  @override
  Future<BackendSettings> rollbackSettings() async =>
      settingsFromJson(await _sendJson('POST', '/api/settings/rollback', {}));

  @override
  Future<void> acknowledgeTerms() async {
    await _sendJson('POST', '/api/ack', {'accepted': true});
  }

  @override
  Future<LoginStart> startLogin(NsoAccount account) async {
    final json = await _sendJson('POST', '/api/login/start', {
      'account': account.name,
    });
    final start = loginStartFromJson(json);
    if (start == null) {
      throw BackendException(S.errorLoginUrlRejected);
    }
    return start;
  }

  @override
  Future<void> completeLogin(NsoAccount account, String redirect) async {
    await _sendJson('POST', '/api/login/complete', {
      'account': account.name,
      'redirect': redirect,
    }, timeout: slowTimeout);
  }

  @override
  Future<void> logout(NsoAccount? account) async {
    await _sendJson('POST', '/api/logout', {'account': account?.name ?? 'all'});
  }

  @override
  Future<DiscordTestResult> testDiscord() async {
    final j = await _sendJson(
      'POST',
      '/api/discord/test',
      {},
      timeout: slowTimeout,
    );
    return DiscordTestResult(
      ok: j['ok'] == true,
      discordRunning: j['discordRunning'] == true,
      error: _str(j['error']) ?? '',
    );
  }

  @override
  Future<DiagnosticsResult> runDiagnostics() async => diagnosticsFromJson(
    await _sendJson('POST', '/api/diagnostics', {}, timeout: slowTimeout),
  );

  @override
  Future<WebServiceList> webServices() async =>
      webServicesFromJson(await _getJson('/api/webservices'));

  @override
  Future<WebServiceSession> openWebService(String id) async =>
      webServiceSessionFromJson(
        await _sendJson(
          'POST',
          '/api/webservices/${Uri.encodeComponent(id)}/open',
          {},
          timeout: slowTimeout,
        ),
      );

  @override
  Future<void> shutdown() async {
    final res = await _send('POST', '/api/shutdown', body: '{}');
    if (res.statusCode != 200 && res.statusCode != 202) {
      _checkStatus(res, '/api/shutdown');
    }
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final res = await _send('GET', path);
    _checkStatus(res, path);
    return _decode(res, path);
  }

  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path,
    Map<String, Object?> body, {
    Duration timeout = timeout,
  }) async {
    final res = await _send(
      method,
      path,
      body: jsonEncode(body),
      timeout: timeout,
    );
    _checkStatus(res, path);
    if (res.bodyBytes.isEmpty) return const {};
    return _decode(res, path);
  }

  static Map<String, dynamic> _decode(http.Response res, String path) {
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw BackendException(
        S.errorUnreadableResponse(path: path),
        statusCode: res.statusCode,
      );
    }
    if (body is! Map<String, dynamic>) {
      throw BackendException(
        S.errorUnexpectedResponse(path: path),
        statusCode: res.statusCode,
      );
    }
    return body;
  }

  Future<http.Response> _send(
    String method,
    String path, {
    String? body,
    Duration timeout = timeout,
  }) async {
    final base = _baseUrl;
    if (base == null) {
      throw BackendException(S.errorReconnecting);
    }
    final token = _token;
    final abort = Completer<void>();
    final timer = Timer(timeout, abort.complete);
    try {
      final req = http.AbortableRequest(
        method,
        Uri.parse('$base$path'),
        abortTrigger: abort.future,
      )..headers.addAll(_headers);
      if (token != null && token.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = body;
      }
      return await http.Response.fromStream(await _client.send(req));
    } on http.RequestAbortedException {
      throw BackendException(
        S.errorBackendNotAnswering(address: Uri.parse(base).authority),
      );
    } on Exception {
      throw BackendException(
        S.errorBackendUnreachable(address: Uri.parse(base).authority),
      );
    } finally {
      timer.cancel();
    }
  }

  static void _checkStatus(http.Response res, String path) {
    final code = res.statusCode;
    if (code >= 200 && code < 300) return;
    final err = errorBodyOf(res.bodyBytes);
    final retry = int.tryParse(res.headers['retry-after']?.trim() ?? '');
    final detail = err.message;
    throw BackendException(
      switch (code) {
        401 || 403 => S.errorHttpForbidden(path: path, code: code),
        429 => S.errorHttpTooMany(path: path),
        _ when detail == null => S.errorHttp(path: path, code: code),
        _ => S.errorHttpDetail(path: path, code: code, detail: detail),
      },
      statusCode: code,
      code: err.code,
      field: err.field,
      retryAfter: retry == null || retry < 0 ? null : Duration(seconds: retry),
    );
  }

  @override
  void close() => _client.close();
}

({String? message, String? code, String? field}) errorBodyOf(List<int> bytes) {
  try {
    final j = jsonDecode(utf8.decode(bytes));
    if (j is Map) {
      final m = _nonEmpty(j['error']);
      return (
        message: m == null || m.length <= 160 ? m : '${m.substring(0, 160)}…',
        code: _nonEmpty(j['code']),
        field: _nonEmpty(j['field']),
      );
    }
  } catch (_) {}
  return (message: null, code: null, field: null);
}

bool isLoopbackApi(Uri? uri) {
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == 'localhost' ||
      host == '::1' ||
      RegExp(r'^127\.\d+\.\d+\.\d+$').hasMatch(host);
}

Dashboard dashboardFromApi({
  required Map<String, dynamic> status,
  required Map<String, dynamic> friends,
  required Map<String, dynamic> config,
  required DateTime now,
}) {
  final cfg = _configFromJson(config);
  final target = _str(config['watchTarget']) ?? '';
  final raw = [for (final f in _list(friends['friends'])) _map(f)];

  // Older backends only have it inside the friend list.
  final watchedField = _map(friends['watched']);
  Map<String, dynamic>? watchedJson = watchedField.isEmpty
      ? null
      : watchedField;
  if (watchedJson == null) {
    for (final f in raw) {
      if (_matches(f, target)) {
        watchedJson = f;
        break;
      }
    }
  }

  final watchable = friends.containsKey('watchable')
      ? [for (final a in _list(friends['watchable'])) _map(a)]
      : raw;

  final observer = _map(status['observer']);
  final tokens = _map(status['tokens']);
  final discord = _map(status['discord']);
  final watch = _map(status['watch']);

  final accounts = [
    for (final f in watchable)
      WatchedAccount(
        name: _str(f['name']) ?? '',
        nsaId: _str(f['nsaId']) ?? '',
      ),
  ];
  WatchedAccount? watched;
  if (watchedJson != null) {
    watched = WatchedAccount(
      name: _str(watchedJson['name']) ?? '',
      nsaId: _str(watchedJson['nsaId']) ?? '',
    );
  } else if (target.isNotEmpty) {
    watched = WatchedAccount(name: S.watchedNotFound, nsaId: target);
    accounts.insert(0, watched);
  }

  return Dashboard(
    friends: [for (final f in raw) friendFromJson(f, now)],
    friendsFromMain: friends['source'] == 'main',
    mainAccountName: _nonEmpty(_map(status['main'])['name']),
    profile: watchedJson == null
        ? null
        : profileFromJson(
            watchedJson,
            now,
            friendCode: _friendCodeOf(watchedJson, _map(status['main'])),
            playLog: [
              for (final g in _list(friends['playLog']))
                recentGameFromJson(_map(g)),
            ],
          ),
    tokens: TokenStatus(
      sessionSaved: tokens['session'] == true,
      accountExpiresIn: _until(tokens['accountExpiresAt'], now),
      coralExpiresIn: _until(tokens['coralExpiresAt'], now),
      zncaValid:
          (_until(tokens['zncaExpiresAt'], now) ?? Duration.zero) >
          Duration.zero,
    ),
    observerConnected: observer['connected'] == true,
    observerName: _nonEmpty(observer['name']) ?? S.settingsObserverTitle,
    discordEnabled: discord['enabled'] == true,
    discordConnected: discord['connected'] == true,
    watchableAccounts: accounts,
    watched: watched,
    config: cfg,
    error: _nonEmpty(watch['error']),
    setup: status.containsKey('setup')
        ? setupFromJson(_map(status['setup']))
        : SetupStatus.legacy,
    coral: coralFromJson(_map(status['coral'])),
    presence: status.containsKey('presence')
        ? livePresenceFromJson(_map(status['presence']))
        : null,
    backendVersion: _nonEmpty(config['version']),
    mainConnected: _map(status['main'])['connected'] == true,
  );
}

SetupStatus setupFromJson(Map<String, dynamic> j) {
  final ack = j['thirdPartyAck'] == true;
  final observer = j['observerLoggedIn'] == true;
  final target = j['targetSet'] == true;
  return SetupStatus(
    thirdPartyAck: ack,
    observerLoggedIn: observer,
    mainLoggedIn: j['mainLoggedIn'] == true,
    targetSet: target,
    complete: j['complete'] is bool
        ? j['complete'] as bool
        : ack && observer && target,
  );
}

CoralStatus coralFromJson(Map<String, dynamic> j) => CoralStatus(
  state: switch (j['state']) {
    'ok' => CoralState.ok,
    'degraded' => CoralState.degraded,
    'down' => CoralState.down,
    _ => CoralState.unknown,
  },
  latencyMs: _int(j['latencyMs']),
  lastSuccess: _time(j['lastSuccess']),
  lastError: _str(j['lastError']) ?? '',
  lastErrorCode: _int(j['lastErrorCode']),
  consecutiveFailures: _int(j['consecutiveFailures']),
  retryAfterSeconds: _int(j['retryAfterSeconds']),
);

LivePresence livePresenceFromJson(Map<String, dynamic> j) {
  final g = _map(j['game']);
  final name = _nonEmpty(g['name']);
  final game = name == null
      ? null
      : LiveGame(
          name: name,
          imageUrl: safeImageUrl(g['imageUri']),
          totalPlayTimeMinutes: _int(g['totalPlayTime']),
          sysDescription: _str(g['sysDescription']) ?? '',
        );
  final state = switch (j['state']) {
    'playing' => game == null ? LiveState.online : LiveState.playing,
    'online' => LiveState.online,
    'idle' => LiveState.idle,
    _ => LiveState.offline,
  };
  final platform = _int(j['platform']);
  return LivePresence(
    state: state,
    game: state == LiveState.playing ? game : null,
    startedAt: state == LiveState.playing ? _fromUnix(j['startedAt']) : null,
    platform: platform == 1 || platform == 2 ? platform : 0,
    discordApp: switch (j['discordApp']) {
      'switch' => 'switch',
      'switch2' => 'switch2',
      _ => 'default',
    },
  );
}

BackendSettings settingsFromJson(Map<String, dynamic> j) {
  const d = BackendSettings();
  int interval(Object? v, int fallback) {
    final n = _num(v)?.toInt();
    return n == null ? fallback : n.clamp(15, 3600);
  }

  return BackendSettings(
    watchTarget: _str(j['watchTarget']) ?? d.watchTarget,
    intervalSeconds: interval(j['intervalSeconds'], d.intervalSeconds),
    idleIntervalSeconds: interval(
      j['idleIntervalSeconds'],
      d.idleIntervalSeconds,
    ),
    friendsIntervalSeconds: interval(
      j['friendsIntervalSeconds'],
      d.friendsIntervalSeconds,
    ),
    showIdle: j['showIdle'] is bool ? j['showIdle'] as bool : d.showIdle,
    discordEnabled: j['discordEnabled'] is bool
        ? j['discordEnabled'] as bool
        : d.discordEnabled,
  );
}

LoginStart? loginStartFromJson(Map<String, dynamic> j) {
  final url = Uri.tryParse(_str(j['url']) ?? '');
  if (url == null ||
      url.scheme != 'https' ||
      url.host.toLowerCase() != 'accounts.nintendo.com') {
    return null;
  }
  final prefix = _nonEmpty(j['redirectPrefix']);
  return LoginStart(
    url: url,
    redirectPrefix: prefix != null && prefix.startsWith('npf')
        ? prefix
        : LoginStart.defaultRedirectPrefix,
  );
}

DiagnosticsResult diagnosticsFromJson(Map<String, dynamic> j) =>
    DiagnosticsResult(
      checks: [
        for (final c in _list(j['checks']))
          if (_str(_map(c)['name']) case final name?)
            DiagnosticCheck(
              name: name,
              ok: _map(c)['ok'] == true,
              latencyMs: _int(_map(c)['latencyMs']),
              detail: _str(_map(c)['detail']) ?? '',
            ),
      ],
      at: _time(j['at']),
    );

Friend friendFromJson(Map<String, dynamic> json, DateTime now) {
  final p = _presence(json);
  final state = _state(p);
  final game = _map(p['game']);
  return Friend(
    name: _str(json['name']) ?? '',
    nsaId: _str(json['nsaId']) ?? '',
    state: state,
    game: _nonEmpty(game['name']),
    gameImageUrl: safeImageUrl(game['imageUri']),
    avatarUrl: safeImageUrl(json['imageUri']),
    lastSeen: state == PresenceState.offline
        ? lastSeenLabel(_num(p['logoutAt']), now)
        : null,
  );
}

Profile profileFromJson(
  Map<String, dynamic> json,
  DateTime now, {
  String? friendCode,
  List<RecentGame> playLog = const [],
}) {
  final p = _presence(json);
  final game = _map(p['game']);
  final playing = _state(p) == PresenceState.playing;
  final name = _str(json['name']) ?? '';
  final since = _fromUnix(p['updatedAt']);
  return Profile(
    name: name,
    avatarInitial: initialOf(name),
    subtitle: profileSubtitle(
      friendCode: friendCode,
      platform: _num(p['platform']),
      nsaId: _str(json['nsaId']),
    ),
    recentGames: playLog,
    currentGame: playing ? _nonEmpty(game['name']) : null,
    currentSessionMinutes: since == null
        ? 0
        : now.difference(since).inMinutes.clamp(0, 1 << 30),
    avatarUrl: safeImageUrl(json['imageUri']),
    gameImageUrl: playing ? safeImageUrl(game['imageUri']) : null,
  );
}

String profileSubtitle({String? friendCode, num? platform, String? nsaId}) {
  final console = platform == 1 || platform == 2
      ? platformName(platform)
      : null;
  final code = friendCode == null || friendCode.isEmpty
      ? null
      : 'SW-$friendCode';
  final parts = [?code, ?console];
  return parts.isEmpty ? S.profileNsaId(id: nsaId ?? '') : parts.join(' | ');
}

String? _friendCodeOf(
  Map<String, dynamic> watched,
  Map<String, dynamic> main,
) => main['nsaId'] != null && main['nsaId'] == watched['nsaId']
    ? _nonEmpty(main['friendCode'])
    : null;

RecentGame recentGameFromJson(Map<String, dynamic> g) {
  final minutes = _num(g['totalPlayTime'])?.toInt() ?? 0;
  final since = _fromUnix(g['firstPlayedAt']);
  return RecentGame(
    name: _str(g['name']) ?? '',
    detail: [
      playTimeShort(minutes),
      if (since != null) S.recentSince(date: monthYear(since)),
    ].join(' · '),
    imageUrl: safeImageUrl(g['imageUri']),
  );
}

String playTimeShort(int minutes) {
  if (minutes < 0) minutes = 0;
  return minutes < 60
      ? S.playTimeMinutes(count: minutes)
      : S.playTimeHours(count: minutes ~/ 60);
}

String monthYear(DateTime d) =>
    S.monthYear(month: t('month.short.${d.month}'), year: d.year);

String platformName(num? platform) =>
    platform == 2 ? 'Nintendo Switch 2' : 'Nintendo Switch';

String lastSeenLabel(num? logoutAt, DateTime now) {
  final at = _fromUnix(logoutAt);
  if (at == null) return S.lastSeenOffline;
  final d = now.difference(at);
  if (d.inMinutes < 1) return S.lastSeenJustNow;
  if (d.inHours < 1) return S.lastSeenMinutes(count: d.inMinutes);
  if (d.inHours < 24) return S.lastSeenHours(count: d.inHours);
  if (d.inHours < 48) return S.lastSeenYesterday;
  return S.lastSeenDays(count: d.inDays);
}

BackendConfig _configFromJson(Map<String, dynamic> c) => BackendConfig(
  discordSwitch2Id: _str(c['discordSwitch2Id']) ?? '',
  discordSwitchId: _str(c['discordSwitchId']) ?? '',
  discordDefaultId: _str(c['discordDefaultId']) ?? '',
  interval: Duration(seconds: _num(c['intervalSeconds'])?.toInt() ?? 15),
  idleInterval: Duration(
    seconds: _num(c['idleIntervalSeconds'])?.toInt() ?? 15,
  ),
  zncaClientId: _str(c['zncaClientId']) ?? '',
  zncaAuthMode: switch (c['zncaAuth']) {
    'client_secret' => ZncaAuthMode.clientSecret,
    'shared_secret' => ZncaAuthMode.sharedSecret,
    _ => ZncaAuthMode.none,
  },
  zncaHasSecret: c['zncaHasSecret'] == true,
  contact: _str(c['contact']) ?? '',
  appVersion: _str(c['appVersion']) ?? '',
);

Map<String, dynamic> _presence(Map<String, dynamic> friend) =>
    _map(friend['presence']);

PresenceState _state(Map<String, dynamic> presence) {
  final game = _map(presence['game']);
  return switch (presence['state']) {
    'ONLINE' ||
    'PLAYING' when _nonEmpty(game['name']) != null => PresenceState.playing,
    'ONLINE' || 'PLAYING' || 'INACTIVE' => PresenceState.online,
    _ => PresenceState.offline,
  };
}

bool _matches(Map<String, dynamic> friend, String target) =>
    target.isNotEmpty &&
    (friend['nsaId'] == target ||
        _str(friend['name'])?.toLowerCase() == target.toLowerCase());

String? safeImageUrl(Object? v) {
  final url = _nonEmpty(v);
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  final host = uri.host.toLowerCase();
  const allowed = ['nintendo.com', 'nintendo.net'];
  final ok = allowed.any((d) => host == d || host.endsWith('.$d'));
  return ok ? url : null;
}

WebServiceList webServicesFromJson(Map<String, dynamic> j) {
  final raw = j['services'];
  final services = <WebServiceInfo>[];
  if (raw is List) {
    for (final e in raw) {
      if (e is! Map) continue;
      final id = _str(e['id']);
      final name = _str(e['name']);
      if (id == null || id.isEmpty || name == null || name.isEmpty) continue;
      services.add(
        WebServiceInfo(
          id: id,
          name: name,
          game: _str(e['game']) ?? '',
          imageUrl: safeImageUrl(e['imageUri']),
          available: e['available'] != false,
          reason: _str(e['reason']) ?? '',
        ),
      );
    }
  }
  return WebServiceList(
    account: _str(j['account']) ?? 'none',
    services: services,
  );
}

WebServiceSession webServiceSessionFromJson(Map<String, dynamic> j) {
  final url = Uri.tryParse(_str(j['url']) ?? '');
  if (url == null || url.scheme != 'https') {
    throw BackendException('bad web service url');
  }

  final query = <String, String>{...url.queryParameters};
  final q = j['query'];
  if (q is Map) {
    q.forEach((k, v) {
      if (k is String && v != null) query[k] = '$v';
    });
  }

  final cookies = <WebServiceCookie>[];
  final c = j['cookies'];
  if (c is List) {
    for (final e in c) {
      if (e is! Map) continue;
      final name = _str(e['name']);
      final value = _str(e['value']);
      if (name == null || name.isEmpty || value == null) continue;
      cookies.add(
        WebServiceCookie(
          name: name,
          value: value,
          domain: _str(e['domain']) ?? '',
        ),
      );
    }
  }

  final headers = <String, String>{};
  final h = j['headers'];
  if (h is Map) {
    h.forEach((k, v) {
      if (k is String && v is String) headers[k] = v;
    });
  }

  return WebServiceSession(
    url: query.isEmpty ? url : url.replace(queryParameters: query),
    userAgent: _str(j['userAgent']) ?? '',
    cookies: cookies,
    headers: headers,
  );
}
