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

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    fixture = TestBed.createComponent(People);
    component = fixture.componentInstance;
    http = TestBed.inject(HttpTestingController);
    session = TestBed.inject(Session);
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
  });

  describe('adding somebody', () => {
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
});
