import 'dart:async';

import 'package:flutter/widgets.dart';

import '../i18n/i18n.dart';

String sessionDurationLabel(Duration d, {bool seconds = false}) {
  final m = d.inMinutes;
  if (m < 1 && seconds) return S.durationSeconds(count: d.inSeconds);
  return m < 60
      ? S.durationMinutes(count: m)
      : S.durationHoursMinutes(
          hours: m ~/ 60,
          minutes: (m % 60).toString().padLeft(2, '0'),
        );
}

class LiveClock extends StatefulWidget {
  const LiveClock({
    super.key,
    required this.builder,
    this.every = const Duration(seconds: 1),
    this.now,
  });

  final Widget Function(BuildContext context, DateTime now) builder;
  final Duration every;
  final DateTime Function()? now;

  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.every, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, (widget.now ?? DateTime.now)());
}
