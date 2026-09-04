/// The order status pipeline, SPEC.md §6.3.
///
/// The transition cases live in `shared/pricing-fixtures.json` and are loaded
/// by both suites. This file additionally asserts the shape of the machine —
/// that the enum matches the spec, that every status is reachable, and that the
/// pipeline has no way out other than the two terminals — because a fixture
/// list can only test the transitions somebody remembered to write down.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/pricing/einvoice_threshold.dart';
import 'package:milan_quote/pricing/order_status.dart';

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
    cases = json['order_status_cases'] as List<dynamic>;
  });

  group('the shared contract', () {
    test('carries cases at all', () {
      // A fixture file that silently lost its cases would turn this whole file
      // green while testing nothing.
      expect(cases.length, greaterThanOrEqualTo(20));
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
        StatusRefusal.values.map((r) => r.wire).toSet(),
        reason: 'a refusal nothing exercises is a refusal nobody has checked',
      );
    });

    test('every allowed edge of the pipeline is exercised', () {
      final covered = cases
          .where(
            (c) => (c as Map<String, dynamic>)['expect']['allowed'] == true,
          )
          .map((c) {
            final m = c as Map<String, dynamic>;
            return '${m['from']}->${m['to']}';
          })
          .toSet();

      // Cancellation is reachable from six places; one worked example of it is
      // enough here, so it is excluded and checked on its own below.
      final forward = <String>{
        'confirmed->measurement_booked',
        'measurement_booked->measured',
        'measured->material_selected',
        'material_selected->in_production',
        'in_production->ready',
        'ready->installed',
        'installed->closed',
      };
      expect(covered.intersection(forward), forward);
    });

    test('the fixtures agree with the machine', () {
      for (final raw in cases) {
        final c = raw as Map<String, dynamic>;
        final expected = c['expect'] as Map<String, dynamic>;

        final result = advanceOrder(
          from: OrderStatus.fromWire(c['from'] as String),
          to: OrderStatus.fromWire(c['to'] as String),
          reason: c['reason'] as String?,
          lines: (c['lines'] as List<dynamic>)
              .map(
                (l) => OrderLineState(
                  needsMeasuring: (l as Map)['needs_measuring'] as bool,
                  hasFinalDimensions: l['has_final_dimensions'] as bool,
                  materialDeferred: l['material_deferred'] as bool,
                  materialChosen: l['material_chosen'] as bool,
                ),
              )
              .toList(),
          // Two separate fields because they differ: an order inside the
          // RM8,000 fair margin is asked about but not stopped. Absent means
          // false, which is what every case written before the RM10,000 guard
          // existed means: nothing to capture.
          threshold: ThresholdCheck(
            mustCapture:
                c['threshold_captures'] as bool? ??
                c['threshold_blocks'] as bool? ??
                false,
            blocksAdvance: c['threshold_blocks'] as bool? ?? false,
          ),
        );

        final why = '${c['id']} — ${c['why']}';
        expect(result.isAllowed, expected['allowed'], reason: why);
        if (expected['allowed'] as bool) {
          expect(result.to!.wire, c['to'], reason: why);
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

  group('the shape of the machine', () {
    test('the statuses are the ones SPEC.md §6.3 names', () {
      // Asserted as a literal list, not derived from the enum, so that adding
      // or renaming a status is a decision somebody has to make twice.
      expect(OrderStatus.values.map((s) => s.wire), [
        'confirmed',
        'measurement_booked',
        'measured',
        'material_selected',
        'in_production',
        'ready',
        'installed',
        'closed',
        'cancelled',
      ]);
    });

    test('an unknown status raises rather than defaulting', () {
      // A silent default puts a real order in the wrong column of every
      // report. Better to fail on the row than to be quietly wrong about it.
      expect(
        () => OrderStatus.fromWire('awaiting_paint'),
        throwsA(isA<UnknownOrderStatus>()),
      );
      expect(
        () => OrderStatus.fromWire(''),
        throwsA(isA<UnknownOrderStatus>()),
      );
    });

    test('the transition table and isTerminal say the same thing', () {
      // Two mechanisms express one rule: the empty table entries, and the
      // early answer of `terminal`. The early answer wins, which makes the
      // entries unreachable — so nothing but this would notice if one of them
      // grew an edge.
      for (final s in OrderStatus.values) {
        expect(
          allowedFrom(s).isEmpty,
          s.isTerminal,
          reason: '$s: the table and isTerminal disagree',
        );
      }
    });

    test('allowedFrom lists the edges without judging the guards', () {
      expect(allowedFrom(OrderStatus.confirmed), {
        OrderStatus.measurementBooked,
        OrderStatus.cancelled,
      });
      expect(allowedFrom(OrderStatus.installed), {OrderStatus.closed});
      expect(allowedFrom(OrderStatus.closed), isEmpty);
    });

    test('exactly two statuses are terminal', () {
      expect(OrderStatus.values.where((s) => s.isTerminal).toSet(), {
        OrderStatus.closed,
        OrderStatus.cancelled,
      });
    });

    test('nothing moves out of a terminal status', () {
      for (final terminal in [OrderStatus.closed, OrderStatus.cancelled]) {
        for (final to in OrderStatus.values) {
          final result = advanceOrder(
            from: terminal,
            to: to,
            lines: const [],
            reason: 'a perfectly good reason',
          );
          expect(result.isAllowed, isFalse, reason: '$terminal -> $to');
        }
      }
    });

    test('every status is reachable from confirmed', () {
      // A status nothing can reach is a column in a report that stays empty
      // forever while looking like it means something.
      final seen = <OrderStatus>{OrderStatus.confirmed};
      final queue = <OrderStatus>[OrderStatus.confirmed];
      const everythingDone = OrderLineState(
        needsMeasuring: true,
        hasFinalDimensions: true,
        materialDeferred: true,
        materialChosen: true,
      );

      while (queue.isNotEmpty) {
        final from = queue.removeLast();
        for (final to in OrderStatus.values) {
          if (seen.contains(to)) continue;
          final result = advanceOrder(
            from: from,
            to: to,
            lines: const [everythingDone],
            reason: 'a perfectly good reason',
          );
          if (result.isAllowed) {
            seen.add(to);
            queue.add(to);
          }
        }
      }

      expect(seen, OrderStatus.values.toSet());
    });

    test('the pipeline walks straight through without cancelling', () {
      var at = OrderStatus.confirmed;
      const done = OrderLineState(
        needsMeasuring: true,
        hasFinalDimensions: true,
        materialDeferred: true,
        materialChosen: true,
      );
      final walked = <OrderStatus>[at];

      while (nextInPipeline(at) != null) {
        final next = nextInPipeline(at)!;
        final result = advanceOrder(from: at, to: next, lines: const [done]);
        expect(result.isAllowed, isTrue, reason: '$at -> $next');
        at = result.to!;
        walked.add(at);
      }

      expect(walked, OrderStatus.pipeline);
      expect(at, OrderStatus.closed);
    });

    test('nextInPipeline stops at the end and ignores cancelled', () {
      expect(nextInPipeline(OrderStatus.closed), isNull);
      // Cancelled is a branch off the side, not a stage, so it has no next.
      expect(nextInPipeline(OrderStatus.cancelled), isNull);
      expect(nextInPipeline(OrderStatus.ready), OrderStatus.installed);
    });
  });

  group('the guards', () {
    const unmeasured = OrderLineState(
      needsMeasuring: true,
      hasFinalDimensions: false,
      materialDeferred: false,
      materialChosen: false,
    );
    const stillDeferring = OrderLineState(
      needsMeasuring: false,
      hasFinalDimensions: false,
      materialDeferred: true,
      materialChosen: false,
    );

    test('a line that needs no measuring never blocks measured', () {
      // Otherwise a supply-only line would hold up an order forever, and the
      // measurer would have nothing to do about it.
      final result = advanceOrder(
        from: OrderStatus.measurementBooked,
        to: OrderStatus.measured,
        lines: const [
          OrderLineState(
            needsMeasuring: false,
            hasFinalDimensions: false,
            materialDeferred: false,
            materialChosen: false,
          ),
        ],
      );
      expect(result.isAllowed, isTrue);
    });

    test('the measured guard does not leak onto other transitions', () {
      // An unmeasured line must not stop the order being cancelled, or being
      // booked in for the very visit that would measure it.
      for (final to in [OrderStatus.measurementBooked]) {
        expect(
          advanceOrder(
            from: OrderStatus.confirmed,
            to: to,
            lines: const [unmeasured],
          ).isAllowed,
          isTrue,
          reason: 'confirmed -> $to with an unmeasured line',
        );
      }
      expect(
        advanceOrder(
          from: OrderStatus.confirmed,
          to: OrderStatus.cancelled,
          lines: const [unmeasured],
          reason: 'customer changed their mind',
        ).isAllowed,
        isTrue,
      );
    });

    test('the material guard does not leak onto other transitions', () {
      // A deferred material is the normal state of every line at confirmation
      // (§13 B7). If this guard fired anywhere but material_selected, no order
      // would ever get its measurement booked.
      expect(
        advanceOrder(
          from: OrderStatus.confirmed,
          to: OrderStatus.measurementBooked,
          lines: const [stillDeferring],
        ).isAllowed,
        isTrue,
      );
      expect(
        advanceOrder(
          from: OrderStatus.materialSelected,
          to: OrderStatus.inProduction,
          lines: const [stillDeferring],
        ).isAllowed,
        isTrue,
        reason:
            'past material_selected the guard has already been satisfied once; '
            'refiring it here would deadlock the order',
      );
    });

    test('one bad line among many is enough to refuse', () {
      const good = OrderLineState(
        needsMeasuring: true,
        hasFinalDimensions: true,
        materialDeferred: true,
        materialChosen: true,
      );
      expect(
        advanceOrder(
          from: OrderStatus.measurementBooked,
          to: OrderStatus.measured,
          lines: const [good, good, unmeasured, good],
        ).refusedBecause,
        StatusRefusal.linesNotMeasured,
      );
      expect(
        advanceOrder(
          from: OrderStatus.measured,
          to: OrderStatus.materialSelected,
          lines: const [good, good, stillDeferring],
        ).refusedBecause,
        StatusRefusal.materialNotChosen,
      );
    });

    test('an order with no lines passes both guards', () {
      for (final (from, to) in [
        (OrderStatus.measurementBooked, OrderStatus.measured),
        (OrderStatus.measured, OrderStatus.materialSelected),
      ]) {
        expect(
          advanceOrder(from: from, to: to, lines: const []).isAllowed,
          isTrue,
          reason: '$from -> $to',
        );
      }
    });
  });

  group('cancelling', () {
    const line = OrderLineState(
      needsMeasuring: true,
      hasFinalDimensions: false,
      materialDeferred: true,
      materialChosen: false,
    );

    test('four trimmed characters is the bar, and it is exactly four', () {
      String? refusal(String? reason) => advanceOrder(
        from: OrderStatus.confirmed,
        to: OrderStatus.cancelled,
        lines: const [line],
        reason: reason,
      ).refusedBecause?.wire;

      expect(refusal('lost'), isNull);
      expect(refusal('  lost  '), isNull, reason: 'trimmed, then measured');
      expect(refusal('los'), 'no_reason');
      expect(refusal('   lost'), isNull);
      expect(refusal('  a  '), 'no_reason');
      expect(refusal(null), 'no_reason');
      expect(minReasonLength, 4);
    });

    test('a reason is not asked for on any other transition', () {
      // Only cancellation needs one. Requiring it everywhere would put a
      // dialog in front of the measurer six times a day.
      const done = OrderLineState(
        needsMeasuring: true,
        hasFinalDimensions: true,
        materialDeferred: true,
        materialChosen: true,
      );
      expect(
        advanceOrder(
          from: OrderStatus.ready,
          to: OrderStatus.installed,
          lines: const [done],
        ).isAllowed,
        isTrue,
      );
    });

    test('the reason is not checked before the transition itself', () {
      // installed -> cancelled is refused because it is not an edge, not
      // because of the reason. Reporting "no reason" there would send somebody
      // off to write a better one for a move that will never be allowed.
      expect(
        advanceOrder(
          from: OrderStatus.installed,
          to: OrderStatus.cancelled,
          lines: const [line],
          reason: '',
        ).refusedBecause,
        StatusRefusal.notATransition,
      );
    });
  });

  test('staying put is distinguishable from being refused', () {
    // The screen shows nothing for already_there and an error for the rest, so
    // collapsing them would put an error in front of somebody who tapped twice.
    final result = advanceOrder(
      from: OrderStatus.ready,
      to: OrderStatus.ready,
      lines: const [],
    );
    expect(result.isAllowed, isFalse);
    expect(result.refusedBecause, StatusRefusal.alreadyThere);
  });

  test('a wire refusal round trips', () {
    for (final r in StatusRefusal.values) {
      expect(StatusRefusal.fromWire(r.wire), r);
    }
  });
}
