import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../i18n/i18n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'auth_browser.dart';

enum SetupStep { terms, observer, main, target, discord, preferences }

class SetupController extends ChangeNotifier {
  SetupController({
    required this.state,
    required this.browser,
    required this.openExternal,
  }) {
    step = _firstIncomplete();
  }

  final AppState state;
  final AuthBrowser browser;

  final Future<bool> Function(Uri url) openExternal;

  late SetupStep step;
  bool busy = false;
  String? error;
  String? info;

  NsoAccount? pasteFor;
  final _pending = <NsoAccount, LoginStart>{};

  bool launchAtLogin = false;
  bool startMinimized = false;
  bool _disposed = false;

  SetupStep _firstIncomplete() {
    final s = state.setup;
    if (!s.thirdPartyAck) return SetupStep.terms;
    if (!s.observerLoggedIn) return SetupStep.observer;
    if (!s.targetSet) return SetupStep.target;
    return SetupStep.discord;
  }

  bool isDone(SetupStep s) => switch (s) {
    SetupStep.terms => state.setup.thirdPartyAck,
    SetupStep.observer => state.setup.observerLoggedIn,
    SetupStep.main => state.setup.mainLoggedIn,
    SetupStep.target => state.setup.targetSet,
    SetupStep.discord => state.discordTest?.ok == true,
    SetupStep.preferences => false,
  };

  void goTo(SetupStep s) {
    step = s;
    error = null;
    info = null;
    pasteFor = null;
    _notify();
  }

  void next() {
    if (step.index < SetupStep.values.length - 1) {
      goTo(SetupStep.values[step.index + 1]);
    }
  }

  void back() {
    if (step.index > 0) goTo(SetupStep.values[step.index - 1]);
  }

  Future<void> acceptTerms() => _run(() async {
    await state.acknowledgeTerms();
    next();
  });

  Future<void> login(NsoAccount account) => _run(() async {
    final start = await state.startLogin(account);
    _pending[account] = start;
    String? redirect;
    try {
      redirect = await browser.capture(start.url, start.redirectPrefix);
    } catch (_) {
      await _fallback(account, start);
      return;
    }
    if (redirect == null) {
      info = S.setupInfoCancelled;
      return;
    }
    await _complete(account, redirect);
  });

  Future<void> loginInSystemBrowser(NsoAccount account) => _run(() async {
    final start = await state.startLogin(account);
    _pending[account] = start;
    await _fallback(account, start);
  });

  Future<void> _fallback(NsoAccount account, LoginStart start) async {
    pasteFor = account;
    final opened = await openExternal(start.url);
    info = opened
        ? S.setupInfoPasteLink
        : S.setupInfoBrowserFailed(url: start.url);
  }

  Future<void> submitPasted(NsoAccount account, String link) => _run(() async {
    final prefix =
        _pending[account]?.redirectPrefix ?? LoginStart.defaultRedirectPrefix;
    if (!isLoginRedirect(link, prefix)) {
      error = S.setupErrorWrongLink(prefix: prefix);
      return;
    }
    await _complete(account, link.trim());
  });

  Future<void> _complete(NsoAccount account, String redirect) async {
    await state.completeLogin(account, redirect);
    pasteFor = null;
    info = null;
    next();
  }

  Future<void> chooseTarget(WatchedAccount account) => _run(() async {
    await state.setWatchTarget(account.nsaId);
    next();
  });

  Future<void> testDiscord() => _run(() async {
    final r = await state.testDiscord();
    if (r == null || !r.ok) {
      error = r == null
          ? S.setupErrorTestImpossible
          : !r.discordRunning
          ? S.setupErrorDiscordNotRunning
          : r.error.isEmpty
          ? S.setupErrorDiscordRefused
          : S.setupErrorDiscordRefusedWith(error: r.error);
    } else {
      info = S.setupInfoTestSent(activity: S.discordTestDetails);
    }
  });

  void setPreferences({bool? launchAtLogin, bool? startMinimized}) {
    this.launchAtLogin = launchAtLogin ?? this.launchAtLogin;
    this.startMinimized = startMinimized ?? this.startMinimized;
    _notify();
  }

  Future<void> finish() => _run(() async {
    final s = state.setup;
    if (s.known && !s.complete) {
      error = [
        if (!s.thirdPartyAck) S.setupRemainingTerms,
        if (!s.observerLoggedIn) S.setupRemainingObserver,
        if (!s.targetSet) S.setupRemainingTarget,
      ].join(', ');
      error = S.setupRemainingMessage(steps: error!);
      return;
    }
    await state.settings.applyLocal(
      launchAtLogin: launchAtLogin,
      startMinimized: startMinimized,
    );
    state.finishSetup();
  });

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } on BackendException catch (e) {
      error = switch (e.code) {
        'login_expired' => S.setupErrorLinkExpired,
        'invalid_redirect' => S.setupErrorInvalidRedirect,
        _ => e.message,
      };
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      _notify();
    }
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
