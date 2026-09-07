/**
 * Publishing a rate card. SPEC.md §11 Phase 5.
 *
 * > Publishing shows exactly which products move and by how much before commit
 *
 * The acceptance criterion is really about a sequence, so that is what is
 * tested: publish is not reachable until a preview has been seen, and any edit
 * after that takes it away again. A publish that went out against a diff
 * describing different text would be worse than no preview at all, because
 * somebody would have read the wrong list and believed it.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import type { CardDiffOut } from '../api/types';
import { PublishCard } from './publish-card';

const CARD = JSON.stringify({
  version: 2,
  rules: [{ id: 'night-curtain-lo', rate_sen: 5000 }],
});

const diff = (over: Partial<CardDiffOut> = {}): CardDiffOut => ({
  changed: [
    {
      rule_id: 'night-curtain-lo',
      label: 'Night curtain',
      old_rate_sen: 4600,
      new_rate_sen: 5000,
      old_mvp_rate_sen: 4000,
      new_mvp_rate_sen: 4000,
      delta_sen: 400,
    },
  ],
  added: [],
  removed: [],
  unchanged: 76,
  is_empty: false,
  total_delta_sen: 400,
  ...over,
});

describe('PublishCard', () => {
  let fixture: ComponentFixture<PublishCard>;
  let component: PublishCard;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    fixture = TestBed.createComponent(PublishCard);
    component = fixture.componentInstance;
    http = TestBed.inject(HttpTestingController);
    fixture.detectChanges();
  });

  const type = (text: string): void => {
    component['onText'](text);
    fixture.detectChanges();
  };

  const previewWith = (d: CardDiffOut = diff()): void => {
    component['preview']();
    http.expectOne('/api/rate-cards/preview').flush(d);
    fixture.detectChanges();
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  describe('the two steps', () => {
    it('offers no preview until there is a card to preview', () => {
      expect(component['canPreview']()).toBe(false);
      type('not json at all');
      expect(component['canPreview']()).toBe(false);
      type(CARD);
      expect(component['canPreview']()).toBe(true);
    });

    it('offers no publish until a preview has been seen', () => {
      type(CARD);
      expect(component['canPublish']()).toBe(false);
      previewWith();
      expect(component['canPublish']()).toBe(true);
    });

    it('takes the publish away again when the text changes', () => {
      // A publish against a diff describing different text is the one thing
      // this screen exists to prevent, and it is worse than no preview: the
      // wrong list was read and believed.
      type(CARD);
      previewWith();
      expect(component['canPublish']()).toBe(true);

      type(CARD.replace('5000', '5100'));
      expect(component['canPublish']()).toBe(false);
      expect(component['diff']()).toBeNull();
    });

    it('takes it away when the list changes too', () => {
      // A diff of the fair card says nothing about the standard one.
      type(CARD);
      previewWith();
      component['chooseList']('standard');
      expect(component['canPublish']()).toBe(false);
    });

    it('refuses to publish without a preview even if called directly', () => {
      // The button is absent, and this is the second lock on the same door.
      type(CARD);
      component['publish']();
      http.expectNone('/api/rate-cards');
    });

    it('offers no second publish once it has gone out', () => {
      // The diff is still on screen afterwards, so "a preview exists" is not
      // enough on its own — publishing twice would create two versions of the
      // same card, and every handset would pull the second for no reason.
      type(CARD);
      previewWith();
      component['publish']();
      http
        .expectOne('/api/rate-cards')
        .flush({ version: 2, list_id: 'fair', published_by: 'u-boss' });
      fixture.detectChanges();

      expect(component['stage']()).toBe('published');
      expect(component['canPublish']()).toBe(false);

      component['publish']();
      http.expectNone('/api/rate-cards');
    });
  });

  describe('the preview', () => {
    it('shows what moves, by how much, and which way', () => {
      type(CARD);
      previewWith();

      expect(text()).toContain('Night curtain');
      expect(text()).toContain('RM 46.00');
      expect(text()).toContain('RM 50.00');
      expect(text()).toContain('RM 4.00');
      expect(text()).toContain('76 unchanged');
    });

    it('names products that would disappear', () => {
      // A product that stops being quotable is at least as big a change as one
      // that gets dearer, and it is the one nobody notices.
      type(CARD);
      previewWith(
        diff({
          changed: [],
          total_delta_sen: 0,
          removed: [
            {
              rule_id: 'gone',
              label: 'Outdoor zip',
              old_rate_sen: 5500,
              new_rate_sen: null,
              old_mvp_rate_sen: null,
              new_mvp_rate_sen: null,
              delta_sen: null,
            },
          ],
        }),
      );

      expect(text()).toContain('Products that disappear');
      expect(text()).toContain('Outdoor zip');
      expect(text()).toContain('RM 55.00');
    });

    it('says plainly when nothing would change, and offers no publish', () => {
      // Publishing it would create a version nobody can tell apart from the
      // live one, and every handset would pull it for no reason.
      type(CARD);
      previewWith(
        diff({ changed: [], is_empty: true, total_delta_sen: 0, unchanged: 77 }),
      );

      expect(text()).toContain('Nothing would change');
      expect(component['canPublish']()).toBe(false);
    });

    it('asks the server, and never works the diff out here', () => {
      // The server is the authority on pricing. A diff computed in the browser
      // could disagree with the publish it precedes.
      type(CARD);
      component['preview']();
      const req = http.expectOne('/api/rate-cards/preview');
      expect(req.request.body.list_id).toBe('fair');
      expect(req.request.body.payload.version).toBe(2);
      req.flush(diff());
    });
  });

  describe('publishing', () => {
    it('sends the card and reports the version it became', () => {
      type(CARD);
      previewWith();

      component['publish']();
      const req = http.expectOne('/api/rate-cards');
      expect(req.request.body.list_id).toBe('fair');
      req.flush({ version: 2, list_id: 'fair', published_by: 'u-boss' });
      fixture.detectChanges();

      expect(text()).toContain('version 2');
      expect(text()).toContain('next pull');
    });

    it('says a refusal in words, and stays on the previewed step', () => {
      type(CARD);
      previewWith();

      component['publish']();
      http
        .expectOne('/api/rate-cards')
        .flush({ detail: 'no' }, { status: 403, statusText: 'Forbidden' });
      fixture.detectChanges();

      expect(text()).toContain('Only an admin can publish');
      expect(component['stage']()).toBe('previewed');
    });

    it('explains a refused version rather than showing a bare 400', () => {
      // Versions only go up: a re-used number would leave two different cards
      // answering to one.
      type(CARD);
      previewWith();

      component['publish']();
      http
        .expectOne('/api/rate-cards')
        .flush({ detail: 'no' }, { status: 400, statusText: 'Bad Request' });
      fixture.detectChanges();

      expect(text()).toContain('version number goes up');
    });
  });

  describe('every control on the screen is actually wired', () => {
    // Nothing above this block touches the DOM: every test drives the
    // component by calling its methods. That is exactly the gap that let the
    // people screen ship an Add button bound to `(ngSubmit)` in a component
    // without FormsModule — a DOM event nothing fires, so the unit was right
    // and only the wiring to it was dead.
    //
    // This screen is the one where that would cost the most: it sets the price
    // of everything, for every handset, on the next pull. So the whole
    // sequence is driven the way somebody in the office would.
    //
    // Selectors are structural rather than by label, matching the idiom in
    // order-board.spec.ts — a test that finds a button by its English text
    // stops working the moment the screen speaks Malay.

    const el = <T extends Element>(selector: string): T => {
      const found = fixture.nativeElement.querySelector(selector) as T | null;
      if (found === null) throw new Error(`no ${selector} on the screen`);
      return found;
    };

    const typeInBox = (value: string): void => {
      const box = el<HTMLTextAreaElement>('textarea#card');
      box.value = value;
      box.dispatchEvent(new Event('input'));
      fixture.detectChanges();
    };

    const click = <T extends HTMLElement>(selector: string): void => {
      el<T>(selector).click();
      fixture.detectChanges();
    };

    it('the whole publish runs from the keyboard and the mouse alone', () => {
      typeInBox(CARD);
      click('button.primary');

      const preview = http.expectOne('/api/rate-cards/preview');
      expect(preview.request.body.payload.version).toBe(2);
      preview.flush(diff());
      fixture.detectChanges();
      expect(text()).toContain('1 prices move');

      click('button.danger');
      const publish = http.expectOne('/api/rate-cards');
      expect(publish.request.body.list_id).toBe('fair');
      publish.flush({ version: 2, list_id: 'fair', published_by: 'u-boss' });
      fixture.detectChanges();

      expect(text()).toContain('version 2');
    });

    it('the list buttons choose the list the server is asked about', () => {
      // Sending the standard card to the fair list would publish the wrong
      // prices under the right name, which is the worst version of this bug.
      const lists = fixture.nativeElement.querySelectorAll(
        '.which button',
      ) as NodeListOf<HTMLButtonElement>;
      expect(lists.length).toBe(2);

      lists[1].click();
      fixture.detectChanges();
      typeInBox(CARD);
      click('button.primary');

      const req = http.expectOne('/api/rate-cards/preview');
      expect(req.request.body.list_id).toBe('standard');
      req.flush(diff());
    });

    it('switching list after a preview takes the publish button away', () => {
      // A diff of the fair card says nothing about the standard one, and the
      // button that says "Publish this" would be describing the wrong diff.
      typeInBox(CARD);
      click('button.primary');
      http.expectOne('/api/rate-cards/preview').flush(diff());
      fixture.detectChanges();
      expect(fixture.nativeElement.querySelector('button.danger')).not.toBeNull();

      const lists = fixture.nativeElement.querySelectorAll(
        '.which button',
      ) as NodeListOf<HTMLButtonElement>;
      lists[1].click();
      fixture.detectChanges();

      expect(fixture.nativeElement.querySelector('button.danger')).toBeNull();
    });

    it('an edit after a preview takes the publish button away', () => {
      typeInBox(CARD);
      click('button.primary');
      http.expectOne('/api/rate-cards/preview').flush(diff());
      fixture.detectChanges();
      expect(fixture.nativeElement.querySelector('button.danger')).not.toBeNull();

      typeInBox(CARD + ' ');
      expect(fixture.nativeElement.querySelector('button.danger')).toBeNull();
    });

    it('a card that changes nothing offers no publish button at all', () => {
      // It would create a version nobody can tell apart from the live one,
      // and every handset would pull it for no reason.
      typeInBox(CARD);
      click('button.primary');
      http
        .expectOne('/api/rate-cards/preview')
        .flush(diff({ changed: [], is_empty: true, total_delta_sen: 0 }));
      fixture.detectChanges();

      expect(text()).toContain('Nothing would change');
      expect(fixture.nativeElement.querySelector('button.danger')).toBeNull();
    });

    it('the preview button is disabled until the text parses', () => {
      const button = el<HTMLButtonElement>('button.primary');
      expect(button.disabled).toBe(true);
      typeInBox('not json at all');
      expect(el<HTMLButtonElement>('button.primary').disabled).toBe(true);
      typeInBox(CARD);
      expect(el<HTMLButtonElement>('button.primary').disabled).toBe(false);
    });

    it('"Publish another" clears the screen rather than half of it', () => {
      typeInBox(CARD);
      click('button.primary');
      http.expectOne('/api/rate-cards/preview').flush(diff());
      fixture.detectChanges();
      click('button.danger');
      http
        .expectOne('/api/rate-cards')
        .flush({ version: 2, list_id: 'fair', published_by: 'u-boss' });
      fixture.detectChanges();

      click('button.primary');

      // Back to an empty box with no diff behind it. Leaving the old card in
      // place would let somebody publish it twice by pressing on.
      expect(el<HTMLTextAreaElement>('textarea#card').value).toBe('');
      expect(text()).not.toContain('prices move');
      expect(el<HTMLButtonElement>('button.primary').disabled).toBe(true);
    });
  });
});
