/// Signing a handset in. Once, before the fair.
///
/// Deliberately not a gate. The app opens straight into the quote screen with
/// no session at all, because CLAUDE.md rule 9 makes offline the default and a
/// login wall would make a dead connection into a day with no quoting. Signing
/// in buys two things — the office's prices, and finished quotes reaching the
/// office — and nothing else stops working without it.
///
/// Phone plus PIN rather than a name picked from a list: a roster on this
/// screen would hand the staff list to anyone who opens the app, and these
/// handsets travel to fairs.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../sync/api_client.dart';
import '../../sync/server_config.dart';
import '../../sync/sync_state.dart';
import '../../ui/theme.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _phone = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.signInTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Text(l.signInWhy, style: AppText.caption),
          const SizedBox(height: Space.xl),

          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: InputDecoration(labelText: l.signInPhone),
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            // Digits only, matched to what the server will accept, so a typo
            // is caught here rather than as a failed sign-in.
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(12),
            ],
            decoration: InputDecoration(labelText: l.signInPin),
            onSubmitted: (_) => _submit(),
          ),

          if (_error case final message?) ...[
            const SizedBox(height: Space.lg),
            Container(
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: AppColors.alarmSurface,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                message,
                style: AppText.caption.copyWith(color: AppColors.alarm),
              ),
            ),
          ],

          const SizedBox(height: Space.xl),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(l.signInAction),
          ),

          const SizedBox(height: Space.xxl),
          const _ServerAddressField(),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final l = L.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await ref
        .read(credentialsProvider.notifier)
        .signIn(phone: _phone.text.trim(), pin: _pin.text);

    if (!mounted) return;
    switch (result) {
      case SyncOk():
        // Straight into a sync. The point of signing in is the office's
        // prices, and making someone find a second button for them is a way to
        // quote from a stale card all afternoon.
        unawaited(ref.read(syncProvider.notifier).syncNow());
        navigator.pop();
      case SyncFailed(:final failure, :final detail):
        setState(() {
          _busy = false;
          _error = switch (failure) {
            SyncFailure.offline => l.signInOffline,
            // The server sends Retry-After; the detail carries the seconds.
            SyncFailure.serverError when detail.contains('429') => l.signInBusy(
              _secondsIn(detail),
            ),
            _ => l.signInFailed,
          };
        });
    }
  }
}

/// Pulls the wait out of a 429 body, defaulting to a minute — the cap the
/// server uses.
int _secondsIn(String detail) =>
    int.tryParse(RegExp(r'(\d+)s').firstMatch(detail)?.group(1) ?? '') ?? 60;

/// Which server this handset talks to.
///
/// On the sign-in screen because it has to be changeable *before* anyone can
/// sign in — the same APK goes on a demo phone, a staging box and the client's
/// own VPS.
class _ServerAddressField extends ConsumerStatefulWidget {
  const _ServerAddressField();

  @override
  ConsumerState<_ServerAddressField> createState() =>
      _ServerAddressFieldState();
}

class _ServerAddressFieldState extends ConsumerState<_ServerAddressField> {
  final _controller = TextEditingController();
  bool _editing = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final config = ref.watch(serverConfigProvider).valueOrNull;
    final host = config?.baseUrl.host ?? '';

    if (!_editing) {
      return TextButton(
        onPressed: () {
          _controller.text = host;
          setState(() => _editing = true);
        },
        child: Text('${l.serverAddress}: $host', style: AppText.caption),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l.serverAddress,
            errorText: _error,
          ),
        ),
        const SizedBox(height: Space.sm),
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() => _editing = false),
              child: Text(l.cancel),
            ),
            const Spacer(),
            FilledButton(onPressed: _save, child: Text(l.done)),
          ],
        ),
      ],
    );
  }

  Future<void> _save() async {
    final l = L.of(context);
    // https only, and refused rather than warned about: a PIN and a
    // non-expiring token cross this connection, and a fair's wifi is a
    // stranger's wifi.
    final url = ServerConfig.parse(_controller.text);
    if (url == null) {
      setState(() => _error = l.serverAddressInvalid);
      return;
    }
    await ref.read(serverConfigProvider.notifier).setBaseUrl(url);
    if (mounted) setState(() => _editing = false);
  }
}
