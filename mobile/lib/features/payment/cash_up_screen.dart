/// End of day. SPEC.md §6.4.
///
/// > Per user: expected total by method versus what they actually hold. Small
/// > to build, catches most of what goes wrong with cash at a fair.
///
/// The screen's whole job is to make one number easy to say out loud: *"I
/// should have RM900 and I have RM850."* Everything else is arrangement.
///
/// It never reports a day as balanced because nobody counted. An uncounted
/// method is shown as an open question, because "nobody checked" and "checked
/// and it was wrong" need different conversations.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/money.dart';
import '../../l10n/app_localizations.dart';
import '../../pricing/cash_up.dart';
import '../../ui/theme.dart';
import '../quote/quote_state.dart';
import 'payment_method_sheet.dart';

class CashUpScreen extends ConsumerStatefulWidget {
  const CashUpScreen({super.key});

  @override
  ConsumerState<CashUpScreen> createState() => _CashUpScreenState();
}

class _CashUpScreenState extends ConsumerState<CashUpScreen> {
  /// What the person says they are holding, per method. Kept in memory: it is
  /// a count taken once at the end of a shift, not a record of anything.
  final Map<PaymentMethod, Money> _counted = {};

  CashUp? _day;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final day = await ref
        .read(paymentRepositoryProvider)
        .cashUp(ref.read(todayProvider), counted: Map.of(_counted));
    if (mounted) setState(() => _day = day);
  }

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);
    final day = _day;

    return Scaffold(
      appBar: AppBar(title: Text(l.cashUpTitle)),
      body: day == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Space.lg),
              children: [
                Text(
                  formatDate(ref.read(todayProvider)),
                  style: AppText.caption,
                ),
                const SizedBox(height: Space.lg),

                if (day.byMethod.isEmpty)
                  Text(l.cashUpNothingTaken, style: AppText.body)
                else ...[
                  for (final total in day.byMethod)
                    _MethodRow(
                      total: total,
                      onCount: (amount) {
                        setState(() {
                          if (amount == null) {
                            _counted.remove(total.method);
                          } else {
                            _counted[total.method] = amount;
                          }
                        });
                        _reload();
                      },
                    ),

                  const Divider(height: Space.xxl),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.cashUpExpected,
                          style: AppText.bodyStrong,
                        ),
                      ),
                      Text(day.expectedTotal.format(), style: AppText.money),
                    ],
                  ),

                  if (day.uncounted.isNotEmpty) ...[
                    const SizedBox(height: Space.lg),
                    _Note(
                      text: l.cashUpNotCounted(day.uncounted.length),
                      tone: _Tone.warning,
                    ),
                  ],
                  if (day.anyDiscrepancy) ...[
                    const SizedBox(height: Space.sm),
                    for (final off in day.discrepancies)
                      _Note(
                        text: l.cashUpOff(
                          paymentMethodLabel(l, off.method),
                          Money.sen(off.variance!.sen.abs()).format(),
                          off.variance!.sen < 0 ? l.cashUpShort : l.cashUpOver,
                        ),
                        tone: _Tone.alarm,
                      ),
                  ],
                  if (!day.anyDiscrepancy && day.uncounted.isEmpty) ...[
                    const SizedBox(height: Space.lg),
                    _Note(text: l.cashUpBalanced, tone: _Tone.good),
                  ],
                ],
              ],
            ),
    );
  }
}

class _MethodRow extends StatelessWidget {
  final MethodTotal total;
  final void Function(Money?) onCount;

  const _MethodRow({required this.total, required this.onCount});

  @override
  Widget build(BuildContext context) {
    final l = L.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(paymentMethodLabel(l, total.method), style: AppText.body),
                if (total.variance case final off? when off.sen != 0)
                  Text(
                    off.sen < 0
                        ? '${l.cashUpShort} ${Money.sen(-off.sen).format()}'
                        : '${l.cashUpOver} ${off.format()}',
                    style: AppText.caption.copyWith(color: AppColors.alarm),
                  ),
              ],
            ),
          ),
          Text(total.expected.format(), style: AppText.money),
          const SizedBox(width: Space.md),
          SizedBox(
            width: 120,
            child: TextField(
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                isDense: true,
                hintText: l.cashUpCounted,
              ),
              onChanged: (text) {
                if (text.trim().isEmpty) {
                  onCount(null);
                  return;
                }
                final amount = Money.tryParse(text);
                if (amount != null) onCount(amount);
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum _Tone { good, warning, alarm }

class _Note extends StatelessWidget {
  final String text;
  final _Tone tone;

  const _Note({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (tone) {
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
