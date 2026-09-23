/**
 * The home screen. What needs attention, composed from what the dashboard
 * already fetches elsewhere -- no new backend read for the two admin-only
 * stats, and one shared with every screen for the third.
 */

import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController,
  provideHttpClientTesting,
} from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { beforeEach, describe, expect, it } from 'vitest';

import { Session } from '../auth/session';
import { Text } from '../i18n/text';
import { Home } from './home';

describe('Home', () => {
  let http: HttpTestingController;
  let session: Session;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting(), provideRouter([])],
    });
    http = TestBed.inject(HttpTestingController);
    session = TestBed.inject(Session);
    TestBed.inject(Text).pick('en');
  });

  const asAdmin = (): void => {
    session.user.set({ id: 'u1', name: 'Boss', role: 'admin', language: 'en' });
  };

  const asStaff = (): void => {
    session.user.set({ id: 'u2', name: 'Staff', role: 'staff', language: 'en' });
  };

  const create = (): { fixture: ComponentFixture<Home> } => {
    const fixture = TestBed.createComponent(Home);
    fixture.detectChanges();
    return { fixture };
  };

  const text = (fixture: ComponentFixture<Home>): string =>
    fixture.nativeElement.textContent as string;

  it('fetches the measurement queue count for anyone signed in', () => {
    asStaff();
    const { fixture } = create();

    const req = http.expectOne('/api/measurement-queue');
    req.flush({ groups: [], total_orders: 7 });
    fixture.detectChanges();

    expect(text(fixture)).toContain('7');
  });

  it('never fetches the two admin-only stats for a non-admin', () => {
    asStaff();
    const { fixture } = create();

    http.expectOne('/api/measurement-queue').flush({ groups: [], total_orders: 0 });
    fixture.detectChanges();

    http.expectNone((r) => r.url === '/api/unit-types');
    http.expectNone((r) => r.url === '/api/allocations');
    expect(fixture.nativeElement.querySelectorAll('.stat-card').length).toBe(1);
  });

  it('an admin sees all three stats, each fetched independently', () => {
    asAdmin();
    const { fixture } = create();

    expect(fixture.nativeElement.querySelectorAll('.stat-card').length).toBe(3);

    // The admin-only stats resolve first; the measurement queue (open to
    // everyone) is still loading. Neither should block the other.
    http
      .expectOne((r) => r.url === '/api/unit-types')
      .flush({ unit_types: [{}, {}] });
    http.expectOne((r) => r.url === '/api/allocations').flush({ allocations: [{}] });
    fixture.detectChanges();

    expect(text(fixture)).toContain('2');
    expect(text(fixture)).toContain('1');
    // Still loading: a skeleton, not a fabricated 0.
    expect(fixture.nativeElement.querySelector('.stat-skeleton')).toBeTruthy();

    http.expectOne('/api/measurement-queue').flush({ groups: [], total_orders: 5 });
    fixture.detectChanges();

    expect(text(fixture)).toContain('5');
    expect(fixture.nativeElement.querySelector('.stat-skeleton')).toBeFalsy();
  });

  it('a failed stat shows a dash, never a fabricated zero', () => {
    asStaff();
    const { fixture } = create();

    http
      .expectOne('/api/measurement-queue')
      .flush({ detail: 'no' }, { status: 500, statusText: 'x' });
    fixture.detectChanges();

    expect(text(fixture)).toContain('—');
    expect(text(fixture)).not.toContain('0');
  });

  it('each stat card links to its own screen', () => {
    asAdmin();
    const { fixture } = create();
    http.expectOne('/api/measurement-queue').flush({ groups: [], total_orders: 0 });
    http.expectOne((r) => r.url === '/api/unit-types').flush({ unit_types: [] });
    http.expectOne((r) => r.url === '/api/allocations').flush({ allocations: [] });
    fixture.detectChanges();

    const hrefs = Array.from(
      fixture.nativeElement.querySelectorAll('a.stat-card'),
    ).map((a) => (a as HTMLAnchorElement).getAttribute('href'));
    expect(hrefs).toEqual(['/measurement', '/library/review', '/inventory/allocations']);
  });
});
