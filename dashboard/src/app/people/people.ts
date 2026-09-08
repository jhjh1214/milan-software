/**
 * Who can sign in, and who used to. SPEC.md §11 Phase 5, §12, §3.
 *
 * > Users and roles — individual PINs, deactivate leavers
 *
 * The acceptance criterion §11 names is that **deactivating a user requires
 * typing their name**. That is not friction for its own sake: sessions never
 * expire (§12), so deactivating is what stops the handset in a leaver's pocket,
 * and doing it to the wrong person silently locks somebody out mid-fair. Typing
 * the name is the cheapest way to make the click deliberate.
 *
 * Leavers stay on the list. A screen that hides them cannot answer "who used to
 * have access", which is the question somebody asks after something goes
 * missing.
 *
 * Nothing here is a permission check. The server refuses all of it to anybody
 * who is not an admin, and would refuse it identically if this file lied.
 *
 * Every field is a signal. A plain field read inside a `computed` never
 * recomputes, which would leave a button permanently disabled — and that is a
 * bug you find by clicking rather than by reading.
 */

import { CommonModule } from '@angular/common';
import { Component, computed, inject, signal } from '@angular/core';

import { Api } from '../api/api';
import { commonMessage, failureOf, type Failure } from '../i18n/failure';
import { Text } from '../i18n/text';
import { formatDate } from '../api/money';
import { Session } from '../auth/session';
import type { PersonOut, Role } from '../api/types';

/**
 * What just happened on this screen, before it becomes a sentence.
 *
 * A note names a person and sometimes a number of handsets, and somebody may
 * be reading it out to that person. Composing it at the moment of the click
 * would freeze it in whichever language was on screen then.
 */
type Note =
  | { readonly kind: 'added'; readonly name: string }
  | { readonly kind: 'reactivated'; readonly name: string }
  | {
      readonly kind: 'deactivated';
      readonly name: string;
      readonly handsets: number;
    };

@Component({
  selector: 'app-people',
  imports: [CommonModule],
  templateUrl: './people.html',
  styleUrl: './people.css',
})
export class People {
  private readonly api = inject(Api);
  private readonly session = inject(Session);

  protected readonly roles: readonly Role[] = ['parttime', 'staff', 'admin'];

  protected readonly people = signal<readonly PersonOut[]>([]);
  protected readonly loading = signal(false);
  protected readonly failure = signal<Failure | null>(null);

  /**
   * A write is in flight. Bug hunt, 2026-09-09: none of add/deactivate/
   * reactivate had one, so a double click (or a double Enter) before the
   * first request's response landed fired the request twice — the same
   * shape of gap `order-detail.ts`'s buyer form already closes with its own
   * `savingBuyer`.
   */
  protected readonly saving = signal(false);

  /**
   * What just happened, as what happened rather than as a sentence.
   *
   * The same reasoning as a failure: a note composed at the moment of the
   * click freezes in whichever language was on screen then, and this one
   * names a person and a number of handsets that somebody may well be
   * reading out to them.
   */
  protected readonly note = signal<Note | null>(null);

  /** The words, as a signal: switching language re-renders the roster. */
  protected readonly t = inject(Text).strings;

  protected noteText(note: Note): string {
    const words = this.t().people;
    switch (note.kind) {
      case 'added':
        return words.canSignInNow(note.name);
      case 'reactivated':
        return words.canSignInAgain(note.name);
      default:
        return note.handsets === 0
          ? words.cannotSignIn(note.name)
          : words.cannotSignInAndOut(note.name, note.handsets);
    }
  }

  /** Chosen at render time, so a failure on screen follows the language. */
  protected message(failure: Failure): string {
    const words = this.t().people;
    if (failure.status === 409) return words.phoneTaken;
    // The server refuses a PIN nobody should be issued. Saying which rule it
    // broke beats "422".
    if (failure.status === 422) return words.weakPin;
    if (failure.status === 403) return words.notAdmin;
    if (failure.status === 404) return words.noSuchPerson;
    if (failure.status === null) return words.wentWrong;
    return commonMessage(this.t(), failure);
  }

  /** The new-person form. */
  protected readonly adding = signal(false);
  protected readonly name = signal('');
  protected readonly phone = signal('');
  protected readonly pin = signal('');
  protected readonly role = signal<Role>('parttime');

  /** Who is being deactivated, and what has been typed to confirm it. */
  protected readonly confirming = signal<PersonOut | null>(null);
  protected readonly typedName = signal('');

  constructor() {
    this.load();
  }

  private load(): void {
    this.loading.set(true);
    this.failure.set(null);

    this.api.people().subscribe({
      next: (out) => {
        this.people.set(out.people);
        this.loading.set(false);
      },
      error: (err: unknown) => {
        this.people.set([]);
        this.failure.set(failureOf(err));
        this.loading.set(false);
      },
    });
  }

  protected retry(): void {
    this.load();
  }

  protected openAdd(): void {
    this.adding.set(true);
    this.note.set(null);
    this.failure.set(null);
  }

  protected readonly canAdd = computed(
    () =>
      !this.saving() &&
      this.name().trim().length > 0 &&
      this.phone().trim().length > 0 &&
      this.pin().length > 0,
  );

  /** The form's own submit, so Enter in a box adds rather than reloading. */
  protected submitAdd(event: Event): void {
    event.preventDefault();
    this.add();
  }

  protected add(): void {
    if (!this.canAdd()) return;
    this.failure.set(null);
    this.saving.set(true);

    this.api
      .addPerson({
        name: this.name().trim(),
        phone: this.phone().trim(),
        pin: this.pin(),
        role: this.role(),
      })
      .subscribe({
        next: (person) => {
          // The PIN leaves this browser's memory the moment it is accepted.
          this.pin.set('');
          this.name.set('');
          this.phone.set('');
          this.role.set('parttime');
          this.adding.set(false);
          this.saving.set(false);
          this.note.set({ kind: 'added', name: person.name });
          this.load();
        },
        error: (err: unknown) => {
          this.saving.set(false);
          this.failure.set(failureOf(err));
        },
      });
  }

  protected startDeactivating(person: PersonOut): void {
    this.confirming.set(person);
    this.typedName.set('');
    this.note.set(null);
  }

  protected cancelDeactivating(): void {
    this.confirming.set(null);
    this.typedName.set('');
  }

  /**
   * Whether the typed name matches. §11 Phase 5's acceptance criterion.
   *
   * Case and surrounding spaces ignored: the point is that somebody read the
   * name, not that they can reproduce its capitals.
   */
  protected readonly nameMatches = computed(() => {
    if (this.saving()) return false;
    const person = this.confirming();
    if (person === null) return false;
    return this.typedName().trim().toLowerCase() === person.name.toLowerCase();
  });

  protected deactivate(): void {
    const person = this.confirming();
    if (person === null || !this.nameMatches()) return;

    this.failure.set(null);
    this.saving.set(true);
    this.api.deactivate(person.id).subscribe({
      next: (out) => {
        this.confirming.set(null);
        this.typedName.set('');
        this.saving.set(false);
        this.note.set({
          kind: 'deactivated',
          name: person.name,
          handsets: out.sessions_revoked,
        });
        this.load();
      },
      error: (err: unknown) => {
        this.saving.set(false);
        this.failure.set(failureOf(err));
      },
    });
  }

  protected reactivate(person: PersonOut): void {
    if (this.saving()) return;
    this.failure.set(null);
    this.saving.set(true);
    this.api.reactivate(person.id).subscribe({
      next: () => {
        // Said out loud: their old handsets stay signed out, so somebody
        // expecting the phone in the drawer to work again is told otherwise.
        this.saving.set(false);
        this.note.set({ kind: 'reactivated', name: person.name });
        this.load();
      },
      error: (err: unknown) => {
        this.saving.set(false);
        this.failure.set(failureOf(err));
      },
    });
  }

  /** True for the signed-in admin's own row. */
  protected isMe(person: PersonOut): boolean {
    return this.session.user()?.id === person.id;
  }

  protected readonly date = formatDate;
}
