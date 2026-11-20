import '../i18n/i18n.dart';
import 'redact.dart';

int _len(List<String> lines) => lines.fold(0, (sum, l) => sum + l.length + 1);

String _body(IssueReport r, List<String> backend, List<String> app) {
  String block(String name, List<String> lines) => lines.isEmpty
      ? '### $name\n${S.reportLogEmpty}\n'
      : '### ${S.reportLogHeader(name: name)}\n```text\n${lines.join('\n')}\n```\n';
  return '''
### ${S.reportDescription}
<!-- ${S.reportDescribe} -->


### ${S.reportEnvironment}
- NSOnline: ${r.appVersion}
- ${S.reportSystem}: ${r.os} ${r.osVersion}
- Backend: ${r.backendVersion}
- Coral: ${r.coralState}
- Discord: ${r.discordState}

${block('backend.log', backend)}
${block('app.log', app)}
${S.reportReviewLogs}
''';
}

class IssueReport {
  const IssueReport({
    required this.appVersion,
    required this.os,
    required this.osVersion,
    required this.backendVersion,
    required this.coralState,
    required this.discordState,
    this.backendLog = const [],
    this.appLog = const [],
  });

  final String appVersion;
  final String os;
  final String osVersion;
  final String backendVersion;
  final String coralState;
  final String discordState;
  final List<String> backendLog;
  final List<String> appLog;
}

const issueBaseUrl = 'https://github.com/dorydev/NSOnline/issues/new';

const issueUrlMaxLength = 7000;

Uri buildIssueUrl(IssueReport r, {int maxLength = issueUrlMaxLength}) {
  final title = S.reportTitle(version: r.appVersion, os: r.os);
  var backend = [for (final l in r.backendLog) redactSecrets(l)];
  var app = [for (final l in r.appLog) redactSecrets(l)];

  Uri build() => Uri.parse(
    issueBaseUrl,
  ).replace(queryParameters: {'title': title, 'body': _body(r, backend, app)});

  var uri = build();
  while (uri.toString().length > maxLength) {
    if (backend.isEmpty && app.isEmpty) {
      var body = _body(r, const [], const []);
      var t = title;
      Uri cut() => Uri.parse(
        issueBaseUrl,
      ).replace(queryParameters: {'title': t, 'body': body});
      var u = cut();
      while (u.toString().length > maxLength &&
          (body.isNotEmpty || t.isNotEmpty)) {
        if (body.isNotEmpty) {
          body = body.substring(0, (body.length * 0.9).floor());
        } else {
          t = t.substring(0, (t.length * 0.9).floor());
        }
        u = cut();
      }
      return u;
    }
    final longer = _len(backend) >= _len(app) ? backend : app;
    if (longer.length == 1 && longer.first.length > 200) {
      longer[0] = '…${longer.first.substring(longer.first.length ~/ 2)}';
    } else {
      longer.removeAt(0);
    }
    if (identical(longer, backend)) {
      backend = longer;
    } else {
      app = longer;
    }
    uri = build();
  }
  return uri;
}
