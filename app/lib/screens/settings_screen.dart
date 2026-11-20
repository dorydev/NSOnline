import 'package:flutter/material.dart';

import '../app_services.dart';
import '../i18n/i18n.dart';
import '../models/models.dart';
import '../setup/setup_controller.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../state/settings_controller.dart';
import '../theme/app_theme.dart';
import '../update/update_controller.dart';
import '../widgets/common.dart';
import '../widgets/settings_widgets.dart';
import '../widgets/update_popover.dart';
import 'setup_screen.dart';

String _shortDuration(Duration d) => d.inSeconds < 60
    ? S.settingsShortSeconds(count: d.inSeconds)
    : S.settingsShortMinutes(count: d.inMinutes);

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

Future<void> _connect(BuildContext context, SetupStep step) =>
    Navigator.of(context).push(fadeSlideRoute((_) => SetupScreen(only: step)));

Future<void> _disconnect(
  BuildContext context,
  AppState state,
  NsoAccount account,
) async {
  final ok = await confirmDialog(
    context,
    title: S.settingsLogoutTitle,
    message: account == NsoAccount.observer
        ? S.settingsLogoutObserverMessage
        : S.settingsLogoutMainMessage,
    confirmLabel: S.settingsLogoutConfirm,
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  try {
    await state.logout(account);
  } catch (e) {
    if (context.mounted) _snack(context, S.settingsLogoutFailed(error: e));
  }
}

Future<void> openSettings(BuildContext context) =>
    Navigator.of(context).push(fadeSlideRoute((_) => const SettingsScreen()));

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static const scrollKey = Key('settings-scroll');
  static const saveBarKey = Key('settings-save-bar');

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _maxWidth = 930.0;
  static const _sectionGap = 44.0;

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      AppStateScope.of(context).settings.load();
    }
  }

  Future<void> _confirmLeave(SettingsController settings) async {
    final leave = await confirmDialog(
      context,
      title: S.settingsUnsavedTitle,
      message: S.settingsUnsavedMessage,
      confirmLabel: S.settingsUnsavedLeave,
      cancelLabel: S.settingsUnsavedStay,
      destructive: true,
    );
    if (!leave || !mounted) return;
    settings.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final settings = state.settings;

    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => PopScope(
        canPop: !settings.dirty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _confirmLeave(settings);
        },
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    key: SettingsScreen.scrollKey,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 36,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: _maxWidth),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                RoundIconButton(
                                  icon: Icons.chevron_left_rounded,
                                  tooltip: S.settingsBack,
                                  size: 58,
                                  onPressed: () =>
                                      Navigator.of(context).maybePop(),
                                ),
                                const SizedBox(width: 18),
                                Text(S.settingsTitle, style: context.pageTitle),
                              ],
                            ),
                            const SizedBox(height: 36),
                            _ObserverSection(state: state),
                            const SizedBox(height: _sectionGap),
                            _WatchedSection(state: state, settings: settings),
                            const SizedBox(height: _sectionGap),
                            _DiscordSection(state: state, settings: settings),
                            const SizedBox(height: _sectionGap),
                            _StartupSection(settings: settings),
                            const SizedBox(height: _sectionGap),
                            _LanguageSection(state: state),
                            const SizedBox(height: _sectionGap),
                            const _ConfigSection(),
                            const SizedBox(height: _sectionGap),
                            _HelpSection(state: state),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                _SaveBar(settings: settings),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final visible =
        settings.dirty || settings.offerRollback || settings.error != null;

    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.screen),
      transitionBuilder: (child, anim) => SizeTransition(
        sizeFactor: anim,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Container(
              key: SettingsScreen.saveBarKey,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: const BoxDecoration(
                color: AppColors.card,
                border: Border(
                  top: BorderSide(color: AppColors.divider, width: 2),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      settings.error ??
                          (settings.dirty
                              ? S.settingsBarUnsaved
                              : S.settingsBarConnectionLost),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.label.copyWith(
                        fontSize: 14,
                        color: settings.error != null
                            ? AppColors.alert
                            : AppColors.text,
                      ),
                    ),
                  ),
                  if (settings.offerRollback) ...[
                    PillButton(
                      label: S.homeRollback,
                      compact: true,
                      busy: settings.rollingBack,
                      onPressed: settings.rollback,
                    ),
                    const SizedBox(width: 10),
                  ],
                  if (settings.dirty) ...[
                    PillButton(
                      label: S.settingsBarCancel,
                      compact: true,
                      onPressed: settings.saving ? null : settings.cancel,
                    ),
                    const SizedBox(width: 10),
                    PillButton(
                      label: S.settingsBarSave,
                      primary: true,
                      compact: true,
                      busy: settings.saving,
                      onPressed: settings.save,
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _ObserverSection extends StatelessWidget {
  const _ObserverSection({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final connected = state.observerConnected;

    return SettingsSection(
      title: S.settingsObserverTitle,
      subtitle: S.settingsObserverSubtitle,
      rows: [
        SettingsRow(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          leading: Padding(
            padding: const EdgeInsets.only(right: 18),
            child: LetterAvatar(letter: state.observerInitial, size: 58),
          ),
          trailing: PillButton(
            label: connected
                ? S.settingsAccountDisconnect
                : S.settingsAccountConnect,
            onPressed: connected
                ? () => _disconnect(context, state, NsoAccount.observer)
                : () => _connect(context, SetupStep.observer),
          ),
          label: state.observerName,
          sublabel: connected
              ? S.settingsAccountConnected
              : S.settingsAccountDisconnected,
          sublabelColor: connected ? AppColors.online : AppColors.textMuted,
        ),
      ],
    );
  }
}

class _WatchedSection extends StatelessWidget {
  const _WatchedSection({required this.state, required this.settings});

  final AppState state;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final target = settings.draft?.backend.watchTarget;
    final accounts = state.watchableAccounts;
    WatchedAccount? selected;
    for (final a in accounts) {
      if (a.nsaId == target) selected = a;
    }
    selected ??= target == null || target.isEmpty ? state.watched : null;

    return SettingsSection(
      title: S.settingsMainTitle,
      subtitle: S.settingsMainSubtitle,
      rows: [
        SettingsRow(
          label: S.settingsMainFriendList,
          sublabel: state.friendsFromMain
              ? S.settingsMainFriendListMain
              : S.settingsMainFriendListObserver,
          trailing: StatusText(
            state.friendsFromMain
                ? (state.mainAccountName ?? S.settingsMainMainAccount)
                : S.settingsMainObserverAccount,
            positive: state.friendsFromMain,
          ),
        ),
        SettingsRow(
          label: S.settingsMainMainAccount,
          sublabel: S.settingsMainMainOptional,
          trailing: PillButton(
            label: state.mainConnected
                ? S.settingsAccountDisconnect
                : S.settingsAccountConnect,
            onPressed: state.mainConnected
                ? () => _disconnect(context, state, NsoAccount.main)
                : () => _connect(context, SetupStep.main),
          ),
        ),
        SettingsRow(
          label: S.settingsMainWatched,
          sublabel: settings.errorField == 'watchTarget'
              ? S.settingsMainWatchedRejected
              : null,
          sublabelColor: settings.errorField == 'watchTarget'
              ? AppColors.alert
              : null,
          trailingFlex: true,
          trailing: PillDropdown<WatchedAccount>(
            value: selected,
            hint: S.settingsMainNoAccount,
            items: accounts,
            labelOf: (a) => a.label,
            onChanged: (a) =>
                settings.editBackend((b) => b.copyWith(watchTarget: a.nsaId)),
          ),
        ),
      ],
    );
  }
}

class _DiscordSection extends StatelessWidget {
  const _DiscordSection({required this.state, required this.settings});

  final AppState state;
  final SettingsController settings;

  static const _intervalOptions = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  static const _idleOptions = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
  ];

  @override
  Widget build(BuildContext context) {
    final b = settings.draft?.backend;
    final test = state.discordTest;

    return SettingsSection(
      title: S.settingsDiscordTitle,
      subtitle: S.settingsDiscordSubtitle,
      rows: [
        SettingsRow(
          label: S.settingsDiscordDesktop,
          sublabel: test == null
              ? null
              : test.ok
              ? S.settingsDiscordTestSent
              : (test.error.isEmpty ? S.settingsDiscordTestFailed : test.error),
          sublabelColor: test == null
              ? null
              : test.ok
              ? AppColors.online
              : AppColors.alert,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: StatusText(
                  state.discordConnected
                      ? S.settingsDiscordConnected
                      : state.presenceEnabled
                      ? S.settingsDiscordNotConnected
                      : S.settingsDiscordPresenceOff,
                  positive: state.discordConnected,
                ),
              ),
              const SizedBox(width: 12),
              PillButton(
                label: S.settingsDiscordTest,
                compact: true,
                busy: state.discordTesting,
                onPressed: state.api == null ? null : state.testDiscord,
              ),
            ],
          ),
        ),
        SettingsRow(
          label: S.settingsDiscordPresence,
          sublabel: S.settingsDiscordPresenceSub,
          trailing: RedSwitch(
            value: b?.discordEnabled ?? state.presenceEnabled,
            semanticLabel: S.settingsDiscordPresenceSemantic,
            onChanged: b == null
                ? null
                : (v) => settings.editBackend(
                    (b) => b.copyWith(discordEnabled: v),
                  ),
          ),
        ),
        SettingsRow(
          label: S.settingsDiscordShowIdle,
          sublabel: S.settingsDiscordShowIdleSub,
          trailing: RedSwitch(
            value: b?.showIdle ?? true,
            semanticLabel: S.settingsDiscordShowIdleSemantic,
            onChanged: b == null
                ? null
                : (v) => settings.editBackend((b) => b.copyWith(showIdle: v)),
          ),
        ),
        SettingsRow(
          label: S.settingsDiscordFrequency,
          sublabel: settings.errorField?.contains('nterval') == true
              ? S.settingsDiscordFrequencyRejected
              : S.settingsDiscordFrequencySub,
          sublabelColor: settings.errorField?.contains('nterval') == true
              ? AppColors.alert
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DurationPicker(
                value: Duration(
                  seconds: b?.intervalSeconds ?? state.interval.inSeconds,
                ),
                options: _intervalOptions,
                tooltip: S.settingsDiscordInGame,
                onSelected: (d) => settings.editBackend(
                  (b) => b.copyWith(intervalSeconds: d.inSeconds),
                ),
              ),
              const SizedBox(width: 10),
              _DurationPicker(
                value: Duration(
                  seconds:
                      b?.idleIntervalSeconds ?? state.idleInterval.inSeconds,
                ),
                options: _idleOptions,
                tooltip: S.settingsDiscordNotInGame,
                onSelected: (d) => settings.editBackend(
                  (b) => b.copyWith(idleIntervalSeconds: d.inSeconds),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DurationPicker extends StatelessWidget {
  const _DurationPicker({
    required this.value,
    required this.options,
    required this.onSelected,
    required this.tooltip,
  });

  final Duration value;
  final List<Duration> options;
  final ValueChanged<Duration> onSelected;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.raised),
      ),
      menuChildren: [
        for (final o in options)
          MenuItemButton(
            onPressed: () => onSelected(o),
            child: Text(
              _shortDuration(o),
              style: context.label.copyWith(fontWeight: FontWeight.w500),
            ),
          ),
      ],
      builder: (context, controller, _) => ValueChip(
        label: _shortDuration(value),
        tooltip: tooltip,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

class _StartupSection extends StatelessWidget {
  const _StartupSection({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final d = settings.draft;

    return SettingsSection(
      title: S.settingsStartupTitle,
      rows: [
        SettingsRow(
          label: S.settingsStartupLaunchAtLogin,
          trailing: RedSwitch(
            value: d?.launchAtLogin ?? false,
            semanticLabel: S.settingsStartupLaunchAtLogin,
            onChanged: d == null
                ? null
                : (v) => settings.edit((s) => s.copyWith(launchAtLogin: v)),
          ),
        ),
        SettingsRow(
          label: S.settingsStartupStartMinimized,
          sublabel: S.settingsStartupStartMinimizedSub,
          trailing: RedSwitch(
            value: d?.startMinimized ?? false,
            semanticLabel: S.settingsStartupStartMinimizedSemantic,
            onChanged: d == null
                ? null
                : (v) => settings.edit((s) => s.copyWith(startMinimized: v)),
          ),
        ),
      ],
    );
  }
}

class _LanguageSection extends StatelessWidget {
  const _LanguageSection({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      title: S.settingsLanguageTitle,
      rows: [
        SettingsRow(
          label: S.settingsLanguageLabel,
          sublabel: S.settingsLanguageSub,
          trailingFlex: true,
          trailing: PillSegmented<String>(
            key: const Key('language-picker'),
            value: state.language,
            options: {for (final l in kLocales) l: localeName(l)},
            onChanged: state.setLanguage,
          ),
        ),
      ],
    );
  }
}

class _ConfigSection extends StatelessWidget {
  const _ConfigSection();

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      title: S.settingsConfigTitle,
      rows: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Row(
            children: [
              PillButton(
                label: S.settingsConfigExport,
                primary: true,
                onPressed: () => _snack(
                  context,
                  S.settingsNotWired(action: S.settingsConfigExport),
                ),
              ),
              const SizedBox(width: 12),
              PillButton(
                label: S.settingsConfigImport,
                onPressed: () => _snack(
                  context,
                  S.settingsNotWired(action: S.settingsConfigImport),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final services = AppServicesScope.of(context);

    return SettingsSection(
      title: S.settingsHelpTitle,
      rows: [
        SettingsRow(
          label: S.settingsHelpVersion,
          trailing: StatusText(
            S.settingsHelpVersionValue(
              app: services.version,
              backend: state.backendVersion ?? S.settingsHelpUnknownVersion,
            ),
          ),
        ),
        if (services.updates != null)
          _UpdatesRow(controller: services.updates!),
        SettingsRow(
          label: S.settingsHelpReport,
          sublabel: S.settingsHelpReportSub,
          trailing: PillButton(
            label: S.settingsHelpReport,
            onPressed: services.reportIssue == null
                ? null
                : () async {
                    try {
                      await services.reportIssue!();
                    } catch (e) {
                      if (context.mounted) {
                        _snack(context, S.settingsHelpReportFailed(error: e));
                      }
                    }
                  },
          ),
        ),
      ],
    );
  }
}

class _UpdatesRow extends StatelessWidget {
  const _UpdatesRow({required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final busy =
            c.phase == UpdatePhase.checking ||
            c.phase == UpdatePhase.downloading ||
            c.phase == UpdatePhase.installing;
        final status = switch (c.phase) {
          UpdatePhase.checking => S.settingsUpdatesChecking,
          UpdatePhase.upToDate => S.settingsUpdatesUpToDate,
          UpdatePhase.available || UpdatePhase.error when c.release != null =>
            S.settingsUpdatesAvailable(version: c.release!.version),
          UpdatePhase.downloading => S.settingsUpdatesDownloading(
            percent: (c.progress * 100).round(),
          ),
          UpdatePhase.installing => S.settingsUpdatesInstalling,
          UpdatePhase.error => c.error ?? S.settingsUpdatesFailed,
          _ => S.settingsUpdatesAuto,
        };

        return SettingsRow(
          label: S.settingsUpdatesLabel,
          sublabel: status,
          sublabelColor: c.phase == UpdatePhase.error ? AppColors.alert : null,
          trailing: c.updateAvailable
              ? PillButton(
                  label: S.settingsUpdatesInstall(version: c.release!.version),
                  primary: true,
                  busy: busy,
                  onPressed: busy
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) =>
                              Dialog(child: UpdatePopover(controller: c)),
                        ),
                )
              : PillButton(
                  label: S.settingsUpdatesCheck,
                  busy: busy,
                  onPressed: busy
                      ? null
                      : () async {
                          await c.check();
                          if (context.mounted && c.phase == UpdatePhase.idle) {
                            _snack(context, S.settingsUpdatesUnreachable);
                          }
                        },
                ),
        );
      },
    );
  }
}
