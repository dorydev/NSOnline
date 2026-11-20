abstract final class AppLinks {
  static final repositoryUrl = Uri.parse('https://github.com/dorydev/NSOnline');
}

const appVersion = '0.1.0';

// Game web services (SplatNet 3, NookLink, Smash World) are off in 0.1.0:
// the WebView can't send X-GameWebToken on the first request, and the pages
// stay on their loader. Build with --dart-define=NSONLINE_WEB_SERVICES=true.
const webServicesEnabled = bool.fromEnvironment('NSONLINE_WEB_SERVICES');
