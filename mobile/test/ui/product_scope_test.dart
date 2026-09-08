import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/pricing/models.dart';

/// What each product asks for, and what it offers on top.
///
/// Two separate questions, both about a part-timer standing in a room:
///
/// * **What is the second dimension called?** §5.2. A floor lies flat and has
///   a LENGTH. Asking for its "height" invites somebody to type the wall,
///   which is a plausible number and the wrong one.
/// * **What may be added to it?** §4.1. An upgrade offered on a product it
///   cannot belong to is a wrong line somebody taps by mistake, and every one
///   of these is money: RM400 of stainless steel cable on a curtain.
void main() {
  late RateCard card;

  setUpAll(() {
    var dir = Directory.current;
    while (!File(
      '${dir.path}/shared/rate-card-fair-2026-08.json',
    ).existsSync()) {
      dir = dir.parent;
    }
    card = RateCard.fromJson(
      jsonDecode(
            File(
              '${dir.path}/shared/rate-card-fair-2026-08.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>,
    );
  });

  PricingRule ruleFor(String id) => card.rules.firstWhere((r) => r.id == id);

  List<String> upgradeIdsFor(String parentId) =>
      card.upgradesFor(ruleFor(parentId)).map((r) => r.id).toList();

  group('what the second dimension is called', () {
    test('a floor has a length, never a height', () {
      // §5.2, and it is the whole reason SecondDimension exists.
      expect(secondDimensionOf(Family.flooring), SecondDimension.length);
    });

    test('a curtain and a blind have a drop', () {
      expect(secondDimensionOf(Family.curtain), SecondDimension.drop);
      expect(secondDimensionOf(Family.blind), SecondDimension.drop);
    });

    test('wallpaper covers a wall, so it really is a height', () {
      expect(secondDimensionOf(Family.wallpaper), SecondDimension.height);
    });
  });

  group('what may be added on top', () {
    test('tracks are offered on a curtain', () {
      // A16: the curtain rate covers the fabric and the standard track. Every
      // track row on the list is an upgrade the customer chooses.
      final upgrades = upgradeIdsFor('s-track-night-lo');
      expect(upgrades, contains('doso-track'));
      expect(upgrades, contains('iron-rod-19'));
    });

    test('tracks are offered on nothing else', () {
      for (final parent in ['spc-4mm', 'korea-wallpaper', 'roller-blackout']) {
        final tracks = card
            .upgradesFor(ruleFor(parent))
            .where((r) => r.family == Family.track)
            .map((r) => r.id);
        expect(tracks, isEmpty, reason: '$parent was offered a track');
      }
    });

    test('the stainless steel side guide belongs to the outdoor roller', () {
      // Client, Sep 2026: it is a must on an outdoor roller blind and has no
      // meaning anywhere else. RM400 a set.
      expect(
        upgradeIdsFor('outdoor-roller-fabric'),
        contains('side-guide-cable'),
      );
    });

    test('the stainless steel side guide is offered on nothing else', () {
      for (final parent in [
        's-track-night-lo',
        'spc-4mm',
        'korea-wallpaper',
        'roller-blackout',
      ]) {
        expect(
          upgradeIdsFor(parent),
          isNot(contains('side-guide-cable')),
          reason: '$parent was offered the stainless steel side guide',
        );
      }
    });

    test('a flooring service is not offered on a curtain or wallpaper', () {
      // Self levelling and dismantling old SPC prepare a floor. On a curtain
      // they are a line somebody taps by mistake and a customer queries.
      for (final parent in ['s-track-night-lo', 'korea-wallpaper']) {
        final services = card
            .upgradesFor(ruleFor(parent))
            .where((r) => r.family == Family.service)
            .map((r) => r.id);
        expect(
          services,
          isNot(contains('self-levelling')),
          reason: '$parent was offered self levelling',
        );
        expect(
          services,
          isNot(contains('dismantle-old-spc')),
          reason: '$parent was offered SPC dismantling',
        );
      }
    });

    test('the wallpaper service is not offered on flooring or a curtain', () {
      for (final parent in ['spc-4mm', 's-track-night-lo']) {
        expect(
          upgradeIdsFor(parent),
          isNot(contains('wallpaper-dismantle')),
          reason: '$parent was offered wallpaper dismantling',
        );
      }
    });

    test('a motor is not offered on a floor or on wallpaper', () {
      // Nothing about a floor is motorised.
      for (final parent in ['spc-4mm', 'korea-wallpaper']) {
        final motors = card
            .upgradesFor(ruleFor(parent))
            .where((r) => r.id.contains('motor') || r.id == 'remote-control')
            .map((r) => r.id);
        expect(motors, isEmpty, reason: '$parent was offered $motors');
      }
    });

    test('the motor and its remote belong to an indoor curtain', () {
      // Client, Sep 2026: the generic motor is for indoor curtains. Every
      // outdoor product either carries its own named motor row or is manual.
      final upgrades = upgradeIdsFor('night-curtain-lo');
      expect(upgrades, contains('motor'));
      expect(upgrades, contains('remote-control'));
    });

    test('an outdoor blind is offered its own motor, not the generic one', () {
      // Somfy and AOK are one variant with a material choice, not two
      // upgrades — `upgradesFor` dedupes on variant and the choice is deferred
      // to measurement like every other material (§13 B7).
      final upgrades = card.upgradesFor(ruleFor('outdoor-roller-fabric'));
      final motorVariants = upgrades
          .map((r) => r.variant)
          .where((v) => v.contains('motor'));
      expect(motorVariants, ['outdoor_roller_motor']);
      expect(upgrades.map((r) => r.id), isNot(contains('motor')));
      expect(card.materialsFor('outdoor_roller_motor').length, 2);
    });
  });

  group('a required add-on is not a choice', () {
    // Client, Sep 2026: the stainless steel side guide is a **must** on an
    // outdoor roller blind, and it is still charged. The wizard adds it, so
    // the one product that cannot go up without it is not the one somebody
    // forgets to tick.

    test('the side guide is flagged as required', () {
      expect(ruleFor('side-guide-cable').mandatory, isTrue);
    });

    test('and it is still charged, at RM400 a set', () {
      // "Charged, added automatically" — not folded into the blind's rate and
      // not quietly dropped. The customer sees the line.
      expect(ruleFor('side-guide-cable').rateSen, 40000);
    });

    test('nothing else on the card is required', () {
      // A flag that spread would start adding lines nobody chose, which is
      // the exact opposite of §4.1.
      final required = card.rules
          .where((r) => r.mandatory)
          .map((r) => r.id)
          .toSet();
      expect(required, {'side-guide-cable'});
    });

    test('a rule with no flag is optional, and that is the default', () {
      // The card was written before this flag existed. Every row that does not
      // mention it has to stay a choice.
      expect(ruleFor('motor').mandatory, isFalse);
      expect(ruleFor('doso-track').mandatory, isFalse);
      expect(ruleFor('self-levelling').mandatory, isFalse);
    });
  });

  group('a service is quoted on the product, not on its own', () {
    // Client, Sep 2026: "make charging them an option instead while quoting
    // for that product, not a separate service quote, so it is clearer".
    //
    // They are still charged. What changes is where they are asked for: an
    // upgrade copies its parent's dimensions, so dismantling old SPC bills the
    // same square footage as the floor going over it, and nobody types a room
    // twice or types it differently the second time.

    test('a floor offers to dismantle the old one and to self level', () {
      final upgrades = upgradeIdsFor('spc-4mm');
      expect(upgrades, contains('dismantle-old-spc'));
      expect(upgrades, contains('self-levelling'));
    });

    test('wallpaper offers its own dismantling', () {
      expect(upgradeIdsFor('korea-wallpaper'), contains('wallpaper-dismantle'));
    });

    test('none of them can be started as a product on its own', () {
      // The whole point of the change. A service picked from the product list
      // asks for its own measurements, which is the second chance to type a
      // different number for the same room.
      final selectable = card.selectableProducts.map((r) => r.id);
      for (final service in [
        'dismantle-old-spc',
        'self-levelling',
        'wallpaper-dismantle',
      ]) {
        expect(
          selectable,
          isNot(contains(service)),
          reason: '$service is still offered as a product',
        );
      }
    });

    test('they are still charged, and still at the same rates', () {
      // "actually i'm wrong, need to be charged". Nothing here is free: the
      // change is where the question is asked, not what it costs.
      expect(ruleFor('dismantle-old-spc').rateSen, 100);
      expect(ruleFor('self-levelling').rateSen, 300);
      expect(ruleFor('wallpaper-dismantle').rateSen, 8000);
    });

    test('a flooring service still rides the flooring deposit', () {
      // §6.1: applying a curtain lock to a flooring line is the expensive bug
      // in this design, and these rows are family `service`.
      expect(
        ruleFor('self-levelling').depositCategory,
        DepositCategory.flooring,
      );
      expect(
        ruleFor('wallpaper-dismantle').depositCategory,
        DepositCategory.wallpaper,
      );
    });
  });
}
