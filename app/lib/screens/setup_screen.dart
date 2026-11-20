import 'package:flutter/material.dart';

import '../app_services.dart';
import '../i18n/i18n.dart';
import '../models/models.dart';
import '../setup/setup_controller.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/settings_widgets.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, this.only});

  final SetupStep? only;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  SetupController? _c;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c == null) {
      final services = AppServicesScope.of(context);
      _c = SetupController(
        state: AppStateScope.of(context),
        browser: services.browser,
        openExternal: services.openUrl,
      )..addListener(_onChange);
      if (widget.only != null) _c!.goTo(widget.only!);
    }
  }

  void _onChange() {
    final only = widget.only;
    if (only != null && _c!.step != only && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _c?.removeListener(_onChange);
    _c?.dispose();
    super.dispose();
  }

  static Map<SetupStep, String> get _titles => {
    SetupStep.terms: S.setupStepTerms,
    SetupStep.observer: S.setupStepObserver,
    SetupStep.main: S.setupStepMain,
    SetupStep.target: S.setupStepTarget,
    SetupStep.discord: S.setupStepDiscord,
    SetupStep.preferences: S.setupStepPreferences,
  };

  @override
  Widget build(BuildContext context) {
    final c = _c!;
    AppStateScope.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (widget.only != null) ...[
                      RoundIconButton(
                        icon: Icons.chevron_left_rounded,
                        tooltip: S.setupBack,
                        size: 52,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 16),
                    ] else ...[
                      const NsonlineMark(size: 44),
                      const SizedBox(width: 14),
                    ],
                    Text(
                      widget.only == null
                          ? S.setupWelcome
                          : _titles[widget.only]!,
                      style: context.pageTitle,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.only == null) ...[
                        SizedBox(width: 230, child: _StepList(c: c)),
                        const SizedBox(width: 24),
                      ],
                      Expanded(
                        child: SingleChildScrollView(
                          child: AppCard(
                            padding: const EdgeInsets.all(28),
                            child: AnimatedSwitcher(
                              duration: AppMotion.of(context, AppMotion.screen),
                              transitionBuilder: fadeSlideTransition,
                              child: KeyedSubtree(
                                key: ValueKey(c.step),
                                child: _StepBody(c: c),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepList extends StatelessWidget {
  const _StepList({required this.c});

  final SetupController c;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in SetupStep.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FocusGlow(
              child: Material(
                color: s == c.step ? AppColors.raised : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.tile),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadii.tile),
                  onTap: c.busy ? null : () => c.goTo(s),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          c.isDone(s)
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 20,
                          color: c.isDone(s)
                              ? AppColors.online
                              : s == c.step
                              ? AppColors.accent
                              : AppColors.textFaint,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _SetupScreenState._titles[s]!,
                            style: context.label.copyWith(fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StepBody extends StatelessWidget {
  const _StepBody({required this.c});

  final SetupController c;

  @override
  Widget build(BuildContext context) {
    final children = switch (c.step) {
      SetupStep.terms => _terms(context),
      SetupStep.observer => _login(
        context,
        NsoAccount.observer,
        S.setupObserverText,
      ),
      SetupStep.main => _login(
        context,
        NsoAccount.main,
        S.setupMainText,
        optional: true,
      ),
      SetupStep.target => _target(context),
      SetupStep.discord => _discord(context),
      SetupStep.preferences => _preferences(context),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...children,
        if (c.info != null) ...[
          const SizedBox(height: 14),
          Text(c.info!, key: const Key('setup-info'), style: context.body),
        ],
        if (c.error != null) ...[
          const SizedBox(height: 14),
          Text(
            c.error!,
            key: const Key('setup-error'),
            style: context.body.copyWith(color: AppColors.alert),
          ),
        ],
      ],
    );
  }

  List<Widget> _terms(BuildContext context) => [
    Text(S.setupTermsTitle, style: context.cardTitle),
    const SizedBox(height: 12),
    Text(S.setupTermsBody, style: context.body),
    const SizedBox(height: 10),
    Text(S.setupTermsDisclaimer, style: context.body),
    const SizedBox(height: 22),
    PillButton(
      label: S.setupTermsAccept,
      primary: true,
      busy: c.busy,
      onPressed: c.acceptTerms,
    ),
  ];

  List<Widget> _login(
    BuildContext context,
    NsoAccount account,
    String text, {
    bool optional = false,
  }) {
    final done = account == NsoAccount.observer
        ? c.state.setup.observerLoggedIn
        : c.state.setup.mainLoggedIn;
    return [
      Text(
        account == NsoAccount.observer ? S.setupStepObserver : S.setupStepMain,
        style: context.cardTitle,
      ),
      const SizedBox(height: 12),
      Text(text, style: context.body),
      if (done) ...[
        const SizedBox(height: 10),
        Text(
          S.setupLoginConnected,
          style: context.body.copyWith(color: AppColors.online),
        ),
      ],
      const SizedBox(height: 22),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          PillButton(
            label: S.setupLoginWithNintendo,
            primary: true,
            busy: c.busy,
            onPressed: () => c.login(account),
          ),
          PillButton(
            label: S.setupLoginSystemBrowser,
            onPressed: c.busy ? null : () => c.loginInSystemBrowser(account),
          ),
          if (optional || done)
            PillButton(
              label: optional && !done ? S.setupSkip : S.setupContinue,
              onPressed: c.busy ? null : c.next,
            ),
        ],
      ),
      if (c.pasteFor == account) ...[
        const SizedBox(height: 18),
        _PasteField(c: c, account: account),
      ],
    ];
  }

  List<Widget> _target(BuildContext context) {
    final state = c.state;
    final accounts = state.watchableAccounts;
    return [
      Text(S.setupTargetTitle, style: context.cardTitle),
      const SizedBox(height: 12),
      Text(S.setupTargetText, style: context.body),
      const SizedBox(height: 18),
      if (accounts.isEmpty)
        Text(
          state.loading ? S.setupTargetLoading : S.setupTargetEmpty,
          style: context.body,
        )
      else
        for (final a in accounts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FocusGlow(
              child: Material(
                color: a == state.watched
                    ? AppColors.accent.withValues(alpha: 0.18)
                    : AppColors.raised,
                borderRadius: BorderRadius.circular(AppRadii.tile),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadii.tile),
                  onTap: c.busy ? null : () => c.chooseTarget(a),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        LetterAvatar(letter: initialOf(a.name), size: 40),
                        const SizedBox(width: 12),
                        Expanded(child: Text(a.name, style: context.label)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 12,
        children: [
          PillButton(label: S.setupTargetRefresh, onPressed: state.refresh),
          if (state.setup.targetSet)
            PillButton(label: S.setupContinue, onPressed: c.next),
        ],
      ),
    ];
  }

  List<Widget> _discord(BuildContext context) => [
    Text(S.setupDiscordTitle, style: context.cardTitle),
    const SizedBox(height: 12),
    Text(
      S.setupDiscordText(activity: S.discordTestDetails),
      style: context.body,
    ),
    const SizedBox(height: 22),
    Wrap(
      spacing: 12,
      children: [
        PillButton(
          label: S.setupDiscordTest,
          primary: true,
          busy: c.busy,
          onPressed: c.testDiscord,
        ),
        PillButton(label: S.setupContinue, onPressed: c.busy ? null : c.next),
      ],
    ),
  ];

  List<Widget> _preferences(BuildContext context) => [
    Text(S.setupPreferencesTitle, style: context.cardTitle),
    const SizedBox(height: 12),
    SettingsRow(
      padding: EdgeInsets.zero,
      label: S.settingsStartupLaunchAtLogin,
      trailing: RedSwitch(
        value: c.launchAtLogin,
        semanticLabel: S.settingsStartupLaunchAtLogin,
        onChanged: (v) => c.setPreferences(launchAtLogin: v),
      ),
    ),
    const SizedBox(height: 14),
    SettingsRow(
      padding: EdgeInsets.zero,
      label: S.settingsStartupStartMinimized,
      trailing: RedSwitch(
        value: c.startMinimized,
        semanticLabel: S.settingsStartupStartMinimizedSemantic,
        onChanged: (v) => c.setPreferences(startMinimized: v),
      ),
    ),
    const SizedBox(height: 22),
    PillButton(
      label: S.setupFinish,
      primary: true,
      busy: c.busy,
      onPressed: c.finish,
    ),
  ];
}

class _PasteField extends StatefulWidget {
  const _PasteField({required this.c, required this.account});

  final SetupController c;
  final NsoAccount account;

  @override
  State<_PasteField> createState() => _PasteFieldState();
}

class _PasteFieldState extends State<_PasteField> {
  String _value = '';

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: PillTextField(
            key: const Key('setup-paste'),
            initialValue: '',
            hint: 'npf71b963c1b7b6d119://auth#session_token_code=…',
            onChanged: (v) => _value = v,
          ),
        ),
        const SizedBox(width: 12),
        PillButton(
          label: S.setupPasteValidate,
          primary: true,
          busy: widget.c.busy,
          onPressed: () => widget.c.submitPasted(widget.account, _value),
        ),
      ],
    );
  }
}
