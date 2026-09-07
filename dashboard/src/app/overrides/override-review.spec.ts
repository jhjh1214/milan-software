/**
 * The weekly override review. SPEC.md §6.5.
 *
 * > without it the log is never read and the control does not exist
 *
 * So what is tested is the things that would quietly stop it being a control: a
 * week boundary that drops a row, a net total that hides a bad week, a reason
 * shortened into something less than what was typed, and a 403 that looks like
 * a quiet week rather than like a refusal.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
import { RouterTestingHarness } from '@angular/router/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import type { PriceOverrideOut } from '../api/types';
import { Text } from '../i18n/text';
import { OverrideReview, weekStart } from './override-review';

const row = (over: Partial<PriceOverrideOut> = {}): PriceOverrideOut => ({
  id: 'ov1',
  order_line_id: 'l1',
  order_id: 'o1',
  before_sen: 55200,
  after_sen: 50000,
  reason: 'matched a competitor quote',
  admin_user_id: 'u-boss',
  at: '2026-08-27T11:00:00Z',
  ...over,
});

describe('weekStart', () => {
  it('is the Monday on or before the day', () => {
    // Monday because that is how the shop talks about a week. Getting this
    // wrong puts a row in two weeks or in neither.
    const monday = '2026-08-24T00:00:00.000Z';
    expect(weekStart(new Date('2026-08-24T09:00:00Z')).toISOString()).toBe(monday);
    expect(weekStart(new Date('2026-08-27T11:00:00Z')).toISOString()).toBe(monday);
    // Sunday belongs to the week that started six days earlier, not the one
    // about to start.
    expect(weekStart(new Date('2026-08-30T23:59:00Z')).toISOString()).toBe(monday);
    expect(weekStart(new Date('2026-08-31T00:00:00Z')).toISOString()).toBe(
      '2026-08-31T00:00:00.000Z',
    );
  });
});

describe('OverrideReview', () => {
  let fixture: ComponentFixture<OverrideReview>;
  let http: HttpTestingController;
  let i18n: Text;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([]),
      ],
    });
    fixture = TestBed.createComponent(OverrideReview);
    http = TestBed.inject(HttpTestingController);
    i18n = TestBed.inject(Text);
    // Pinned rather than assumed: the dashboard defaults to Chinese (§13 C9).
    i18n.pick('en');
  });

  const load = (rows: PriceOverrideOut[]): void => {
    fixture.detectChanges();
    const req = http.expectOne((r) => r.url === '/api/overrides');
    req.flush({ overrides: rows });
    fixture.detectChanges();
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  it('asks for a half-open week', () => {
    // Inclusive at the start, exclusive at the end, so one row lands in
    // exactly one week rather than in two or in neither.
    fixture.detectChanges();
    const req = http.expectOne((r) => r.url === '/api/overrides');

    const start = new Date(req.request.params.get('start')!);
    const end = new Date(req.request.params.get('end')!);
    expect(end.getTime() - start.getTime()).toBe(7 * 86_400_000);
    expect(start.getUTCDay()).toBe(1);

    req.flush({ overrides: [] });
  });

  it('shows who, how much, and why', () => {
    // The three questions the log exists to answer. Anything missing makes a
    // row unusable for the conversation it is meant to start.
    load([row()]);
    expect(text()).toContain('u-boss');
    expect(text()).toContain('RM 552.00');
    expect(text()).toContain('RM 500.00');
    expect(text()).toContain('matched a competitor quote');
  });

  it('shows the reason as typed, not shortened', () => {
    const long =
      'customer had a written quote from the shop across the road and would ' +
      'have walked, boss approved matching it';
    load([row({ reason: long })]);
    expect(text()).toContain(long);
  });

  it('totals the week before any single row is read', () => {
    // A week full of individually reasonable-looking changes can still add up
    // to something nobody decided.
    load([
      row({ id: 'a', before_sen: 55200, after_sen: 50000 }),
      row({ id: 'b', before_sen: 100000, after_sen: 90000 }),
      row({ id: 'c', before_sen: 20000, after_sen: 22000 }),
    ]);

    expect(text()).toContain('3 changes');
    // -5200 - 10000 + 2000
    expect(text()).toContain('RM -132.00');
  });

  it('a quiet week says so in words', () => {
    // An empty table reads as "failed to load", and this screen has to be
    // trustworthy about a week in which nobody changed anything.
    load([]);
    expect(text()).toContain('Nobody changed a price this week');
  });

  it('a refusal is not shown as a quiet week', () => {
    // §6.5 makes this admin-only on the server. Rendering a 403 as an empty
    // table would tell a non-admin that nothing happened, which is worse than
    // telling them nothing.
    fixture.detectChanges();
    http
      .expectOne((r) => r.url === '/api/overrides')
      .flush({ detail: 'no' }, { status: 403, statusText: 'Forbidden' });
    fixture.detectChanges();

    expect(text()).toContain('Only an admin can see the override log');
    expect(text()).not.toContain('Nobody changed a price');
  });

  it('a failed load offers a way back', () => {
    fixture.detectChanges();
    http
      .expectOne((r) => r.url === '/api/overrides')
      .flush({ detail: 'no' }, { status: 500, statusText: 'Server Error' });
    fixture.detectChanges();

    expect(text()).toContain('The server answered 500');
    expect(text()).toContain('Try again');
  });

  describe('in the other two languages', () => {
    // SPEC.md §13 C9. §6.5 is blunt that this screen *is* the control — an
    // audit log only counts if somebody reads it, and somebody who cannot
    // read the column headings is not reading it.

    it('says the whole review in Chinese', () => {
      i18n.pick('zh');
      load([row()]);

      expect(text()).toContain('人手改过的价格');
      expect(text()).toContain('1 笔，合计');
      expect(text()).toContain('原因');
      expect(text()).not.toContain('Prices changed by hand');
    });

    it('says the whole review in Malay', () => {
      i18n.pick('ms');
      load([row()]);

      expect(text()).toContain('Harga yang diubah dengan tangan');
      expect(text()).toContain('1 perubahan');
      expect(text()).toContain('Sebab');
    });

    it('the reason is shown as typed, never translated', () => {
      // It is what one named person wrote about one price, and §6.5 makes it
      // the thing the review exists to read. Rewording it in another language
      // would put words in their mouth.
      i18n.pick('ms');
      load([row({ reason: 'matched a competitor quote' })]);

      expect(text()).toContain('matched a competitor quote');
    });

    it('a quiet week says so in the reader’s language', () => {
      // An empty table reads as "failed to load" in any language.
      i18n.pick('zh');
      load([]);

      expect(text()).toContain('这一周没有人改过价格');
    });

    it('a refusal is not shown as a quiet week, in any language', () => {
      i18n.pick('ms');
      fixture.detectChanges();
      http
        .expectOne((r) => r.url === '/api/overrides')
        .flush({ detail: 'no' }, { status: 403, statusText: 'Forbidden' });
      fixture.detectChanges();

      expect(text()).toContain('Hanya admin boleh melihat log');
      expect(text()).not.toContain('Tiada sesiapa mengubah harga');
    });
  });
});

/**
 * Every control on the screen, clicked.
 *
 * Nothing in the suite above touches a button: the week is moved by setting a
 * query parameter and the load is asserted from the request. That leaves the
 * two arrows — the only way anybody actually reaches last week — untested, and
 * a dead binding there is invisible in exactly the way the people screen's Add
 * button was.
 *
 * Through a **real router**, because `step()` navigates rather than setting a
 * field. A component fixture with `provideRouter([])` would let the navigation
 * resolve to nothing and the effect never re-run, and the test would pass on a
 * screen that does not move.
 */
describe('OverrideReview: the week arrows', () => {
  let harness: RouterTestingHarness;
  let http: HttpTestingController;
  let router: Router;
  let i18n: Text;

  beforeEach(async () => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        provideRouter([{ path: 'overrides', component: OverrideReview }]),
      ],
    });
    http = TestBed.inject(HttpTestingController);
    router = TestBed.inject(Router);
    i18n = TestBed.inject(Text);
    i18n.pick('en');
    harness = await RouterTestingHarness.create();
  });

  const open = async (url: string): Promise<void> => {
    await harness.navigateByUrl(url);
    http.expectOne((r) => r.url === '/api/overrides').flush({ overrides: [] });
    harness.detectChanges();
  };

  const arrows = (): HTMLButtonElement[] =>
    Array.from(
      harness.routeNativeElement!.querySelectorAll('.week button'),
    ) as HTMLButtonElement[];

  /** Click, then let the navigation it starts actually finish. */
  const press = async (which: 0 | 1): Promise<void> => {
    arrows()[which].click();
    await harness.fixture.whenStable();
    harness.detectChanges();
  };

  const started = (): string => {
    const req = http.expectOne((r) => r.url === '/api/overrides');
    const start = req.request.params.get('start') as string;
    req.flush({ overrides: [] });
    harness.detectChanges();
    return start.slice(0, 10);
  };

  it('there are two of them and they are the only ones in the nav', async () => {
    await open('/overrides?week=2026-08-26');
    expect(arrows().length).toBe(2);
  });

  it('Earlier loads the week before, and says so in the URL', async () => {
    // The URL matters as much as the load: §11 Phase 5 makes every filter
    // state reachable by link, and a week somebody can see but not send is
    // half a review screen.
    await open('/overrides?week=2026-08-26');

    await press(0);

    expect(started()).toBe('2026-08-17');
    expect(router.url).toContain('week=2026-08-17');
  });

  it('Later loads the week after', async () => {
    await open('/overrides?week=2026-08-26');

    await press(1);

    expect(started()).toBe('2026-08-31');
    expect(router.url).toContain('week=2026-08-31');
  });

  it('stepping twice keeps going, rather than bouncing off the same week', async () => {
    // The navigation is keyed on the URL. Stepping from a week the URL does
    // not name would compute the same target twice and look like a dead
    // button on the second press.
    await open('/overrides?week=2026-08-26');

    await press(0);
    expect(started()).toBe('2026-08-17');

    await press(0);
    expect(started()).toBe('2026-08-10');
  });

  it('the first Earlier works even when the URL named no week', async () => {
    // The commonest press: somebody opens the screen on Monday and wants
    // last week. `start()` falls back to today's week, and stepping has to
    // step from that rather than from nothing.
    await open('/overrides');
    const thisWeek = weekStart(new Date());
    const wanted = new Date(thisWeek);
    wanted.setUTCDate(wanted.getUTCDate() - 7);

    await press(0);

    expect(started()).toBe(wanted.toISOString().slice(0, 10));
  });
});
