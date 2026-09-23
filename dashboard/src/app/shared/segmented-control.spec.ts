/**
 * The shared segmented control, tested in isolation -- the five screens
 * that use it (order board, products, publish-card, reports, measurement
 * queue) each keep their own existing specs pinning what happens on click;
 * this file is what pins the component's own contract.
 */

import { Component } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { describe, expect, it } from 'vitest';

import { SegmentedControl } from './segmented-control';

type Fruit = 'apple' | 'banana';

@Component({
  imports: [SegmentedControl],
  template: `
    <app-segmented-control
      [options]="options"
      [optionLabel]="label"
      [selected]="selected"
      [allLabel]="allLabel"
      [capitalize]="capitalize"
      (select)="picked = $event"
    />
  `,
})
class Host {
  options: readonly Fruit[] = ['apple', 'banana'];
  label = (f: Fruit): string => (f === 'apple' ? 'Apple' : 'Banana');
  selected: Fruit | null = null;
  allLabel: string | null = null;
  capitalize = false;
  picked: Fruit | null | undefined;
}

describe('SegmentedControl', () => {
  /** A fresh fixture per scenario, with its complete starting state set
   * before the first `detectChanges()` -- rather than mutating a host field
   * and re-checking, which Angular's dev-mode `NG0100` guard (rightly)
   * treats as a bug shape everywhere else in this app. */
  const create = (
    over: Partial<Pick<Host, 'selected' | 'allLabel' | 'capitalize'>> = {},
  ) => {
    const fixture = TestBed.createComponent(Host);
    Object.assign(fixture.componentInstance, over);
    fixture.detectChanges();
    return { fixture, host: fixture.componentInstance };
  };

  const buttons = (fixture: ReturnType<typeof create>['fixture']) =>
    Array.from(fixture.nativeElement.querySelectorAll('button')) as HTMLButtonElement[];

  it('renders one button per option, labelled by the given function', () => {
    const { fixture } = create();
    const labels = buttons(fixture).map((b) => b.textContent?.trim());
    expect(labels).toEqual(['Apple', 'Banana']);
  });

  it('clicking an option emits it', () => {
    const { fixture, host } = create();
    buttons(fixture)[1].click();
    expect(host.picked).toBe('banana');
  });

  it('reflects the selected option in class and aria-pressed', () => {
    const { fixture } = create({ selected: 'apple' });

    const [apple, banana] = buttons(fixture);
    expect(apple.classList.contains('on')).toBe(true);
    expect(apple.getAttribute('aria-pressed')).toBe('true');
    expect(banana.classList.contains('on')).toBe(false);
    expect(banana.getAttribute('aria-pressed')).toBe('false');
  });

  it('omits the "all" option entirely when no allLabel is given', () => {
    const { fixture } = create();
    expect(buttons(fixture).length).toBe(2);
  });

  it('an allLabel adds a first button that emits null and carries no aria-pressed', () => {
    const { fixture, host } = create({ allLabel: 'All' });

    const all = buttons(fixture)[0];
    expect(all.textContent?.trim()).toBe('All');
    // Matches the exact markup this replaced: only a real option reports
    // pressed state, never the synthetic "everything" one.
    expect(all.hasAttribute('aria-pressed')).toBe(false);

    all.click();
    expect(host.picked).toBeNull();
  });

  it('capitalize applies text-transform only when asked', () => {
    const off = create({ capitalize: false });
    expect(
      off.fixture.nativeElement
        .querySelector('app-segmented-control')!
        .classList.contains('capitalize'),
    ).toBe(false);

    const on = create({ capitalize: true });
    expect(
      on.fixture.nativeElement
        .querySelector('app-segmented-control')!
        .classList.contains('capitalize'),
    ).toBe(true);
  });
});
