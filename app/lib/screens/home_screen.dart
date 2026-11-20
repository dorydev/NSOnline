import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../app_services.dart';
import '../config.dart';
import '../i18n/i18n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/live_clock.dart';
import '../widgets/update_popover.dart';
import 'settings_screen.dart';

IconData _serviceIcon(String name) {
  final n = name.toLowerCase();
  if (n.contains('splat')) return Icons.water_drop_outlined;
  if (n.contains('nook')) return Icons.park_outlined;
  if (n.contains('smash')) return Icons.sports_mma_outlined;
  return Icons.sports_esports_outlined;
}

void _showError(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

String sessionLabel(int minutes) => minutes < 60
    ? S.durationMinutes(count: minutes)
    : S.durationHoursMinutes(
        hours: minutes ~/ 60,
        minutes: (minutes % 60).toString().padLeft(2, '0'),
      );

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const _padding = 20.0;
  static const _gap = 20.0;

  static double sideWidth(double windowWidth) =>
      (windowWidth * 0.3).clamp(300.0, 380.0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Padding(
            padding: const EdgeInsets.all(_padding),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _BackendBanner(),
                              _FriendsCard(),
                              SizedBox(height: _gap),
                              _DiscordCard(),
                              SizedBox(height: _gap),
                              _ServicesCard(),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: 12),
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: _BottomBar(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: _gap),
                SizedBox(
                  width: sideWidth(constraints.maxWidth),
                  height: constraints.maxHeight - 2 * _padding,
                  child: const _ProfilePanel(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FriendsCard extends StatelessWidget {
  const _FriendsCard();

  static const maxPerRow = 6;
  static const _spacing = 10.0;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return AppCard(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: S.homeFriendsTitle,
                        style: context.cardTitle.copyWith(fontSize: 19),
                      ),
                      TextSpan(
                        text:
                            '   ${S.homeOnlineCount(count: state.onlineCount)}',
                        style: context.body.copyWith(fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ),
              CoralPill(
                status: state.coral,
                tokenExpiresIn: state.tokens.coralExpiresIn,
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final tileWidth =
                  (constraints.maxWidth - _spacing * (maxPerRow - 1)) /
                  maxPerRow;
              if (state.friends.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    state.loading ? S.commonLoading : S.homeNoFriends,
                    style: context.body,
                  ),
                );
              }
              return Wrap(
                spacing: _spacing,
                runSpacing: 18,
                children: [
                  for (final f in state.friends)
                    _FriendTile(friend: f, width: tileWidth),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({required this.friend, required this.width});

  final Friend friend;
  final double width;

  @override
  Widget build(BuildContext context) {
    final online = friend.isOnline;
    final avatar = (width * 0.74).clamp(52.0, 96.0);

    return SizedBox(
      width: width,
      child: Tooltip(
        message: friend.details,
        waitDuration: const Duration(milliseconds: 500),
        child: Column(
          children: [
            SizedBox(
              height: avatar,
              child: Center(
                child: LetterAvatar(
                  letter: friend.initial,
                  size: online ? avatar : avatar * 0.88,
                  online: online,
                  showGameBadge: friend.state == PresenceState.playing,
                  imageUrl: friend.avatarUrl,
                  badgeImageUrl: friend.gameImageUrl,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              friend.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.label.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              friend.statusLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.body.copyWith(
                fontSize: 13,
                fontWeight: online ? FontWeight.w800 : FontWeight.w500,
                color: online ? AppColors.online : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscordCard extends StatelessWidget {
  const _DiscordCard();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.homeDiscordPresence,
                  style: context.cardTitle.copyWith(fontSize: 19),
                ),
                const SizedBox(height: 2),
                Text(
                  state.sharingLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.body,
                ),
              ],
            ),
          ),
          RoundIconButton(
            icon: Icons.settings_outlined,
            tooltip: S.homeSettingsTooltip,
            size: 48,
            onPressed: () => openSettings(context),
          ),
          const SizedBox(width: 12),
          RedSwitch(
            value: state.presenceEnabled,
            onChanged: state.setPresenceEnabled,
            semanticLabel: S.homeDiscordPresence,
          ),
        ],
      ),
    );
  }
}

class _ServicesCard extends StatelessWidget {
  const _ServicesCard();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final list = state.webServices;
    if (list.services.isEmpty) return const SizedBox.shrink();

    return AppCard(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            S.homeServicesTitle,
            style: context.cardTitle.copyWith(fontSize: 19),
          ),
          if (list.account == 'observer') ...[
            const SizedBox(height: 2),
            Text(S.homeServicesViaObserver, style: context.caption),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: list.services.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, i) => _ServiceTile(service: list.services[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.service});

  final WebServiceInfo service;

  Future<void> _open(BuildContext context, AppState state) async {
    final services = AppServicesScope.of(context);
    final session = await state.openWebService(service);
    if (!context.mounted) return;

    if (session == null) {
      if (state.webServiceError != null) {
        _showError(context, state.webServiceError!);
      }
      return;
    }

    try {
      await services.openWebService?.call(service, session);
    } catch (e) {
      if (context.mounted) {
        _showError(context, S.homeServicesFailed(name: service.name, error: e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final opening = state.openingService == service.id;
    final enabled = service.available && state.openingService == null;

    final fallback = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.raised, AppColors.thumbnail],
        ),
      ),
      child: Align(
        alignment: const Alignment(0.75, -0.55),
        child: Icon(
          _serviceIcon(service.name),
          size: 40,
          color: AppColors.accent.withValues(alpha: 0.7),
        ),
      ),
    );

    final tile = SizedBox(
      width: 260,
      height: 120,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.tile),
        child: Stack(
          fit: StackFit.expand,
          children: [
            service.imageUrl == null
                ? fallback
                : Image.network(
                    service.imageUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => fallback,
                    frameBuilder: (_, child, frame, sync) => AnimatedOpacity(
                      opacity: sync || frame != null ? 1 : 0,
                      duration: AppMotion.of(context, AppMotion.crossfade),
                      child: child,
                    ),
                  ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.35, 1],
                  colors: [Color(0x00000000), Color(0xD9000000)],
                ),
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    service.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.label.copyWith(
                      fontSize: 16,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    service.game,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.caption.copyWith(
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            if (opening)
              const ColoredBox(
                color: Color(0x66000000),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Opacity(
      opacity: service.available ? 1 : 0.45,
      child: Tooltip(
        message: service.available
            ? S.homeServicesOpen(name: service.name)
            : S.homeServicesNoAccount,
        waitDuration: const Duration(milliseconds: 500),
        child: FocusGlow(
          enabled: enabled,
          child: MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
            child: GestureDetector(
              onTap: enabled ? () => _open(context, state) : null,
              child: tile,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfilePanel extends StatelessWidget {
  const _ProfilePanel();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final profile = state.profile;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      clipBehavior: Clip.antiAlias,
      child: profile == null
          ? SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 26, 18, 18),
              child: _NoProfile(loading: state.loading),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 26, 18, 0),
                  child: _ProfileHeader(profile: profile),
                ),
                if (profile.recentGames.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 20, 18, 6),
                    child: Text(
                      S.homeRecentGames,
                      style: context.label.copyWith(
                        fontSize: 14,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      key: const Key('play-history'),
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                      itemCount: profile.recentGames.length,
                      itemBuilder: (_, i) =>
                          _RecentGameRow(game: profile.recentGames[i]),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    return Column(
      children: [
        LetterAvatar(
          letter: profile.avatarInitial,
          size: 104,
          online: profile.currentGame != null,
          imageUrl: profile.avatarUrl,
        ),
        const SizedBox(height: 12),
        Text(
          profile.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.cardTitle.copyWith(fontSize: 21),
        ),
        const SizedBox(height: 2),
        Text(
          profile.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.body,
        ),
        if (state.currentGameName != null) ...[
          const SizedBox(height: 18),
          _NowPlayingTile(
            game: state.currentGameName!,
            state: state,
            imageUrl: state.currentGameImage,
          ),
        ],
      ],
    );
  }
}

class _NowPlayingTile extends StatelessWidget {
  const _NowPlayingTile({
    required this.game,
    required this.state,
    this.imageUrl,
  });

  final String game;
  final AppState state;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(AppRadii.tile),
      ),
      child: Row(
        children: [
          CrossFade(
            child: GameThumbnail(
              // Keyed by game only, so a new image URL never replays the crossfade.
              key: ValueKey('art-$game'),
              size: 52,
              radius: 10,
              imageUrl: imageUrl,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CrossFade(
                  child: Text(
                    game,
                    key: ValueKey('title-$game'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.label.copyWith(fontSize: 15.5),
                  ),
                ),
                const SizedBox(height: 4),
                PopOnChange(
                  trigger: game,
                  child: LiveClock(
                    every: const Duration(seconds: 30),
                    builder: (context, now) => StatusBadge(
                      label: S.homeInGameFor(
                        duration: sessionLabel(
                          state.sessionElapsed()?.inMinutes ?? 0,
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
    );
  }
}

class _RecentGameRow extends StatelessWidget {
  const _RecentGameRow({required this.game});

  final RecentGame game;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
      child: Row(
        children: [
          GameThumbnail(size: 44, radius: 9, imageUrl: game.imageUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  game.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.label.copyWith(fontSize: 15),
                ),
                Text(game.detail, style: context.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoProfile extends StatelessWidget {
  const _NoProfile({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const LetterAvatar(letter: '?', size: 104),
        const SizedBox(height: 14),
        Text(
          loading ? S.commonLoading : S.homeNoWatched,
          style: context.cardTitle.copyWith(fontSize: 19),
        ),
        if (!loading) ...[
          const SizedBox(height: 6),
          Text(
            S.homeNoWatchedHint,
            textAlign: TextAlign.center,
            style: context.body,
          ),
        ],
      ],
    );
  }
}

class _BackendBanner extends StatelessWidget {
  const _BackendBanner();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final settings = state.settings;
    final offline = state.backendError;
    final message = switch (state.connection) {
      ConnectionStatus.reconnecting => S.homeReconnecting,
      ConnectionStatus.connecting when offline != null => S.homeBackendStarting,
      _ when offline != null && !state.embedded => S.homeBackendOfflineHint(
        error: offline,
      ),
      _ => offline ?? state.presenceError,
    };

    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final rollback = settings.offerRollback;
        if (message == null && !rollback) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.alert.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadii.tile),
              border: Border.all(color: AppColors.alert.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(
                  offline != null
                      ? Icons.cloud_off_rounded
                      : Icons.error_outline_rounded,
                  color: AppColors.text,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message ?? S.homeConnectionLostAfterSave,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: context.label.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                if (rollback) ...[
                  PillButton(
                    label: S.homeRollback,
                    compact: true,
                    busy: settings.rollingBack,
                    onPressed: settings.rollback,
                  ),
                  const SizedBox(width: 8),
                ],
                PillButton(label: S.commonRetry, onPressed: state.refresh),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar();

  @override
  Widget build(BuildContext context) {
    final updates = AppServicesScope.of(context).updates;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _GitHubButton(),
        if (updates != null) ...[
          const SizedBox(width: 12),
          UpdateBadge(controller: updates),
        ],
      ],
    );
  }
}

class _GitHubButton extends StatelessWidget {
  const _GitHubButton();

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (await openExternalUrl(AppLinks.repositoryUrl)) return;

    messenger.showSnackBar(
      SnackBar(content: Text(S.commonCannotOpen(url: AppLinks.repositoryUrl))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RoundIconButton(
      tooltip: S.homeGithubTooltip,
      size: 44,
      onPressed: () => _open(context),
      child: const FaIcon(
        FontAwesomeIcons.github,
        color: AppColors.text,
        size: 20,
      ),
    );
  }
}
