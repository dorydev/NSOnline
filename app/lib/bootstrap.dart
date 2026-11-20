import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_services.dart';
import 'backend/backend_supervisor.dart';
import 'config.dart';
import 'data/http_repository.dart';
import 'data/mock_data.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/popover_geometry.dart';
import 'desktop/startup.dart';
import 'diagnostics/app_logger.dart';
import 'diagnostics/issue_report.dart';
import 'diagnostics/report_issue.dart';
import 'i18n/i18n.dart';
import 'services/web_service_window.dart';
import 'setup/auth_browser.dart';
import 'state/app_state.dart';
import 'storage/json_store.dart';
import 'storage/legacy_data.dart';
import 'storage/local_prefs.dart';
import 'update/release.dart';
import 'update/update_controller.dart';
import 'update/update_service.dart';

class Boot {
  Boot({required this.state, required this.services, this.navigatorKey});

  final AppState state;
  final AppServices services;
  final GlobalKey<NavigatorState>? navigatorKey;
}

void installErrorHandlers(AppLogger log) {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    log.error(
      'Flutter error: ${details.exceptionAsString()}',
      null,
      details.stack,
    );
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.error('Uncaught error', error, stack);
    return true;
  };
}

Future<Boot> bootstrap(List<String> args) async {
  const mock = bool.fromEnvironment('NSO_MOCK');
  if (kIsWeb || mock) {
    return Boot(
      state: AppState(const MockRepository())..startAutoRefresh(),
      services: AppServices(),
    );
  }

  final dataDir = (await getApplicationSupportDirectory()).path;
  final sep = Platform.pathSeparator;
  final migrated = legacyDataDirs(
    dataDir,
    Platform.operatingSystem,
  ).any((old) => migrateLegacyData(dataDir, old));
  final log = AppLogger(File('$dataDir${sep}logs${sep}app.log'));
  AppLogger.instance = log;
  installErrorHandlers(log);
  if (migrated) log.info('data copied from an older data folder');
  log.info(
    'NSOnline $appVersion · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );

  final prefs = PrefsStore(JsonFileStore(File('$dataDir${sep}app_prefs.json')));
  // Set before the backend starts: it inherits NSONLINE_LANG.
  setLocale(prefs.read().language);
  final env = Platform.environment;
  const definedApi = String.fromEnvironment('NSO_API');
  final devApi = env['NSO_API'] ?? (definedApi.isEmpty ? null : definedApi);

  late final HttpRepository repo;
  BackendSupervisor? supervisor;
  String? missingBackend;
  if (devApi != null) {
    repo = HttpRepository(baseUrl: devApi, token: env['NSONLINE_API_TOKEN']);
    log.info('NSO_API mode: $devApi');
  } else {
    repo = HttpRepository(connected: false);
    final exe = resolveBackendExecutable(
      env: env,
      resolvedExecutable: Platform.resolvedExecutable,
      isWindows: Platform.isWindows,
      exists: (p) => File(p).existsSync(),
      currentDir: Directory.current.path,
    );
    if (exe == null) {
      missingBackend = S.errorBackendMissing;
      log.error(
        'backend executable not found (next to the app or NSO_BACKEND_PATH)',
      );
    } else {
      supervisor = BackendSupervisor(
        executable: exe,
        dataDir: dataDir,
        requestShutdown: (_) => repo.shutdown(),
        logger: log,
      );
      // Must run before AppState's listener.
      supervisor.addListener(() {
        final ep = supervisor!.endpoint;
        if (ep != null) {
          repo.setEndpoint(ep.baseUrl, token: ep.token);
        } else {
          repo.clearEndpoint();
        }
      });
    }
  }

  final startup = StartupLauncher();
  final state = AppState(
    repo,
    prefs: prefs,
    supervisor: supervisor,
    embedded: devApi == null,
    draftStore: JsonFileStore(File('$dataDir${sep}settings_draft.json')),
    applyStartup: ({required launchAtLogin, required startMinimized}) async {
      await startup.apply(launchAtLogin);
      prefs.update(
        (p) => p.copyWith(
          launchAtLogin: launchAtLogin,
          startMinimized: startMinimized,
        ),
      );
    },
  );
  if (missingBackend != null) {
    state
      ..connection = ConnectionStatus.failed
      ..backendError = missingBackend;
  }

  await windowManager.ensureInitialized();
  try {
    await localNotifier.setup(appName: S.appName);
  } catch (_) {}
  final navigatorKey = GlobalKey<NavigatorState>();
  UpdateController? updates;
  DesktopShell? shell;

  var stopped = false;
  Future<void> stopEverything() async {
    if (stopped) return;
    stopped = true;
    log.info('NSOnline stopping');
    updates?.dispose();
    await supervisor?.stop();
    await shell?.dispose();
  }

  Future<void> quit() async {
    await stopEverything();
    exit(0);
  }

  AppLifecycleListener(
    onExitRequested: () async {
      await stopEverything();
      return AppExitResponse.exit;
    },
  );

  shell = DesktopShell(
    state: state,
    prefs: prefs,
    navigatorKey: navigatorKey,
    quit: quit,
    openWebService: webServiceOpener(dataDir: dataDir),
  );
  await shell.init();

  final install = detectInstallType(
    os: Platform.operatingSystem,
    resolvedExecutable: Platform.resolvedExecutable,
    env: env,
    exists: (p) => File(p).existsSync(),
  );
  updates = UpdateController(
    currentVersion: appVersion,
    service: UpdateService(
      tempDir: () => Directory.systemTemp.createTemp('nsonline-update-'),
      pid: pid,
    ),
    os: Platform.operatingSystem,
    arch: archFromVersionString(Platform.version),
    install: install,
    quit: quit,
  );

  final services = AppServices(
    updates: updates,
    browser: WebviewAuthBrowser(dataDir: dataDir),
    quit: quit,
    openMainWindow: shell.openMain,
    openWebService: webServiceOpener(dataDir: dataDir),
    reportIssue: () async {
      final url = buildIssueUrl(
        issueReportFor(state, appVersion: appVersion, dataDir: dataDir),
      );
      log.info('issue report opened (${url.toString().length} chars)');
      if (!await openExternalUrl(url)) {
        throw StateError(S.errorNoBrowserToOpen);
      }
    },
  );

  final minimized = args.contains('--minimized') || prefs.read().startMinimized;
  unawaited(
    windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: normalSize,
        minimumSize: normalMinSize,
        center: true,
        title: S.appName,
        backgroundColor: Color(0xFF1B1C1F),
      ),
      () async {
        if (!minimized) {
          await windowManager.show();
          await windowManager.focus();
        }
      },
    ),
  );

  unawaited(supervisor?.start());
  state.startAutoRefresh();
  updates.start();
  return Boot(state: state, services: services, navigatorKey: navigatorKey);
}
