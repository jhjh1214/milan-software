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
import { formatDate } from '../api/money';
import { Session } from '../auth/session';
import type { PersonOut, Role } from '../api/types';

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
  protected readonly failure = signal<string | null>(null);
  protected readonly note = signal<string | null>(null);

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
        this.failure.set(describe(err));
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
          this.note.set(`${person.name} can sign in now.`);
          this.load();
        },
        error: (err: unknown) => this.failure.set(describe(err)),
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
    const person = this.confirming();
    if (person === null) return false;
    return this.typedName().trim().toLowerCase() === person.name.toLowerCase();
  });

  protected deactivate(): void {
    const person = this.confirming();
    if (person === null || !this.nameMatches()) return;

    this.failure.set(null);
    this.api.deactivate(person.id).subscribe({
      next: (out) => {
        this.confirming.set(null);
        this.typedName.set('');
        this.note.set(
          out.sessions_revoked === 0
            ? `${person.name} can no longer sign in.`
            : `${person.name} can no longer sign in. ` +
              `${out.sessions_revoked} handset(s) signed out.`,
        );
        this.load();
      },
      error: (err: unknown) => this.failure.set(describe(err)),
    });
  }

  protected reactivate(person: PersonOut): void {
    this.failure.set(null);
    this.api.reactivate(person.id).subscribe({
      next: () => {
        // Said out loud: their old handsets stay signed out, so somebody
        // expecting the phone in the drawer to work again is told otherwise.
        this.note.set(`${person.name} can sign in again. They will have to.`);
        this.load();
      },
      error: (err: unknown) => this.failure.set(describe(err)),
    });
  }

  /** True for the signed-in admin's own row. */
  protected isMe(person: PersonOut): boolean {
    return this.session.user()?.id === person.id;
  }

  protected readonly date = formatDate;
}

function describe(err: unknown): string {
  if (typeof err === 'object' && err !== null && 'status' in err) {
    const status = (err as { status: number }).status;
    if (status === 409) return 'Somebody already signs in with that number.';
    // The server refuses a PIN nobody should be issued. Saying which rule it
    // broke beats "422".
    if (status === 422) {
      return 'Refused — check the PIN is four or more digits and not obvious.';
    }
    if (status === 403) return 'Only an admin can manage people.';
    if (status === 401) return 'Signed out. Sign in again.';
    if (status === 404) return 'That person no longer exists.';
    if (status === 0) return 'No answer from the server.';
    return `The server answered ${status}.`;
  }
  return 'Something went wrong.';
}
