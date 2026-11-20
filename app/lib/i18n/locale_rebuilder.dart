import 'package:flutter/widgets.dart';

import 'i18n.dart';

class LocaleRebuilder extends StatefulWidget {
  const LocaleRebuilder({super.key, required this.child});

  final Widget child;

  @override
  State<LocaleRebuilder> createState() => _LocaleRebuilderState();
}

class _LocaleRebuilderState extends State<LocaleRebuilder> {
  @override
  void initState() {
    super.initState();
    appLocale.addListener(_onLocale);
  }

  @override
  void dispose() {
    appLocale.removeListener(_onLocale);
    super.dispose();
  }

  void _onLocale() {
    if (!mounted) return;
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
