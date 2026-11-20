// Generates lib/i18n/strings.g.dart from the shared catalogs in
// ../shared/i18n (the single source of truth for the app and the backend).
//
//   dart run tool/gen_i18n.dart           # (re)generate
//   dart run tool/gen_i18n.dart --check   # exit 1 if the catalogs are
//                                         # inconsistent or the file is stale
//
// Run from app/ (or through `make i18n` at the repo root).
import 'dart:io';

import 'i18n_catalog.dart';

const sourceDir = '../shared/i18n';
const outputFile = 'lib/i18n/strings.g.dart';

void main(List<String> args) {
  final check = args.contains('--check');
  final cats = loadCatalogs(Directory(sourceDir));
  final problems = checkCatalogs(cats);
  if (problems.isNotEmpty) {
    stderr.writeln('i18n: catalogs are inconsistent:');
    problems.forEach(stderr.writeln);
    exit(1);
  }
  final code = generateDart(cats);
  final out = File(outputFile);
  if (check) {
    if (!out.existsSync() || out.readAsStringSync() != code) {
      stderr.writeln('i18n: $outputFile is stale, run `make i18n`');
      exit(1);
    }
    stdout.writeln('i18n: ${cats[defaultLocale]!.length} keys, up to date');
    return;
  }
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(code);
  stdout.writeln(
    'i18n: wrote $outputFile (${cats[defaultLocale]!.length} keys, '
    'locales ${cats.keys.join(', ')})',
  );
}
