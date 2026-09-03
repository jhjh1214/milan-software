/// Price override, SPEC.md §6.5.
///
/// The cases live in `shared/pricing-fixtures.json` and both suites load them.
/// What is added here is the ordering of the checks and the shape of the audit
/// row, because §6.5 puts the entire control on that row being written and
/// being readable a week later:
///
/// > The real control is the audit log plus a weekly review screen, not the
/// > gate.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/core/money.dart';
import 'package:milan_quote/pricing/price_override.dart';

void main() {
  late List<dynamic> cases;

  setUpAll(() {
    var dir = Directory.current;
    while (!File('${dir.path}/shared/pricing-fixtures.json').existsSync()) {
      dir = dir.parent;
    }
    final json =
        jsonDecode(
              File(
                '${dir.path}/shared/pricing-fixtures.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    cases = json['price_override_cases'] as List<dynamic>;
  });

  OverrideDecision ask({
    int before = 55200,
    int after = 50000,
    String? reason = 'matched a competitor quote',
    String? adminUserId = 'u-boss',
    bool isAdmin = true,
    bool orderIsTerminal = false,
  }) => overrideLinePrice(
    before: Money.sen(before),
    after: Money.sen(after),
    reason: reason,
    adminUserId: adminUserId,
    isAdmin: isAdmin,
    orderIsTerminal: orderIsTerminal,
  );

  group('the shared contract', () {
    test('carries cases at all', () {
      expect(cases.length, greaterThanOrEqualTo(10));
    });

    test('every refusal reason is exercised', () {
      final covered = cases
          .map(
            (c) =>
                (c as Map<String, dynamic>)['expect']['refused_because']
                    as String?,
          )
          .whereType<String>()
          .toSet();
      expect(
        covered,
        OverrideRefusal.values.map((r) => r.wire).toSet(),
        reason: 'a refusal nothing exercises is a refusal nobody has checked',
      );
    });

    test('the fixtures agree with the rule', () {
      for (final raw in cases) {
        final c = raw as Map<String, dynamic>;
        final expected = c['expect'] as Map<String, dynamic>;

        final result = overrideLinePrice(
          before: Money.sen(c['before_sen'] as int),
          after: Money.sen(c['after_sen'] as int),
          reason: c['reason'] as String?,
          adminUserId: c['admin_user_id'] as String?,
          isAdmin: c['is_admin'] as bool,
          orderIsTerminal: c['order_is_terminal'] as bool,
        );

        final why = '${c['id']} — ${c['why']}';
        expect(result.isApplied, expected['applied'], reason: why);
        if (expected['applied'] as bool) {
          expect(result.record!.after.sen, expected['after_sen'], reason: why);
        } else {
          expect(
            result.refusedBecause!.wire,
            expected['refused_because'],
            reason: why,
          );
        }
      }
    });
  });

  group('the audit row', () {
    test('names the person, and carries both numbers', () {
      // Without all three the weekly review cannot answer the only questions
      // it exists to answer: who, how much, and why.
      final record = ask(before: 55200, after: 50000).record!;
      expect(record.adminUserId, 'u-boss');
      expect(record.before, const Money.sen(55200));
      expect(record.after, const Money.sen(50000));
      expect(record.reason, 'matched a competitor quote');
    });

    test('stores the reason trimmed, not as typed', () {
      // Leading spaces from a soft keyboard would sort a row away from its
      // neighbours in the review, and the padding says nothing.
      final record = ask(reason: '   damp wall   ').record!;
      expect(record.reason, 'damp wall');
    });

    test('the delta is signed the way the money moved', () {
      expect(ask(before: 55200, after: 50000).record!.delta.sen, -5200);
      expect(ask(before: 50000, after: 55200).record!.delta.sen, 5200);
    });

    test('an override to zero is a real record, not an empty one', () {
      // A write-off is the case the review most needs to surface.
      final record = ask(after: 0, reason: 'remake at our cost').record!;
      expect(record.after, Money.zero);
      expect(record.delta.sen, -55200);
    });
  });

  group('the order of the checks', () {
    test('authority comes before everything else', () {
      // Somebody who may not do this at all should be told that, not sent off
      // to write a longer reason for a refusal that is already certain.
      expect(
        ask(isAdmin: false, reason: '', after: -1).refusedBecause,
        OverrideRefusal.notAnAdmin,
      );
      expect(
        ask(adminUserId: null, reason: '', after: -1).refusedBecause,
        OverrideRefusal.notAnAdmin,
      );
    });

    test('a finished order is refused before the reason is read', () {
      // Same reasoning one step down. The reason cannot rescue it.
      expect(
        ask(orderIsTerminal: true, reason: '').refusedBecause,
        OverrideRefusal.orderFinished,
      );
    });

    test('an empty user id counts as nobody', () {
      // A blank string is what an unset field arrives as, and it names no more
      // of a person than null does.
      expect(ask(adminUserId: '').refusedBecause, OverrideRefusal.notAnAdmin);
    });
  });

  group('the bar on the reason', () {
    test('is four characters after trimming, at both edges', () {
      expect(ask(reason: 'damp').isApplied, isTrue);
      expect(ask(reason: 'dam').refusedBecause, OverrideRefusal.noReason);
      expect(ask(reason: '  damp  ').isApplied, isTrue);
      expect(ask(reason: '   a   ').refusedBecause, OverrideRefusal.noReason);
      expect(ask(reason: null).refusedBecause, OverrideRefusal.noReason);
      expect(ask(reason: '').refusedBecause, OverrideRefusal.noReason);
      expect(minReasonLength, 4);
    });
  });

  group('what it will not do', () {
    test('a negative total is not a price', () {
      // A refund is a payment of kind refund (§6.4), not a line that costs less
      // than nothing.
      expect(ask(after: -1).refusedBecause, OverrideRefusal.negativeTotal);
      expect(ask(after: -55200).refusedBecause, OverrideRefusal.negativeTotal);
    });

    test('zero is allowed, and is not confused with negative', () {
      expect(ask(after: 0).isApplied, isTrue);
    });

    test('changing nothing writes nothing', () {
      // A row saying RM552 became RM552 is noise, and noise is what stops the
      // weekly review being read at all.
      expect(
        ask(before: 55200, after: 55200).refusedBecause,
        OverrideRefusal.noChange,
      );
      expect(ask(before: 0, after: 0).refusedBecause, OverrideRefusal.noChange);
    });

    test('a one sen move is a change', () {
      // The no-op check is equality, not a tolerance. A tolerance would let
      // small corrections through unrecorded, and small is where they hide.
      expect(ask(before: 55200, after: 55201).isApplied, isTrue);
      expect(ask(before: 55200, after: 55199).isApplied, isTrue);
    });
  });

  test('a wire refusal round trips', () {
    for (final r in OverrideRefusal.values) {
      expect(OverrideRefusal.fromWire(r.wire), r);
    }
  });
}
