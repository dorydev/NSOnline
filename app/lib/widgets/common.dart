
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

Color coralColor(CoralState s) => switch (s) {
  CoralState.ok => AppColors.online,
  CoralState.degraded => AppColors.warning,
  CoralState.down => AppColors.alert,
  CoralState.unknown => AppColors.textFaint,
};

String agoLabel(Duration d) {
  if (d.inSeconds < 60) return S.timeJustNow;
  if (d.inMinutes < 60) return S.timeMinutesAgo(count: d.inMinutes);
  if (d.inHours < 24) return S.timeHoursAgo(count: d.inHours);
  return S.timeDaysAgo(count: d.inDays);
}

String shortDuration(Duration d) {
  if (d.inHours > 0) {
    return S.durationHoursMinutes(
      hours: d.inHours,
      minutes: (d.inMinutes % 60).toString().padLeft(2, '0'),
    );
  }
  if (d.inMinutes > 0) return S.durationMinutes(count: d.inMinutes);
  return S.durationSeconds(count: d.inSeconds);
}

class FocusGlow extends StatefulWidget {
  const FocusGlow({
    super.key,
    required this.child,
    this.borderRadius,
    this.circle = false,
    this.enabled = true,
    this.scale = AppMotion.hoverScale,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final bool circle;
  final bool enabled;
  final double scale;

  @override
  State<FocusGlow> createState() => _FocusGlowState();
}

class _FocusGlowState extends State<FocusGlow>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: AppMotion.pulse,
  );
  bool _hovered = false;
  bool _focused = false;

  bool get _active => widget.enabled && (_hovered || _focused);

  void _update() {
    if (!mounted) return;
    setState(() {});
    final reduced = AppMotion.reduced(context);
    if (_active && !reduced) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final radius = widget.borderRadius ?? BorderRadius.circular(AppRadii.tile);

    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _update();
      },
      onExit: (_) {
        _hovered = false;
        _update();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onFocusChange: (f) {
          _focused =
              f &&
              FocusManager.instance.highlightMode ==
                  FocusHighlightMode.traditional;
          _update();
        },
        child: AnimatedScale(
          scale: _active && !reduced ? widget.scale : 1,
          duration: AppMotion.of(context, AppMotion.fast),
          curve: Curves.easeOutCubic,
          // Same tree with or without the ring, or the child rebuilds on hover.
          child: AnimatedBuilder(
            animation: _pulse,
            child: widget.child,
            builder: (context, child) {
              final t = !_active
                  ? 0.0
                  : (reduced ? 1.0 : 0.55 + 0.45 * _pulse.value);

              return DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: widget.circle ? null : radius,
                  border: Border.all(
                    color: AppColors.accent.withValues(alpha: t),
                    width: AppMotion.ringWidth,
                    // Inside: an outside ring gets clipped by scroll views.
                    strokeAlign: BorderSide.strokeAlignInside,
                  ),
                ),
                child: child,
              );
            },
          ),
        ),
      ),
    );
  }
}

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(30),
    this.interactive = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: child,
    );
    return interactive
        ? FocusGlow(
            borderRadius: BorderRadius.circular(AppRadii.card),
            scale: 1.01,
            child: card,
          )
        : card;
  }
}

class LetterAvatar extends StatelessWidget {
  const LetterAvatar({
    super.key,
    required this.letter,
    this.size = 110,
    this.online = false,
    this.showGameBadge = false,
    this.imageUrl,
    this.badgeImageUrl,
  });

  final String letter;
  final double size;
  final bool online;
  final bool showGameBadge;
  final String? imageUrl;
  final String? badgeImageUrl;

  @override
  Widget build(BuildContext context) {
    final ring = size * 0.035;
    final fallback = Center(
      child: Text(
        letter,
        style: TextStyle(
          fontSize: size * 0.34,
          fontWeight: FontWeight.w800,
          color: online ? AppColors.text : AppColors.textFaint,
        ),
      ),
    );
    final circle = AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.fast),
      width: size,
      height: size,
      padding: EdgeInsets.all(online ? ring * 1.6 : 0),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: online
            ? Border.all(color: AppColors.online, width: ring)
            : Border.all(color: Colors.transparent, width: 0),
      ),
      child: ClipOval(
        child: ColoredBox(
          color: AppColors.avatar,
          child: SizedBox.expand(
            child: imageUrl == null
                ? fallback
                : Opacity(
                    opacity: online ? 1 : 0.55,
                    child: _NetworkImage(url: imageUrl!, fallback: fallback),
                  ),
          ),
        ),
      ),
    );
    if (!showGameBadge) return circle;

    final badge = size * 0.36;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          circle,
          Positioned(
            right: -size * 0.02,
            bottom: size * 0.02,
            child: GameThumbnail(
              size: badge,
              radius: badge * 0.2,
              border: AppColors.card,
              imageUrl: badgeImageUrl,
            ),
          ),
        ],
      ),
    );
  }
}

class GameThumbnail extends StatelessWidget {
  const GameThumbnail({
    super.key,
    this.size = 60,
    this.radius = AppRadii.thumb,
    this.border,
    this.imageUrl,
  });

  final double size;
  final double radius;
  final Color? border;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.thumbnail,
        borderRadius: BorderRadius.circular(radius),
        border: border == null ? null : Border.all(color: border!, width: 3),
      ),
      clipBehavior: imageUrl == null ? Clip.none : Clip.antiAlias,
      child: imageUrl == null
          ? null
          : _NetworkImage(url: imageUrl!, fallback: const SizedBox.shrink()),
    );
  }
}

class _NetworkImage extends StatelessWidget {
  const _NetworkImage({required this.url, required this.fallback});

  final String url;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

class CrossFade extends StatelessWidget {
  const CrossFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.crossfade),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class PopOnChange extends StatefulWidget {
  const PopOnChange({super.key, required this.trigger, required this.child});

  final Object? trigger;
  final Widget child;

  @override
  State<PopOnChange> createState() => _PopOnChangeState();
}

class _PopOnChangeState extends State<PopOnChange>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1,
  );
  late final _scale = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.15), weight: 40),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.15,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 60,
    ),
  ]).animate(_c);

  @override
  void didUpdateWidget(PopOnChange old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger && !AppMotion.reduced(context)) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ScaleTransition(scale: _scale, child: widget.child);
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.color = AppColors.online,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.label.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 9});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class CoralPill extends StatelessWidget {
  const CoralPill({
    super.key,
    required this.status,
    this.tokenExpiresIn,
    this.now,
  });

  final CoralStatus status;
  final Duration? tokenExpiresIn;
  final DateTime? now;

  static String tooltipFor(
    CoralStatus s, {
    Duration? tokenExpiresIn,
    required DateTime now,
  }) {
    final last = s.lastSuccess;
    final lines = [
      S.coralTooltipStatus(status: s.label),
      S.coralTooltipLatency(
        latency: s.latencyMs > 0
            ? S.coralTooltipLatencyMs(ms: s.latencyMs)
            : S.coralTooltipNone,
      ),
      S.coralTooltipLastSuccess(
        when: last == null
            ? S.coralTooltipNever
            : agoLabel(now.difference(last)),
      ),
      S.coralTooltipToken(
        state: switch (tokenExpiresIn) {
          null => S.coralTooltipTokenUnknown,
          final d when d <= Duration.zero => S.coralTooltipTokenExpired,
          final d => S.coralTooltipTokenExpiresIn(duration: shortDuration(d)),
        },
      ),
      if (s.lastErrorCode != 0 || s.lastError.isNotEmpty)
        S.coralTooltipLastError(
          error: [
            if (s.lastErrorCode != 0) '${s.lastErrorCode}',
            if (s.lastError.isNotEmpty) s.lastError,
          ].join(' · '),
        ),
      if (s.retryAfterSeconds > 0)
        S.coralTooltipRetryIn(seconds: s.retryAfterSeconds),
    ];
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final color = coralColor(status.state);

    return Tooltip(
      message: tooltipFor(
        status,
        tokenExpiresIn: tokenExpiresIn,
        now: now ?? DateTime.now(),
      ),
      child: Semantics(
        label: S.coralSemantic(status: status.label),
        excludeSemantics: true,
        child: AnimatedContainer(
          duration: AppMotion.of(context, AppMotion.fast),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.raised,
            borderRadius: BorderRadius.circular(40),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                S.coralName,
                style: context.label.copyWith(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 7),
              StatusDot(color: color),
              const SizedBox(width: 6),
              Text(
                status.label,
                style: context.label.copyWith(fontSize: 13, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    this.icon,
    this.child,
    required this.onPressed,
    this.tooltip,
    this.size = 64,
  }) : assert(icon != null || child != null);

  final IconData? icon;

  final Widget? child;
  final VoidCallback onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: FocusGlow(
        circle: true,
        scale: 1.06,
        child: Material(
          color: AppColors.raised,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: size,
              child: Center(
                child:
                    child ??
                    Icon(icon, color: AppColors.text, size: size * 0.42),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RedSwitch extends StatelessWidget {
  const RedSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: Transform.scale(
        scale: 1.25,
        child: Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: Colors.white,
          activeTrackColor: AppColors.accent,
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: AppColors.raised,
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
    );
  }
}

class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.destructive = false,
    this.busy = false,
    this.compact = false,
  });

  final String label;

  final VoidCallback? onPressed;
  final bool primary;
  final bool destructive;

  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final bg = destructive
        ? AppColors.alert
        : primary
        ? AppColors.text
        : AppColors.raised;
    final fg = destructive
        ? AppColors.text
        : primary
        ? AppColors.background
        : AppColors.text;

    return FocusGlow(
      enabled: enabled,
      borderRadius: BorderRadius.circular(40),
      child: Opacity(
        opacity: enabled || busy ? 1 : 0.45,
        child: Material(
          color: bg,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: enabled ? onPressed : null,
            child: Padding(
              padding: compact
                  ? const EdgeInsets.symmetric(horizontal: 16, vertical: 9)
                  : const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy) ...[
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.label.copyWith(
                        color: fg,
                        fontSize: compact ? 14 : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Route<T> fadeSlideRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
  transitionDuration: AppMotion.screen,
  reverseTransitionDuration: AppMotion.screen,
  pageBuilder: (context, _, _) => builder(context),
  transitionsBuilder: (context, anim, _, child) {
    if (AppMotion.reduced(context)) return child;
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0.04, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  },
);

Widget fadeSlideTransition(Widget child, Animation<double> anim) {
  final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);

  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween(
        begin: const Offset(0, 0.03),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    ),
  );
}

class NsonlineMark extends StatelessWidget {
  const NsonlineMark({super.key, this.size = 96, this.progress = 1});

  final double size;

  final double progress;

  @override
  Widget build(BuildContext context) {
    final t = progress.clamp(0.0, 1.0);
    return Opacity(
      opacity: t,
      child: Transform.scale(
        scale: 0.85 + 0.15 * t,
        child: Image.asset(
          'assets/icon_512.png',
          width: size,
          height: size,
          filterQuality: FilterQuality.none,
        ),
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? cancelLabel,
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: context.cardTitle),
      content: Text(message, style: context.body),
      actions: [
        PillButton(
          label: cancelLabel ?? S.commonCancel,
          compact: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        PillButton(
          label: confirmLabel,
          compact: true,
          primary: !destructive,
          destructive: destructive,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return ok == true;
}
