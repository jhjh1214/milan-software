/**
 * Who can sign in. SPEC.md §11 Phase 5, §12.
 *
 * > Deactivating a user requires typing their name
 *
 * That is the acceptance criterion and it is what most of this file is about.
 * It is not friction for its own sake: sessions never expire (§12), so
 * deactivating is the only thing that stops the handset in a leaver's pocket,
 * and doing it to the wrong person silently locks somebody out mid-fair.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';

import { Session } from '../auth/session';
import type { PersonOut } from '../api/types';
import { Text } from '../i18n/text';
import { People } from './people';

const person = (over: Partial<PersonOut> = {}): PersonOut => ({
  id: 'u1',
  name: 'Ah Lian',
  phone: '0123456789',
  email: null,
  role: 'parttime',
  language: 'zh',
  is_active: true,
  deactivated_at: null,
  ...over,
});

describe('People', () => {
  let fixture: ComponentFixture<People>;
  let component: People;
  let http: HttpTestingController;
  let session: Session;
  let i18n: Text;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    fixture = TestBed.createComponent(People);
    component = fixture.componentInstance;
    http = TestBed.inject(HttpTestingController);
    session = TestBed.inject(Session);
    i18n = TestBed.inject(Text);
    // Pinned rather than assumed: the dashboard defaults to Chinese (§13 C9)
    // and nobody is signed in here.
    i18n.pick('en');
  });

  const load = (people: PersonOut[]): void => {
    fixture.detectChanges();
    http.expectOne('/api/people').flush({ people });
    fixture.detectChanges();
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  describe('the roster', () => {
    it('shows leavers as well as everybody else', () => {
      // A screen that hides them cannot answer "who used to have access",
      // which is the question somebody asks after something goes missing.
      load([
        person(),
        person({
          id: 'u2',
          name: 'Old Hand',
          is_active: false,
          deactivated_at: '2026-03-12T00:00:00Z',
        }),
      ]);

      expect(text()).toContain('Ah Lian');
      expect(text()).toContain('Old Hand');
      expect(text()).toContain('Left 12 Mar 2026');
    });

    it('never receives a PIN or a hash to display', () => {
      load([person()]);
      expect(text()).not.toContain('scrypt');
      expect(JSON.stringify(component['people']())).not.toContain('pin');
    });

    it('offers no removal for the signed-in admin themselves', () => {
      // Locking the last admin out is a mistake nobody can undo from the app.
      // The server refuses it too; this is so nobody is invited to try.
      session.user.set({ id: 'u1', name: 'Boss', role: 'admin', language: 'en' });
      load([person({ id: 'u1', name: 'Boss', role: 'admin' })]);

      expect(text()).toContain('You');
      expect(text()).not.toContain('Remove access');
    });
  });

  describe('removing access', () => {
    it('asks for the name, and will not go until it matches', () => {
      load([person()]);
      component['startDeactivating'](person());
      fixture.detectChanges();

      expect(text()).toContain("Remove Ah Lian's access?");
      expect(component['nameMatches']()).toBe(false);

      component['typedName'].set('Ah Li');
      expect(component['nameMatches']()).toBe(false);

      component['typedName'].set('Ah Lian');
      expect(component['nameMatches']()).toBe(true);
    });

    it('accepts the name in any case, with spaces around it', () => {
      // The point is that somebody read the name, not that they can reproduce
      // its capitals.
      load([person()]);
      component['startDeactivating'](person());

      component['typedName'].set('  ah lian  ');
      expect(component['nameMatches']()).toBe(true);
    });

    it('sends nothing until the name matches', () => {
      load([person()]);
      component['startDeactivating'](person());
      component['typedName'].set('wrong');

      component['deactivate']();
      http.expectNone('/api/people/u1/deactivate');
    });

    it('says how many handsets it stopped', () => {
      // §12: sessions never expire, so that number is what somebody
      // deactivating a leaver actually wants to know.
      load([person()]);
      component['startDeactivating'](person());
      component['typedName'].set('Ah Lian');
      component['deactivate']();

      http
        .expectOne('/api/people/u1/deactivate')
        .flush({ person: person({ is_active: false }), sessions_revoked: 2 });
      http.expectOne('/api/people').flush({ people: [] });
      fixture.detectChanges();

      expect(text()).toContain('2 handset(s) signed out');
    });

    it('does not claim handsets were stopped when none were', () => {
      load([person()]);
      component['startDeactivating'](person());
      component['typedName'].set('Ah Lian');
      component['deactivate']();

      http
        .expectOne('/api/people/u1/deactivate')
        .flush({ person: person({ is_active: false }), sessions_revoked: 0 });
      http.expectOne('/api/people').flush({ people: [] });
      fixture.detectChanges();

      expect(text()).toContain('can no longer sign in');
      expect(text()).not.toContain('handset(s) signed out');
    });

    it('backing out sends nothing and forgets what was typed', () => {
      load([person()]);
      component['startDeactivating'](person());
      component['typedName'].set('Ah Lian');
      component['cancelDeactivating']();
      fixture.detectChanges();

      expect(component['confirming']()).toBeNull();
      expect(component['typedName']()).toBe('');
      http.expectNone('/api/people/u1/deactivate');
    });
  });

  describe('letting somebody back in', () => {
    it('says they will have to sign in again', () => {
      // Their old sessions stay revoked, so somebody expecting the phone in
      // the drawer to work again is told otherwise.
      load([person({ is_active: false })]);
      component['reactivate'](person());

      http.expectOne('/api/people/u1/reactivate').flush(person());
      http.expectOne('/api/people').flush({ people: [person()] });
      fixture.detectChanges();

      expect(text()).toContain('They will have to');
    });

    it('a second click before the first response lands sends only one', () => {
      load([person({ is_active: false })]);
      component['reactivate'](person());
      expect(component['saving']()).toBe(true);

      component['reactivate'](person());

      http.expectOne('/api/people/u1/reactivate').flush(person());
      http.expectOne('/api/people').flush({ people: [person()] });
    });
  });

  describe('adding somebody', () => {
    it('the button sends it', () => {
      // Driven through the DOM on purpose. Every other test here calls
      // `add()`, which is exactly what let the form go out bound to
      // `(ngSubmit)` without FormsModule — a DOM event nothing ever fires, so
      // the Add button did nothing and no assertion in this file could tell.
      load([]);
      const open = [...fixture.nativeElement.querySelectorAll('button')].find(
        (b: HTMLButtonElement) => b.textContent?.trim() === 'Add somebody',
      ) as HTMLButtonElement;
      open.click();
      fixture.detectChanges();

      const set = (id: string, value: string): void => {
        const input = fixture.nativeElement.querySelector(
          `#${id}`,
        ) as HTMLInputElement;
        input.value = value;
        input.dispatchEvent(new Event('input'));
        fixture.detectChanges();
      };
      set('name', 'Ah Lian');
      set('phone', '0123456789');
      set('pin', '4821');

      const add = [...fixture.nativeElement.querySelectorAll('button')].find(
        (b: HTMLButtonElement) => b.textContent?.trim() === 'Add',
      ) as HTMLButtonElement;
      add.click();
      fixture.detectChanges();

      const req = http.expectOne('/api/people');
      expect(req.request.method).toBe('POST');
      expect(req.request.body.name).toBe('Ah Lian');
    });

    it('a second click before the first response lands sends only one', () => {
      // Bug hunt, 2026-09-09. Nothing here disabled the button mid-request,
      // so a double click (or a double Enter) fired the POST twice.
      load([]);
      component['name'].set('Ah Lian');
      component['phone'].set('0123456789');
      component['pin'].set('4821');
      component['add']();
      expect(component['canAdd']()).toBe(false);

      component['add']();

      http.expectOne('/api/people').flush(person());
      http.expectOne('/api/people').flush({ people: [person()] });
    });

    it('will not send until there is a name, a phone and a PIN', () => {
      load([]);
      expect(component['canAdd']()).toBe(false);

      component['name'].set('Ah Lian');
      expect(component['canAdd']()).toBe(false);
      component['phone'].set('0123456789');
      expect(component['canAdd']()).toBe(false);
      component['pin'].set('4821');
      expect(component['canAdd']()).toBe(true);
    });

    it('clears the PIN from memory as soon as it is accepted', () => {
      load([]);
      component['name'].set('Ah Lian');
      component['phone'].set('0123456789');
      component['pin'].set('4821');
      component['add']();

      const req = http.expectOne('/api/people');
      expect(req.request.body.pin).toBe('4821');
      req.flush(person());
      http.expectOne('/api/people').flush({ people: [person()] });
      fixture.detectChanges();

      expect(component['pin']()).toBe('');
      expect(text()).not.toContain('4821');
    });

    it('says a taken phone plainly rather than as a 409', () => {
      load([]);
      component['name'].set('Ah Lian');
      component['phone'].set('0123456789');
      component['pin'].set('4821');
      component['add']();

      http
        .expectOne('/api/people')
        .flush({ detail: 'taken' }, { status: 409, statusText: 'Conflict' });
      fixture.detectChanges();

      expect(text()).toContain('already signs in with that number');
    });

    it('explains a refused PIN rather than showing a bare 422', () => {
      load([]);
      component['name'].set('Ah Lian');
      component['phone'].set('0123456789');
      component['pin'].set('0000');
      component['add']();

      http.expectOne('/api/people').flush(
        { detail: 'weak' },
        { status: 422, statusText: 'Unprocessable' },
      );
      fixture.detectChanges();

      expect(text()).toContain('four or more digits');
    });
  });

  describe('removing access, driven the way somebody does it', () => {
    // §11 Phase 5's acceptance criterion is *deactivating a user requires
    // typing their name*. Everything above proves the rule; none of it proves
    // the screen. If the confirm button's binding were dead, or the box not
    // wired to what the button reads, `nameMatches()` would still be right and
    // the criterion would still be unmet.
    //
    // Sessions never expire (§12), so this dialog is the only thing that stops
    // the handset in a leaver's pocket. It is worth clicking.

    const el = <T extends Element>(selector: string): T => {
      const found = fixture.nativeElement.querySelector(selector) as T | null;
      if (found === null) throw new Error(`no ${selector} on the screen`);
      return found;
    };

    const rowButton = (index: number): HTMLButtonElement => {
      const cells = fixture.nativeElement.querySelectorAll('td.actions');
      const button = (cells[index] as HTMLElement).querySelector('button');
      if (button === null) throw new Error(`row ${index} has no button`);
      return button as HTMLButtonElement;
    };

    const click = (selector: string): void => {
      el<HTMLButtonElement>(selector).click();
      fixture.detectChanges();
    };

    const typeName = (value: string): void => {
      const box = el<HTMLInputElement>('#typed');
      box.value = value;
      box.dispatchEvent(new Event('input'));
      fixture.detectChanges();
    };

    it('the row button opens the dialog for that person', () => {
      load([person({ id: 'u1', name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);

      rowButton(1).click();
      fixture.detectChanges();

      // The second row's person, not the first. A dialog that opened on
      // whoever was at the top would lock out the wrong person on a click
      // that looked right.
      expect(el('[role="dialog"]').textContent).toContain('Siti');
    });

    it('the confirm button does nothing until the name is typed', () => {
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);
      rowButton(1).click();
      fixture.detectChanges();

      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(true);
      typeName('Sit');
      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(true);

      // And pressing it anyway sends nothing. The disabled attribute is the
      // presentation; the refusal has to be real.
      el<HTMLButtonElement>('.confirm .danger').click();
      fixture.detectChanges();
      http.expectNone('/api/people/u2/deactivate');
    });

    it('typing the name and pressing it removes that person', () => {
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);
      rowButton(1).click();
      fixture.detectChanges();

      typeName('Siti');
      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(false);
      click('.confirm .danger');

      const req = http.expectOne('/api/people/u2/deactivate');
      expect(req.request.method).toBe('POST');
      req.flush({ id: 'u2', sessions_revoked: 2 });
      http.expectOne('/api/people').flush({ people: [person()] });
      fixture.detectChanges();

      expect(text()).toContain('2 handset(s) signed out');
      expect(fixture.nativeElement.querySelector('[role="dialog"]')).toBeNull();
    });

    it('a second click before the response lands sends only one deactivate', () => {
      // Bug hunt, 2026-09-09. The button stayed enabled through the whole
      // request, since `nameMatches` never considered one in flight.
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);
      rowButton(1).click();
      fixture.detectChanges();

      typeName('Siti');
      click('.confirm .danger');
      fixture.detectChanges();
      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(true);

      click('.confirm .danger');

      http
        .expectOne('/api/people/u2/deactivate')
        .flush({ id: 'u2', sessions_revoked: 2 });
      http.expectOne('/api/people').flush({ people: [person()] });
    });

    it('the case of the typed name does not matter, the person does', () => {
      // The point is that somebody read the name, not that they can reproduce
      // its capitals.
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);
      rowButton(1).click();
      fixture.detectChanges();

      typeName('  siti  ');
      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(false);
    });

    it('typing the OTHER person’s name does not unlock it', () => {
      // The failure this criterion exists to prevent, in its exact shape:
      // the dialog is open on Siti and the name in front of the reader is
      // Ah Lian's, from the row above.
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);
      rowButton(1).click();
      fixture.detectChanges();

      typeName('Ah Lian');
      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(true);
    });

    it('"Keep it" closes the dialog and sends nothing', () => {
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);
      rowButton(1).click();
      fixture.detectChanges();
      typeName('Siti');

      const keep = Array.from(
        fixture.nativeElement.querySelectorAll('.confirm .actions button'),
      )[1] as HTMLButtonElement;
      keep.click();
      fixture.detectChanges();

      expect(fixture.nativeElement.querySelector('[role="dialog"]')).toBeNull();
      http.expectNone('/api/people/u2/deactivate');
    });

    it('re-opening the dialog does not carry the last typed name over', () => {
      // Otherwise the second removal needs no confirmation at all, which is
      // the criterion quietly not applying to the person after the first.
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);
      rowButton(1).click();
      fixture.detectChanges();
      typeName('Siti');

      const keep = Array.from(
        fixture.nativeElement.querySelectorAll('.confirm .actions button'),
      )[1] as HTMLButtonElement;
      keep.click();
      fixture.detectChanges();

      rowButton(1).click();
      fixture.detectChanges();
      expect(el<HTMLInputElement>('#typed').value).toBe('');
      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(true);
    });

    it('"Let back in" is the button a leaver’s row offers', () => {
      load([person({ id: 'u2', name: 'Siti', is_active: false })]);

      rowButton(0).click();
      fixture.detectChanges();

      http.expectOne('/api/people/u2/reactivate').flush(person({ id: 'u2' }));
      fixture.detectChanges();
      expect(text()).toContain('They will have to');
    });

    it('the criterion holds in Malay too', async () => {
      // §11 Phase 5's acceptance criterion is that removing access requires
      // typing the person's name — not that it requires typing it in English.
      // The name goes UNDER the instruction rather than inside it, so the
      // sentence needs no word order of its own in any of the three.
      i18n.pick('ms');
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);

      rowButton(1).click();
      fixture.detectChanges();
      expect(text()).toContain('Tarik balik akses Siti?');
      expect(text()).toContain('Taip nama ini untuk mengesahkan');
      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(true);

      typeName('Siti');
      expect(el<HTMLButtonElement>('.confirm .danger').disabled).toBe(false);
      click('.confirm .danger');

      http
        .expectOne('/api/people/u2/deactivate')
        .flush({ id: 'u2', sessions_revoked: 2 });
      http.expectOne('/api/people').flush({ people: [person()] });
      fixture.detectChanges();

      expect(text()).toContain('2 telefon telah log keluar');
    });

    it('a note already on screen follows a language change', () => {
      // The note names a person and a number of handsets, and somebody may be
      // reading it out to them. Composing it at the click would freeze it.
      load([person({ name: 'Ah Lian' }), person({ id: 'u2', name: 'Siti' })]);
      rowButton(1).click();
      fixture.detectChanges();
      typeName('Siti');
      click('.confirm .danger');
      http
        .expectOne('/api/people/u2/deactivate')
        .flush({ id: 'u2', sessions_revoked: 0 });
      http.expectOne('/api/people').flush({ people: [person()] });
      fixture.detectChanges();
      expect(text()).toContain('Siti can no longer sign in');

      i18n.pick('zh');
      fixture.detectChanges();
      expect(text()).toContain('Siti 不能再登入了');
      expect(text()).not.toContain('can no longer sign in');
    });

    it('an admin’s own row offers no button at all', () => {
      // Locking the last admin out is the one mistake nobody can undo from
      // the app.
      session.user.set({ id: 'u1', name: 'Boss', role: 'admin', language: 'en' });
      load([person({ id: 'u1', name: 'Boss', role: 'admin' })]);

      const cells = fixture.nativeElement.querySelectorAll('td.actions');
      expect((cells[0] as HTMLElement).querySelector('button')).toBeNull();
      expect((cells[0] as HTMLElement).textContent).toContain('You');
    });
  });
});
