import '../models/models.dart';

abstract interface class NsoRepository {
  String get description;

  Future<Dashboard> load();

  Future<void> setPresenceEnabled(bool enabled);

  void close();
}

abstract interface class BackendApi {
  Future<BackendSettings> getSettings();
  Future<BackendSettings> putSettings(BackendSettings settings);
  Future<BackendSettings> rollbackSettings();

  Future<void> acknowledgeTerms();
  Future<LoginStart> startLogin(NsoAccount account);

  Future<void> completeLogin(NsoAccount account, String redirect);

  Future<void> logout(NsoAccount? account);
  Future<DiscordTestResult> testDiscord();
  Future<DiagnosticsResult> runDiagnostics();
  Future<WebServiceList> webServices();
  Future<WebServiceSession> openWebService(String id);
  Future<void> shutdown();
}

class BackendException implements Exception {
  BackendException(
    this.message, {
    this.statusCode,
    this.code,
    this.field,
    this.retryAfter,
  });

  final String message;

  final int? statusCode;

  final String? code;

  final String? field;

  final Duration? retryAfter;

  bool get isConnectionError => statusCode == null;
  bool get isUnauthorized => statusCode == 401 || statusCode == 403;
  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => message;
}
