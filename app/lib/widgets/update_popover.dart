import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../theme/app_theme.dart';
import '../update/update_controller.dart';
import 'common.dart';

class UpdateBadge extends StatelessWidget {
  const UpdateBadge({super.key, required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final r = controller.release;
        if (r == null) return const SizedBox.shrink();
        return FocusGlow(
          borderRadius: BorderRadius.circular(40),
          child: Material(
            color: AppColors.accent.withValues(alpha: 0.16),
            shape: StadiumBorder(
              side: BorderSide(color: AppColors.accent.withValues(alpha: 0.6)),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    Dialog(child: UpdatePopover(controller: controller)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  S.updateNewVersion(version: r.version),
                  style: context.label.copyWith(
                    fontSize: 14,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class UpdatePopover extends StatelessWidget {
  const UpdatePopover({super.key, required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final r = controller.release;
        final phase = controller.phase;
        final working =
            phase == UpdatePhase.downloading || phase == UpdatePhase.installing;

        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  r == null
                      ? S.updateUpToDate
                      : S.updateNewVersion(version: r.version),
                  style: context.cardTitle,
                ),
                const SizedBox(height: 4),
                Text(
                  S.updateInstalled(version: controller.currentVersion),
                  style: context.caption,
                ),
                if (r != null && r.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.raised,
                        borderRadius: BorderRadius.circular(AppRadii.tile),
                      ),
                      child: SingleChildScrollView(
                        child: Text(r.notes.trim(), style: context.body),
                      ),
                    ),
                  ),
                ],
                if (phase == UpdatePhase.downloading) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: controller.progress > 0 ? controller.progress : null,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    S.updateDownloading(
                      percent: (controller.progress * 100).round(),
                    ),
                    style: context.caption,
                  ),
                ],
                if (phase == UpdatePhase.installing) ...[
                  const SizedBox(height: 16),
                  Text(S.updateRestarting, style: context.caption),
                ],
                if (controller.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    controller.error!,
                    style: context.caption.copyWith(color: AppColors.alert),
                  ),
                ],
                if (r != null && !controller.canInstall) ...[
                  const SizedBox(height: 12),
                  Text(S.updateManualOnly, style: context.caption),
                ],
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    PillButton(
                      label: S.updateLater,
                      onPressed: working
                          ? null
                          : () => Navigator.of(context).maybePop(),
                    ),
                    if (r != null)
                      PillButton(
                        label: S.updateInstall,
                        primary: true,
                        busy: working,
                        onPressed: controller.canInstall
                            ? controller.installUpdate
                            : null,
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
