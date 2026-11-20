import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';

import '../i18n/i18n.dart';
import '../models/models.dart';

typedef WebServiceOpener =
    Future<void> Function(WebServiceInfo service, WebServiceSession session);

// desktop_webview_window can't set cookies or headers on the first request,
// so the token cookie is written from a document-start script, then the page
// reloads once with it.
String cookieScript(List<WebServiceCookie> cookies) {
  final list = jsonEncode([
    for (final c in cookies)
      {'name': c.name, 'value': c.value, 'domain': c.domain},
  ]);

  return '''
(function () {
  var cookies = $list;
  var host = location.hostname;
  var changed = false;
  cookies.forEach(function (c) {
    var domain = (c.domain || '').replace(/^\\./, '');
    if (domain && host !== domain && !host.endsWith('.' + domain)) return;
    var pair = c.name + '=' + c.value;
    if (document.cookie.split('; ').indexOf(pair) !== -1) return;
    document.cookie = pair + '; path=/; secure' + (c.domain ? '; domain=' + c.domain : '');
    changed = true;
  });
  if (changed && !sessionStorage.getItem('nsonline-cookie-reload')) {
    sessionStorage.setItem('nsonline-cookie-reload', '1');
    location.reload();
  }
})();
''';
}

Future<void> Function(WebServiceInfo, WebServiceSession) webServiceOpener({
  String? dataDir,
}) {
  return (service, session) async {
    if (!await WebviewWindow.isWebviewAvailable()) {
      throw StateError(S.homeServicesWebviewUnavailable);
    }

    final sep = Platform.pathSeparator;
    final webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        windowWidth: 480,
        windowHeight: 860,
        title: service.name,
        titleBar: const TitleBarOptions(showNavigation: true),
        windows: WindowsWebviewOptions(
          userDataFolder: dataDir == null
              ? 'webview_window_WebView2'
              : '$dataDir${sep}WebView2',
        ),
      ),
    );

    if (session.userAgent.isNotEmpty) {
      await webview.setApplicationNameForUserAgent(' ${session.userAgent}');
    }
    if (session.cookies.isNotEmpty) {
      await webview.addScriptToExecuteOnDocumentCreated(
        cookieScript(session.cookies),
      );
    }
    await webview.setOnUrlRequestCallback((u) {
      final scheme = Uri.tryParse(u)?.scheme.toLowerCase() ?? '';
      return scheme == 'https' || scheme == 'about';
    });
    await webview.launch(session.url.toString());
  };
}
