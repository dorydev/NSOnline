import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../diagnostics/app_logger.dart';
import '../i18n/i18n.dart';
import '../services/web_service_window.dart';
import '../state/app_state.dart';
import '../storage/local_prefs.dart';
import '../widgets/common.dart';
import 'tray_menu.dart';

Future<void> _notify(String title, String body) async {
  try {
    await LocalNotification(title: title, body: body).show();
  } catch (_) {}
}

class DesktopShell with TrayListener, WindowListener {
  DesktopShell({
    required this.state,
    required this.prefs,
    required this.navigatorKey,
    required this.quit,
    this.openWebService,
  });

  final AppState state;
  final PrefsStore prefs;
  final GlobalKey<NavigatorState> navigatorKey;
  final Future<void> Function() quit;
  final WebServiceOpener? openWebService;

  bool _hasTray = false;
  List<TrayEntry> _shown = const [];
  Timer? _clock;

  static String get _iconPath =>
      Platform.isWindows ? 'assets/icon.ico' : 'assets/icon_512.png';

  Future<void> init() async {
    windowManager.addListener(this);
    trayManager.addListener(this);
    await windowManager.setPreventClose(true);
    try {
      await trayManager.setIcon(_iconPath);
      if (!Platform.isLinux) await trayManager.setToolTip(S.trayTooltip);
      _hasTray = true;
      await _updateMenu();
      state.addListener(_onState);
      appLocale.addListener(_onState);
      _clock = Timer.periodic(const Duration(seconds: 30), (_) => _onState());
    } catch (e) {
      // No tray (Linux without AppIndicator): closing quits for real.
      AppLogger.instance.warn('tray icon unavailable', e);
      await windowManager.setPreventClose(false);
    }
  }

  void _onState() => unawaited(_updateMenu());

  Future<void> _updateMenu() async {
    if (!_hasTray) return;
    final entries = trayMenuEntries(state);
    if (listEquals(entries, _shown)) return;
    _shown = entries;
    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            for (final e in entries)
              if (e.separator)
                MenuItem.separator()
              else if (e.checked != null)
                MenuItem.checkbox(
                  key: e.key,
                  label: e.label,
                  checked: e.checked,
                )
              else
                MenuItem(key: e.key, label: e.label, disabled: e.key == null),
          ],
        ),
      );
    } catch (e) {
      AppLogger.instance.warn('tray menu update failed', e);
    }
  }

  @override
  void onTrayIconMouseDown() => unawaited(_popUp());

  @override
  void onTrayIconRightMouseDown() => unawaited(_popUp());

  Future<void> _popUp() async {
    await _updateMenu();
    unawaited(state.refresh());
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final serviceId = webServiceIdOf(menuItem.key);
    if (serviceId != null) {
      unawaited(_openWebService(serviceId));
      return;
    }
    switch (menuItem.key) {
      case TrayAction.presence:
        unawaited(state.setPresenceEnabled(!state.presenceEnabled));
      case TrayAction.open:
        unawaited(openMain());
      case TrayAction.logout:
        unawaited(_logout());
      case TrayAction.quit:
        unawaited(quit());
    }
  }

  Future<void> _openWebService(String id) async {
    final service = state.webServices.services
        .where((s) => s.id == id)
        .firstOrNull;
    final open = openWebService;
    if (service == null || open == null) return;

    final session = await state.openWebService(service);
    try {
      if (session != null) {
        await open(service, session);
        return;
      }
    } catch (e) {
      state.webServiceError = S.homeServicesFailed(
        name: service.name,
        error: e,
      );
    }

    final error = state.webServiceError;
    if (error != null) await _notify(service.name, error);
  }

  Future<void> _logout() async {
    await openMain();
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;

    final ok = await confirmDialog(
      ctx,
      title: S.logoutTitle,
      message: S.logoutMessage,
      confirmLabel: S.logoutConfirm,
      destructive: true,
    );
    if (!ok) return;

    try {
      await state.logout(null);
      navigatorKey.currentState?.popUntil((r) => r.isFirst);
    } catch (e) {
      AppLogger.instance.warn('logout failed', e);
    }
  }

  @override
  void onWindowClose() => unawaited(_hideToTray());

  Future<void> _hideToTray() async {
    await windowManager.hide();
    if (prefs.read().trayNoticeShown) return;

    prefs.update((p) => p.copyWith(trayNoticeShown: true));
    await _notify(
      S.notifyBackgroundTitle,
      S.notifyBackgroundBody(quit: S.trayQuit),
    );
  }

  Future<void> openMain() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> dispose() async {
    _clock?.cancel();
    state.removeListener(_onState);
    appLocale.removeListener(_onState);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {}
  }
}
