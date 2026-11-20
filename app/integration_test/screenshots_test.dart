// Renders README screenshots with demo data (no real account):
//   cd app && flutter test integration_test/screenshots_test.dart -d macos
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nsonline/app.dart';
import 'package:nsonline/app_services.dart';
import 'package:nsonline/data/mock_data.dart';
import 'package:nsonline/models/models.dart';
import 'package:nsonline/screens/settings_screen.dart';
import 'package:nsonline/state/app_state.dart';
import 'package:nsonline/storage/local_prefs.dart';

class _Demo extends MockRepository {
  _Demo(this.dashboard);
  final Dashboard dashboard;

  @override
  Future<Dashboard> load() async => dashboard;

  @override
  Future<BackendSettings> getSettings() async =>
      const BackendSettings(watchTarget: 'a1b2c3d4e5f60718');
}

const _friends = <Friend>[
  Friend(name: 'Léa', state: PresenceState.playing, game: 'Mario Kart World'),
  Friend(name: 'Hugo', state: PresenceState.playing, game: 'Zelda: TotK'),
  Friend(name: 'Nathan', state: PresenceState.online),
  Friend(name: 'Camille', state: PresenceState.offline, lastSeen: '3 h ago'),
  Friend(name: 'Sarah', state: PresenceState.offline, lastSeen: 'Yesterday'),
  Friend(name: 'Inès', state: PresenceState.offline, lastSeen: '2 days ago'),
  Friend(name: 'Théo', state: PresenceState.offline, lastSeen: '4 days ago'),
  Friend(name: 'Jules', state: PresenceState.offline, lastSeen: '1 week ago'),
  Friend(name: 'Maya', state: PresenceState.offline, lastSeen: '2 weeks ago'),
];

const _profile = Profile(
  name: 'John Doe',
  avatarInitial: 'J',
  subtitle: 'SW-9999-9999-9999 | Nintendo Switch 2',
  currentGame: 'Mario Kart World',
  currentSessionMinutes: 42,
  recentGames: [
    RecentGame(name: 'Mario Kart World', detail: '86 h · since Jun 2025'),
    RecentGame(
      name: 'Animal Crossing: New Horizons',
      detail: '212 h · since Mar 2020',
    ),
    RecentGame(name: 'Splatoon 3', detail: '41 h · since Sep 2022'),
    RecentGame(
      name: 'Super Smash Bros. Ultimate',
      detail: '128 h · since Dec 2018',
    ),
    RecentGame(name: 'Pikmin 4', detail: '19 h · since Jul 2023'),
    RecentGame(name: 'Tetris 99', detail: '7 h · since Feb 2019'),
  ],
);

Dashboard _dashboard({SetupStatus setup = SetupStatus.legacy}) => Dashboard(
  friends: _friends,
  profile: _profile,
  tokens: MockData.dashboard.tokens,
  observerConnected: true,
  observerName: 'John Doe',
  friendsFromMain: true,
  mainAccountName: 'John Doe',
  mainConnected: true,
  discordEnabled: true,
  discordConnected: true,
  watchableAccounts: const [
    WatchedAccount(name: 'John Doe', nsaId: 'a1b2c3d4e5f60718'),
  ],
  watched: const WatchedAccount(name: 'John Doe', nsaId: 'a1b2c3d4e5f60718'),
  config: MockData.dashboard.config,
  coral: const CoralStatus(state: CoralState.ok, latencyMs: 240),
  setup: setup,
);

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 300));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final out = File('../screens/$name.png');
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(bytes!.buffer.asUint8List());
}

Future<void> _pump(WidgetTester tester, GlobalKey key, AppState state) async {
  tester.view.physicalSize = const Size(1280, 840);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: NsoRpcApp(state: state, services: AppServices(), splash: false),
    ),
  );
  await tester.runAsync(() async {
    await state.refresh();
    await GoogleFonts.pendingFonts();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home + settings', (tester) async {
    final key = GlobalKey();
    final state = AppState(
      _Demo(_dashboard()),
      prefs: PrefsStore.memory(const LocalPrefs(setupSeen: true)),
    );
    await _pump(tester, key, state);
    await _shot(tester, key, 'home');

    openSettings(tester.element(find.byType(Scaffold).first));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    await _shot(tester, key, 'settings');
  });

  testWidgets('setup', (tester) async {
    final key = GlobalKey();
    final state = AppState(
      _Demo(
        _dashboard(
          setup: const SetupStatus(
            thirdPartyAck: false,
            observerLoggedIn: false,
            mainLoggedIn: false,
            targetSet: false,
            complete: false,
          ),
        ),
      ),
      prefs: PrefsStore.memory(const LocalPrefs()),
    );
    await _pump(tester, key, state);
    await _shot(tester, key, 'setup');
  });
}
