import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../theme/app_theme.dart';
import 'common.dart';

class BootSplash extends StatefulWidget {
  const BootSplash({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (AppMotion.reduced(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone());
    } else {
      _c.forward().whenComplete(() {
        if (mounted) widget.onDone();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draw = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.7, curve: Curves.easeOutCubic),
    );
    final text = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.45, 1, curve: Curves.easeOut),
    );

    return ColoredBox(
      color: AppColors.background,
      child: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.scale(
                scale: 0.85 + 0.15 * draw.value,
                child: NsonlineMark(size: 112, progress: draw.value),
              ),
              const SizedBox(height: 18),
              Opacity(
                opacity: text.value,
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - text.value)),
                  child: Text(
                    S.appName,
                    style: context.pageTitle.copyWith(letterSpacing: 0.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
