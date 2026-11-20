import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'i18n/i18n.dart';
import 'services/web_service_window.dart';
import 'setup/auth_browser.dart';
import 'update/update_controller.dart';

Future<bool> openExternalUrl(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

class AppServices {
  AppServices({
    this.updates,
    AuthBrowser? browser,
    this.openUrl = openExternalUrl,
    this.quit,
    this.reportIssue,
    this.openMainWindow,
    this.openWebService,
    this.version = appVersion,
  }) : browser = browser ?? _NoBrowser();

  final UpdateController? updates;
  final AuthBrowser browser;
  final Future<bool> Function(Uri url) openUrl;

  final Future<void> Function()? quit;

  final Future<void> Function()? reportIssue;

  final WebServiceOpener? openWebService;

  final Future<void> Function()? openMainWindow;
  final String version;
}

class AppServicesScope extends InheritedWidget {
  const AppServicesScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppServicesScope>()
          ?.services ??
      _fallback;

  static final _fallback = AppServices();

  @override
  bool updateShouldNotify(AppServicesScope old) => old.services != services;
}

class _NoBrowser implements AuthBrowser {
  @override
  Future<String?> capture(Uri url, String redirectPrefix) =>
      throw StateError(S.errorNoBrowser);
}
