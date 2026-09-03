/// What the handset knows about the office, and how to make it current.
///
/// One screen, because at a fair the question is never "what is my sync state",
/// it is "am I about to quote the wrong price" and "did that order reach the
/// office". Everything here answers one of those two.
///
/// Nothing on this screen is required. A handset that never opens it still
/// quotes, prices, prints and takes a deposit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../data/rate_card_store.dart';
import '../../l10n/app_localizations.dart';
import '../../sync/api_client.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';
import '../quote/quote_state.dart';
import 'sign_in_screen.dart';

/// Where the handset's copy of the price list came from. Watched by both this
/// screen and the rates screen.
final provenanceProvider = FutureProvider<RateCardProvenance>((ref) async {
  final active = await ref.watch(activeRateCardProvider.future);
  return ref.watch(rateCardStoreProvider).provenance(active.list);
});

class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final credentials = ref.watch(credentialsProvider).valueOrNull;
    final status = ref.watch(syncProvider);
    final queued = ref.watch(outboxDepthProvider).valueOrNull ?? 0;

    return Scaffold(
      appBar: AppBar(title: Text(l.syncTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          if (credentials == null)
            _SignedOutCard(
              onSignIn: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SignInScreen()),
              ),
            )
          else
            _SignedInCard(credentials: credentials),

          const SizedBox(height: Space.xl),
          const _PricesLine(),

          const SizedBox(height: Space.lg),
          // The queue depth, always visible. A part-timer who can see "3
          // waiting" understands a dead connection; one who cannot assumes the
          // orders are gone.
          if (queued > 0)
            _Note(text: l.syncQueued(queued), tone: _Tone.neutral),

          if (status.offline) _Note(text: l.syncOffline, tone: _Tone.neutral),
          if (status.signedOut) _Note(text: l.syncSignedOut, tone: _Tone.alarm),
          if (status.discardedLocalEdit)
            _Note(text: l.syncLocalEditDropped, tone: _Tone.warning),
          if (status.quotesParked > 0)
            _Note(text: l.syncParked(status.quotesParked), tone: _Tone.alarm),
          if (status.disagreements > 0)
            _Note(
              text: l.syncDisagreed(status.disagreements),
              tone: _Tone.warning,
            ),

          const SizedBox(height: Space.xl),
          FilledButton.icon(
            onPressed: credentials == null || status.running
                ? null
                : () => ref.read(syncProvider.notifier).syncNow(),
            icon: status.running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(status.running ? l.syncRunning : l.syncNow),
          ),

          const SizedBox(height: Space.xxl),
          _FairMode(enabled: credentials != null && !status.running),
        ],
      ),
    );
  }
}

class _SignedOutCard extends StatelessWidget {
  final VoidCallback onSignIn;
  const _SignedOutCard({required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.notSignedIn, style: AppText.caption),
        const SizedBox(height: Space.md),
        FilledButton(onPressed: onSignIn, child: Text(l.signInAction)),
      ],
    );
  }
}

class _SignedInCard extends ConsumerWidget {
  final Credentials credentials;
  const _SignedInCard({required this.credentials});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final status = ref.watch(syncProvider);
    final last = status.lastSuccessAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.signedInAs(
            credentials.user.name,
            roleLabel(l, credentials.user.role),
          ),
          style: AppText.bodyStrong,
        ),
        const SizedBox(height: Space.xs),
        Text(
          last == null ? l.syncNever : l.syncLastAt(formatDateTime(last)),
          style: AppText.caption,
        ),
        const SizedBox(height: Space.md),
        TextButton(
          onPressed: () => ref.read(credentialsProvider.notifier).signOut(),
          child: Text(l.signOut),
        ),
      ],
    );
  }
}

/// Where today's prices came from, in one line.
///
/// Offline, the honest answer to "are these current?" is *when they were last
/// known to be* — never a claim that they are.
class _PricesLine extends ConsumerWidget {
  const _PricesLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L.of(context);
    final held = ref.watch(provenanceProvider).valueOrNull;
    if (held == null) return const SizedBox.shrink();

    final (text, tone) = switch (held.origin) {
      RateCardOrigin.server => (
        l.pricesFromServer(
          held.fetchedAt == null ? '' : formatDateTime(held.fetchedAt!),
        ),
        _Tone.neutral,
      ),
      RateCardOrigin.bundled => (l.pricesBundled, _Tone.neutral),
      RateCardOrigin.local => (l.pricesLocal, _Tone.warning),
    };
    return _Note(text: text, tone: tone);
  }
}

/// The deliberate before-you-leave step.
///
/// A fair is four days where the connection is somebody else's guest wifi.
/// Doing this in the office, on purpose, is the difference between that being
/// fine and it being a problem nobody can fix at the venue.
class _FairMode extends ConsumerStatefulWidget {
  final bool enabled;
  const _FairMode({required this.enabled});

  @override
  ConsumerState<_FairMode> createState() => _FairModeState();
}

class _FairModeState extends ConsumerState<_FairMode> {
  bool? _ready;

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.fairModeTitle, style: AppText.bodyStrong),
        const SizedBox(height: Space.xs),
        Text(l.fairModeWhy, style: AppText.caption),
        const SizedBox(height: Space.md),
        OutlinedButton.icon(
          onPressed: widget.enabled ? _prepare : null,
          icon: const Icon(Icons.download_for_offline_outlined),
          label: Text(l.fairModePrepare),
        ),
        if (_ready case final ready?) ...[
          const SizedBox(height: Space.md),
          _Note(
            text: ready ? l.fairModeReady : l.fairModeNotReady,
            tone: ready ? _Tone.good : _Tone.alarm,
          ),
        ],
      ],
    );
  }

  Future<void> _prepare() async {
    final status = await ref.read(syncProvider.notifier).prepareForFair();
    final queued = await ref.read(databaseProvider).pendingOutbox();
    if (!mounted) return;
    // Ready means both lists are current *and* nothing is still waiting. A
    // handset that leaves with a queue is a handset carrying orders the office
    // does not know about.
    setState(() => _ready = status.lastFailure == null && queued.isEmpty);
  }
}

enum _Tone { neutral, good, warning, alarm }

class _Note extends StatelessWidget {
  final String text;
  final _Tone tone;

  const _Note({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (tone) {
      _Tone.neutral => (AppColors.muted, AppColors.mutedForeground),
      _Tone.good => (AppColors.muted, AppColors.accent),
      _Tone.warning => (AppColors.warningSurface, AppColors.warning),
      _Tone.alarm => (AppColors.alarmSurface, AppColors.alarm),
    };

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Space.sm),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(text, style: AppText.caption.copyWith(color: foreground)),
    );
  }
}

/// Roles are shown in the reader's own language, like everything else.
String roleLabel(L l, String role) => switch (role) {
  'admin' => l.roleAdmin,
  'staff' => l.roleStaff,
  _ => l.roleParttime,
};
