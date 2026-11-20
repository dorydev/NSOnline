import 'dart:io';

import '../i18n/i18n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'app_logger.dart';
import 'issue_report.dart';

IssueReport issueReportFor(
  AppState s, {
  required String appVersion,
  String? dataDir,
  String? os,
  String? osVersion,
  int lines = 80,
}) {
  List<String> tail(String name) => dataDir == null
      ? const []
      : tailLines(
          File(
            '$dataDir${Platform.pathSeparator}logs${Platform.pathSeparator}$name',
          ),
          lines: lines,
        );
  return IssueReport(
    appVersion: appVersion,
    os: os ?? Platform.operatingSystem,
    osVersion: osVersion ?? Platform.operatingSystemVersion,
    backendVersion: s.backendVersion ?? S.reportUnknownVersion,
    coralState: [
      s.coral.label,
      if (s.coral.state != CoralState.ok && s.coral.lastErrorCode != 0)
        S.reportCoralCode(code: s.coral.lastErrorCode),
      if (s.backendError != null) S.reportBackendError(error: s.backendError!),
    ].join(' · '),
    discordState: !s.presenceEnabled
        ? S.reportPresenceOff
        : s.discordConnected
        ? S.reportConnected
        : S.reportNotConnected,
    backendLog: tail('backend.log'),
    appLog: tail('app.log'),
  );
}
