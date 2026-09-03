import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milan_quote/data/database.dart';
import 'package:milan_quote/data/quote_repository.dart';

/// SPEC.md §8.1: "The app will be backgrounded mid-quote by a phone call. Every
/// keystroke persists locally. Reopening returns to the exact window."
///
/// Phase 1 lost everything on force-quit. These tests are what say it no longer
/// does — a dropped phone at a fair must cost nothing.
void main() {
  late AppDatabase db;
  late QuoteRepository repo;

  setUp(() {
    // One shared in-memory database, so a "restart" can reopen the same data.
    db = AppDatabase(NativeDatabase.memory());
    repo = QuoteRepository(db);
  });

  tearDown(() => db.close());

  Future<String> draft() async {
    final q = await repo.ensureDraft(
      rateCardVersion: 1,
      language: 'zh',
      channel: 'fair',
    );
    return q.id;
  }

  Future<String> addNightCurtain(String quoteId, {String room = '客厅'}) =>
      repo.addLine(
        quoteId: quoteId,
        room: room,
        variant: 'night_curtain',
        materialKey: null,
        layer: 'night',
        widthTmm: 36576,
        heightTmm: 27432,
        rawWidth: "12'",
        rawHeight: "9'",
      );

  group('ids', () {
    test('are client-generated UUID v4, never issued by a server', () {
      // Two part-timers offline at one fair must not collide.
      final ids = List.generate(500, (_) => newId());
      expect(ids.toSet().length, 500, reason: 'a collision in 500 is fatal');
      expect(
        ids.first,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
        reason: 'must be a v4 UUID',
      );
    });
  });

  group('a quote survives being closed and reopened', () {
    test('lines written before a restart are all there afterwards', () async {
      final id = await draft();
      await addNightCurtain(id, room: '客厅');
      await addNightCurtain(id, room: '主人房');
      await addNightCurtain(id, room: '房间');

      // Reopening the app: a fresh repository over the same storage.
      final reopened = QuoteRepository(db);
      final quote = await reopened.ensureDraft(
        rateCardVersion: 1,
        language: 'zh',
        channel: 'fair',
      );

      expect(quote.id, id, reason: 'the same draft must be picked back up');
      final lines = await reopened.lines(quote.id);
      expect(lines, hasLength(3));
      expect(lines.map((l) => l.room), ['客厅', '主人房', '房间']);
    });

    test(
      'every entered value comes back exactly, including the raw text',
      () async {
        final id = await draft();
        await repo.addLine(
          quoteId: id,
          room: '客厅',
          variant: 'night_curtain',
          materialKey: null,
          layer: 'night',
          widthTmm: 37592,
          heightTmm: 30480,
          rawWidth: "12'4",
          rawHeight: "10'",
          quantity: 3,
        );

        final line = (await QuoteRepository(db).lines(id)).single;
        expect(line.widthTmm, 37592, reason: 'tenths of a mm, not mm');
        expect(line.heightTmm, 30480);
        expect(line.quantity, 3);
        // §5.5: the raw entry survives, so the line can show what was typed
        // rather than a value the user never saw.
        expect(line.rawWidth, "12'4");
        expect(line.rawHeight, "10'");
      },
    );

    test('a deferred material stays deferred across a restart', () async {
      // Null means "not chosen yet" and must not be persisted as a real
      // material, or the reopened quote would silently price the cheaper one.
      final id = await draft();
      await repo.addLine(
        quoteId: id,
        room: '客厅',
        variant: 'zebra_blackout',
        materialKey: null,
        layer: 'single',
        widthTmm: 15240,
        heightTmm: 18288,
        rawWidth: "5'",
        rawHeight: "6'",
      );
      final line = (await QuoteRepository(db).lines(id)).single;
      expect(line.materialKey, isNull);
    });

    test(
      'the tier survives, so an MVP quote reopens as an MVP quote',
      () async {
        final id = await draft();
        await repo.setTier(id, 'mvp');
        final quote = await QuoteRepository(
          db,
        ).ensureDraft(rateCardVersion: 1, language: 'zh', channel: 'fair');
        expect(quote.tier, 'mvp');
      },
    );
  });

  group('ordering', () {
    test('lines keep the order they were entered in', () async {
      final id = await draft();
      for (final room in ['A', 'B', 'C', 'D']) {
        await addNightCurtain(id, room: room);
      }
      final lines = await repo.lines(id);
      expect(lines.map((l) => l.sortOrder), [0, 1, 2, 3]);
      expect(lines.map((l) => l.room), ['A', 'B', 'C', 'D']);
    });

    test('undo restores an upgrade as a child, not as its own window', () async {
      // The total is identical either way, which is exactly why this needs its
      // own assertion: a track restored as a top-level line still adds up, but
      // the quote then reads as two unrelated charges and the customer sees a
      // stray RM960 line with no curtain attached.
      final id = await draft();
      final parent = await addNightCurtain(id);
      await repo.addLine(
        quoteId: id,
        room: '客厅',
        variant: 's_track_night',
        materialKey: null,
        layer: 'single',
        widthTmm: 36576,
        heightTmm: 27432,
        rawWidth: "12'",
        rawHeight: "9'",
        parentLineId: parent,
      );

      final removed = await repo.deleteLineWithChildren(parent);
      expect(removed, hasLength(2));
      expect(await repo.lines(id), isEmpty);

      await repo.restoreLines(removed);
      final restored = await repo.lines(id);
      expect(restored, hasLength(2));
      expect(restored[0].parentLineId, isNull, reason: 'the curtain');
      expect(
        restored[1].parentLineId,
        parent,
        reason: 'the track must still hang off its curtain',
      );
    });

    test('undo restores the photo with the line', () async {
      final id = await draft();
      final lineId = await addNightCurtain(id);
      await repo.setLinePhoto(lineId, '/tmp/window.jpg');

      final removed = await repo.deleteLineWithChildren(lineId);
      await repo.restoreLines(removed);

      // Losing it would send the part-timer back to the window for a photo
      // they already took.
      expect((await repo.lines(id)).single.photoPath, '/tmp/window.jpg');
    });

    test('undo puts a line back where it was, not on the end', () async {
      // §8.1 offers undo so a mis-tap costs nothing. A line that reappears in
      // the wrong place still costs the user their place.
      final id = await draft();
      for (final room in ['A', 'B', 'C']) {
        await addNightCurtain(id, room: room);
      }
      final middle = (await repo.lines(id))[1];

      await repo.deleteLine(middle.id);
      expect((await repo.lines(id)).map((l) => l.room), ['A', 'C']);

      await repo.restoreLine(middle);
      expect((await repo.lines(id)).map((l) => l.room), ['A', 'B', 'C']);
    });
  });

  group('integrity', () {
    test(
      'adding a line touches the quote timestamp in the same transaction',
      () async {
        final id = await draft();
        final before = (await repo.ensureDraft(
          rateCardVersion: 1,
          language: 'zh',
          channel: 'fair',
        )).updatedAt;

        await Future<void>.delayed(const Duration(milliseconds: 5));
        await addNightCurtain(id);

        final after = (await repo.ensureDraft(
          rateCardVersion: 1,
          language: 'zh',
          channel: 'fair',
        )).updatedAt;
        // If the line landed but the timestamp did not, a crash would leave
        // latestQuote picking the wrong draft.
        expect(after.isAfter(before), isTrue);
      },
    );

    test('a line cannot reference a quote that does not exist', () async {
      // Foreign keys are off by default in SQLite; the migration turns them on.
      expect(
        () => repo.addLine(
          quoteId: 'no-such-quote',
          room: '客厅',
          variant: 'night_curtain',
          materialKey: null,
          layer: 'night',
          widthTmm: 36576,
          heightTmm: 27432,
          rawWidth: "12'",
          rawHeight: "9'",
        ),
        throwsA(anything),
      );
    });

    test('clearing removes lines and quotes together', () async {
      final id = await draft();
      await addNightCurtain(id);
      await repo.clearAll();
      expect(await db.latestQuote(), isNull);
      expect(await repo.lines(id), isEmpty);
    });
  });
}
