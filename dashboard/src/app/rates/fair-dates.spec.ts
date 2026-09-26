/**
 * Setting when the fair runs, driven through the DOM -- what matters is that
 * an admin sees the consequence for every deposit before saving, that Save
 * stays shut until the dates as typed would be accepted, that the reason
 * travels with them, and that staff see the dates but never the control.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import type { FairDatesOut } from '../api/types';
import { Session } from '../auth/session';
import { Text } from '../i18n/text';
import { FairDates } from './fair-dates';

const AUGUST: FairDatesOut = {
  version: 1,
  code: 'MITC-2026-08',
  valid_from: '2026-08-28',
  valid_to: '2026-08-31',
};

describe('FairDates', () => {
  let fixture: ComponentFixture<FairDates>;
  let http: HttpTestingController;

  beforeEach(() => {
    sessionStorage.clear();
    localStorage.clear();
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    http = TestBed.inject(HttpTestingController);
    TestBed.inject(Text).pick('en');
  });

  afterEach(() => http.verify());

  const open = (role: 'admin' | 'staff', dates: FairDatesOut = AUGUST): void => {
    TestBed.inject(Session).user.set({
      id: 'u1',
      name: 'Someone',
      role,
      language: 'en',
    });
    fixture = TestBed.createComponent(FairDates);
    fixture.detectChanges();
    http.expectOne('/api/rate-cards/fair/dates').flush(dates);
    fixture.detectChanges();
  };

  const text = (): string => fixture.nativeElement.textContent as string;

  const el = <T extends Element>(selector: string): T => {
    const found = fixture.nativeElement.querySelector(selector) as T | null;
    if (found === null) throw new Error(`no ${selector} on the screen`);
    return found;
  };

  const button = (label: string): HTMLButtonElement | undefined =>
    Array.from(
      fixture.nativeElement.querySelectorAll('button') as NodeListOf<HTMLButtonElement>,
    ).find((b) => b.textContent?.trim().includes(label));

  const type = (selector: string, value: string): void => {
    const input = el<HTMLInputElement>(selector);
    input.value = value;
    input.dispatchEvent(new Event('input'));
    fixture.detectChanges();
  };

  const save = (): HTMLButtonElement => {
    const found = button('Save');
    if (!found) throw new Error('no Save button');
    return found;
  };

  const startEditing = (): void => {
    button('Change dates')!.click();
    fixture.detectChanges();
  };

  it('shows when the fair runs and when its holds end', () => {
    open('staff');
    expect(text()).toContain('MITC-2026-08');
    expect(text()).toContain('28 Aug 2026 – 31 Aug 2026');
    // The day after the fair ends, a year on.
    expect(text()).toContain('hold their price until 1 Sep 2027');
  });

  it('never offers staff the control', () => {
    open('staff');
    expect(button('Change dates')).toBeUndefined();
    expect(text()).toContain('Only an admin can change these.');
  });

  it('says so when the card has no dates at all', () => {
    open('admin', { version: 1, code: null, valid_from: null, valid_to: null });
    expect(text()).toContain('No fair dates are set');
  });

  it('shows the consequence of the dates as typed, before saving', () => {
    open('admin');
    startEditing();
    type('#fair-to', '2026-12-31');
    expect(text()).toContain('hold their price until 1 Jan 2028');
  });

  it('keeps Save shut until the edit would be accepted', () => {
    open('admin');
    startEditing();
    // Opened on the current dates: nothing has changed yet.
    expect(save().disabled).toBe(true);
    expect(text()).toContain('Those are already the dates.');

    type('#fair-code', 'MITC-2026-12');
    type('#fair-from', '2026-12-07');
    type('#fair-to', '2026-12-04');
    expect(text()).toContain('The last day is before the first.');
    expect(save().disabled).toBe(true);

    type('#fair-to', '2026-12-10');
    expect(text()).toContain('Say why');
    expect(save().disabled).toBe(true);

    type('#fair-reason', 'December fair booked');
    expect(save().disabled).toBe(false);
  });

  it('sends the dates with the reason, and reports the new version', () => {
    open('admin');
    let changedTo: number | null = null;
    fixture.componentInstance.changed.subscribe((v) => (changedTo = v));
    startEditing();
    type('#fair-code', ' MITC-2026-12 ');
    type('#fair-from', '2026-12-04');
    type('#fair-to', '2026-12-07');
    type('#fair-reason', ' December fair booked ');
    save().click();

    const req = http.expectOne('/api/rate-cards/fair/dates');
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual({
      code: 'MITC-2026-12',
      valid_from: '2026-12-04',
      valid_to: '2026-12-07',
      reason: 'December fair booked',
    });
    req.flush({
      version: 102,
      code: 'MITC-2026-12',
      valid_from: '2026-12-04',
      valid_to: '2026-12-07',
    });
    fixture.detectChanges();

    expect(changedTo).toBe(102);
    expect(text()).toContain('Saved as version 102');
    expect(text()).toContain('4 Dec 2026 – 7 Dec 2026');
    expect(text()).toContain('hold their price until 8 Dec 2027');
  });

  it('keeps the form open and says why when the server refuses', () => {
    open('admin');
    startEditing();
    type('#fair-to', '2026-09-01');
    type('#fair-reason', 'one more day');
    save().click();
    http
      .expectOne('/api/rate-cards/fair/dates')
      .flush({ detail: 'not allowed' }, { status: 403, statusText: 'Forbidden' });
    fixture.detectChanges();

    expect(text()).toContain('Only an admin can change the fair dates.');
    expect(el('#fair-reason')).toBeTruthy();
  });
});
