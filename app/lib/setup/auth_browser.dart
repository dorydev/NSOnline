import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';

import '../i18n/i18n.dart';

abstract interface class AuthBrowser {
  Future<String?> capture(Uri url, String redirectPrefix);
}

bool isLoginRedirect(String link, String redirectPrefix) {
  final t = link.trim();
  return t.toLowerCase().startsWith(redirectPrefix.toLowerCase()) &&
      t.contains('session_token_code=');
}

class WebviewAuthBrowser implements AuthBrowser {
  WebviewAuthBrowser({this.dataDir});

  final String? dataDir;

  @override
  Future<String?> capture(Uri url, String redirectPrefix) async {
    if (!await WebviewWindow.isWebviewAvailable()) {
      throw StateError(S.authWebviewUnavailable);
    }
    final sep = Platform.pathSeparator;
    final webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        windowWidth: 520,
        windowHeight: 760,
        title: S.authWindowTitle,
        titleBar: const TitleBarOptions(showNavigation: false),
        windows: WindowsWebviewOptions(
          userDataFolder: dataDir == null
              ? 'webview_window_WebView2'
              : '$dataDir${sep}WebView2',
        ),
      ),
    );
    final done = Completer<String?>();
    await webview.setOnUrlRequestCallback((u) {
      if (isLoginRedirect(u, redirectPrefix) ||
          u.toLowerCase().startsWith(redirectPrefix.toLowerCase())) {
        if (!done.isCompleted) done.complete(u);
        scheduleMicrotask(() => webview.close().catchError((_) {}));
        return false;
      }
      // Web pages only: other custom schemes are never handed to the OS.
      final scheme = Uri.tryParse(u)?.scheme.toLowerCase() ?? '';
      return scheme == 'https' || scheme == 'about';
    });
    unawaited(
      webview.onClose.then((_) {
        if (!done.isCompleted) done.complete(null);
      }),
    );
    await webview.launch(url.toString());
    return done.future;
  }
}
