import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_services.dart';
import 'data/http_repository.dart';
import 'data/mock_data.dart';
import 'data/repository.dart';
import 'i18n/i18n.dart';
import 'i18n/locale_rebuilder.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/setup_screen.dart';
import 'state/app_state.dart';
import 'state/app_state_scope.dart';
import 'theme/app_theme.dart';
import 'widgets/boot_splash.dart';
import 'widgets/common.dart';

NsoRepository defaultRepository() {
  const mock = bool.fromEnvironment('NSO_MOCK');
  if (mock || kIsWeb) return const MockRepository();
  return HttpRepository(
    baseUrl: const String.fromEnvironment(
      'NSO_API',
      defaultValue: 'http://127.0.0.1:7878',
    ),
  );
}

class NsoRpcApp extends StatefulWidget {
  const NsoRpcApp({
    super.key,
    this.state,
    this.services,
    this.splash,
    this.navigatorKey,
  });

  final AppState? state;
  final AppServices? services;

  final bool? splash;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<NsoRpcApp> createState() => _NsoRpcAppState();
}

class _NsoRpcAppState extends State<NsoRpcApp> {
  late final AppState _state =
      widget.state ?? (AppState(defaultRepository())..startAutoRefresh());
  late final AppServices _services = widget.services ?? AppServices();
  late final _navigatorKey = widget.navigatorKey ?? GlobalKey<NavigatorState>();
  late bool _splash = widget.splash ?? widget.state == null;

  @override
  void dispose() {
    if (widget.state == null) _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LocaleRebuilder(
      child: AppServicesScope(
        services: _services,
        child: AppStateScope(
          state: _state,
          child: MaterialApp(
            title: S.appName,
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            navigatorKey: _navigatorKey,
            builder: (context, child) =>
                // Painted background: mid-crossfade the bare window showed through.
                ColoredBox(
                  color: AppColors.background,
                  child: AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.screen),
                    transitionBuilder: fadeSlideTransition,
                    child: _splash
                        ? BootSplash(
                            key: const ValueKey('splash'),
                            onDone: () => setState(() => _splash = false),
                          )
                        : KeyedSubtree(
                            key: const ValueKey('app'),
                            child: child!,
                          ),
                  ),
                ),
            home: const _Root(),
          ),
        ),
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _settingsLoaded = false;
  bool _askedRestore = false;
  bool? _wasSetup;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final setup = state.needsSetup;
    if (_wasSetup != setup) {
      if (setup && _wasSetup == false) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        });
      }
      _wasSetup = setup;
    }
    if (!setup && state.lastUpdated != null && !_settingsLoaded) {
      _settingsLoaded = true;
      state.settings.load().then((_) => _maybeRestore(state));
    }
    // Wait for the first answer, or Home then Setup plays two transitions.
    final undecided =
        state.lastUpdated == null &&
        (state.connection == ConnectionStatus.connecting ||
            (state.supervisor != null &&
                state.loading &&
                state.backendError == null));
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.screen),
      transitionBuilder: fadeSlideTransition,
      child: undecided
          ? const ColoredBox(
              key: ValueKey('loading'),
              color: AppColors.background,
              child: SizedBox.expand(),
            )
          : setup
          ? const SetupScreen(key: ValueKey('setup'))
          : const HomeScreen(key: ValueKey('home')),
    );
  }

  Future<void> _maybeRestore(AppState state) async {
    if (!mounted || _askedRestore || state.settings.restorable == null) return;
    _askedRestore = true;
    final restore = await confirmDialog(
      context,
      title: S.restoreTitle,
      message: S.restoreMessage,
      confirmLabel: S.restoreConfirm,
      cancelLabel: S.restoreIgnore,
    );
    if (!mounted) return;
    if (restore) {
      state.settings.restore();
      await openSettings(context);
    } else {
      state.settings.discardRestore();
    }
  }
}
