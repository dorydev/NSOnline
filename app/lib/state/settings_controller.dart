import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/http_repository.dart' show settingsFromJson;
import '../data/repository.dart';
import '../i18n/i18n.dart';
import '../models/models.dart';
import '../storage/json_store.dart';

@immutable
class SettingsValues {
  const SettingsValues({
    required this.backend,
    this.launchAtLogin = false,
    this.startMinimized = false,
  });

  final BackendSettings backend;
  final bool launchAtLogin;
  final bool startMinimized;

  SettingsValues copyWith({
    BackendSettings? backend,
    bool? launchAtLogin,
    bool? startMinimized,
  }) => SettingsValues(
    backend: backend ?? this.backend,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    startMinimized: startMinimized ?? this.startMinimized,
  );

  Map<String, Object> toJson() => {
    'backend': backend.toJson(),
    'launchAtLogin': launchAtLogin,
    'startMinimized': startMinimized,
  };

  static SettingsValues? fromJson(Object? j) {
    if (j is! Map) return null;
    final b = j['backend'];
    if (b is! Map) return null;
    return SettingsValues(
      backend: settingsFromJson(b.cast<String, dynamic>()),
      launchAtLogin: j['launchAtLogin'] == true,
      startMinimized: j['startMinimized'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SettingsValues &&
      other.backend == backend &&
      other.launchAtLogin == launchAtLogin &&
      other.startMinimized == startMinimized;

  @override
  int get hashCode => Object.hash(backend, launchAtLogin, startMinimized);
}

class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.api,
    required this.store,
    required this.readLocal,
    required this.applyLocal,
    this.fallback,
    DateTime Function()? now,
    this.rollbackWindow = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now;

  final BackendApi? api;

  final JsonFileStore store;

  final ({bool launchAtLogin, bool startMinimized}) Function() readLocal;

  final Future<void> Function({
    required bool launchAtLogin,
    required bool startMinimized,
  })
  applyLocal;

  final BackendSettings Function()? fallback;
  final Duration rollbackWindow;
  final DateTime Function() _now;

  SettingsValues? saved;
  SettingsValues? draft;

  SettingsValues? restorable;

  bool loading = false;
  bool saving = false;
  bool rollingBack = false;

  bool backendSupportsSettings = true;
  String? error;

  String? errorField;

  DateTime? lastSaveAt;
  bool saveFailed = false;
  bool _connectionLostAfterSave = false;
  SettingsValues? _previous;
  bool _disposed = false;
  Future<void>? _loading;

  bool get dirty => draft != null && saved != null && draft != saved;

  bool get offerRollback =>
      backendSupportsSettings &&
      (saveFailed || _connectionLostAfterSave) &&
      lastSaveAt != null;

  Future<void> load() =>
      _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    // Callers may be building widgets: notify only after the current frame.
    await Future<void>.microtask(() {});
    loading = true;
    _notify();
    final local = readLocal();
    BackendSettings backend;
    try {
      final a = api;
      if (a == null) throw BackendException('no backend', statusCode: 404);
      backend = await a.getSettings();
      backendSupportsSettings = true;
      error = null;
    } on BackendException catch (e) {
      backend = fallback?.call() ?? const BackendSettings();
      if (e.statusCode == 404) {
        backendSupportsSettings = false;
        error = null;
      } else {
        error = S.errorSettingsNotLoaded(error: e.message);
      }
    }
    final next = SettingsValues(
      backend: backend,
      launchAtLogin: local.launchAtLogin,
      startMinimized: local.startMinimized,
    );
    saved = next;
    if (draft == null || !dirty) draft = next;
    _checkStored(next);
    loading = false;
    _notify();
  }

  void _checkStored(SettingsValues current) {
    final stored = store.read();
    final d = SettingsValues.fromJson(stored?['draft']);
    if (d != null && d != current && restorable == null && !dirty) {
      restorable = d;
    } else if (d == null || d == current) {
      store.delete();
    }
  }

  void edit(SettingsValues Function(SettingsValues current) change) {
    final base = draft ?? saved;
    if (base == null) return;
    draft = change(base);
    error = null;
    errorField = null;
    _persist();
    _notify();
  }

  void editBackend(BackendSettings Function(BackendSettings b) change) =>
      edit((v) => v.copyWith(backend: change(v.backend)));

  void _persist() {
    try {
      if (dirty) {
        store.write({
          'version': 1,
          'at': _now().toUtc().toIso8601String(),
          'base': saved!.toJson(),
          'draft': draft!.toJson(),
        });
      } else {
        store.delete();
      }
    } catch (_) {}
  }

  Future<bool> save() async {
    final d = draft;
    final s = saved;
    if (d == null || s == null || saving) return false;
    saving = true;
    error = null;
    errorField = null;
    _notify();
    try {
      var backend = d.backend;
      if (d.backend != s.backend) {
        final a = api;
        if (a == null || !backendSupportsSettings) {
          throw BackendException(S.errorSettingsReadOnly);
        }
        _previous = s;
        lastSaveAt = _now();
        _connectionLostAfterSave = false;
        backend = await a.putSettings(d.backend);
      }
      if (d.launchAtLogin != s.launchAtLogin ||
          d.startMinimized != s.startMinimized) {
        await applyLocal(
          launchAtLogin: d.launchAtLogin,
          startMinimized: d.startMinimized,
        );
      }
      final next = d.copyWith(backend: backend);
      saved = next;
      draft = next;
      saveFailed = false;
      store.delete();
      return true;
    } on BackendException catch (e) {
      saveFailed = d.backend != s.backend && backendSupportsSettings;
      errorField = e.field;
      error = S.errorSaveFailed(error: e.message);
      return false;
    } catch (e) {
      error = S.errorSaveFailed(error: e);
      return false;
    } finally {
      saving = false;
      _notify();
    }
  }

  void cancel() {
    draft = saved;
    error = null;
    errorField = null;
    store.delete();
    _notify();
  }

  void connectionLost() {
    final at = lastSaveAt;
    if (at != null && _now().difference(at) <= rollbackWindow) {
      _connectionLostAfterSave = true;
      _notify();
    }
  }

  Future<bool> rollback() async {
    final a = api;
    if (a == null || rollingBack) return false;
    rollingBack = true;
    _notify();
    try {
      final backend = await a.rollbackSettings();
      final prev = _previous ?? saved;
      final next = (prev ?? SettingsValues(backend: backend)).copyWith(
        backend: backend,
      );
      if (prev != null &&
          (prev.launchAtLogin != saved?.launchAtLogin ||
              prev.startMinimized != saved?.startMinimized)) {
        await applyLocal(
          launchAtLogin: prev.launchAtLogin,
          startMinimized: prev.startMinimized,
        );
      }
      saved = next;
      draft = next;
      saveFailed = false;
      _connectionLostAfterSave = false;
      lastSaveAt = null;
      error = null;
      store.delete();
      return true;
    } on BackendException catch (e) {
      error = S.errorRollbackFailed(error: e.message);
      return false;
    } finally {
      rollingBack = false;
      _notify();
    }
  }

  void restore() {
    final r = restorable;
    restorable = null;
    if (r == null) return;
    draft = r;
    _persist();
    _notify();
  }

  void discardRestore() {
    restorable = null;
    store.delete();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
