/**
 * Every word the dashboard says, in the three languages it speaks.
 *
 * SPEC.md §13 **C9**, answered: *yes, the office needs Chinese and Malay.* The
 * handset has been trilingual since Phase 2 because §8 makes it one — a
 * part-timer who reads only Malay has to be able to quote — and the assumption
 * that the office is a smaller, more English-reading group was only ever an
 * assumption. It was wrong.
 *
 * ## Why a typed dictionary rather than `@angular/localize`
 *
 * Angular's own i18n is a **build-time** substitution: one bundle per locale,
 * chosen by URL or by deploy. CLAUDE.md requires the opposite — *"switchable
 * per user, not per device"* — and the server already tells us which language
 * a person reads, on `Identity.language`. A runtime lookup is what makes the
 * same page render differently for the two people sharing the office machine.
 *
 * ## Why an interface rather than JSON
 *
 * **A missing translation is a compile error.** `ZH` and `MS` are declared as
 * `Strings`, so a key added to the interface and forgotten in one language
 * fails `npm run build` — which is the same guarantee the handset gets from
 * its `l10n-missing.txt` check, obtained for free rather than from a step that
 * can be skipped.
 *
 * ## Messages with more than one value are functions
 *
 * Not templates with placeholders. CLAUDE.md records the trap three times over
 * on the handset: **gen-l10n orders positional placeholders alphabetically**,
 * so `{room}/{product}/{amount}` generates `(amount, product, room)` and the
 * arguments silently swap. A named function parameter cannot do that — the
 * compiler checks the call — and the argument order is the one written here.
 */

/** The three, in the order a picker offers them. Default first. */
export type Language = 'zh' | 'en' | 'ms';

/**
 * Default `zh`, per CLAUDE.md's conventions, and the picker offers the rest.
 *
 * The signed-in person's own language overrides this the moment they sign in;
 * this is only what the sign-in screen speaks before anybody has said who they
 * are.
 */
export const LANGUAGES: readonly Language[] = ['zh', 'en', 'ms'];

/** What each language calls itself. Never translated — that is the point. */
export const LANGUAGE_NAMES: Readonly<Record<Language, string>> = {
  zh: '中文',
  en: 'English',
  ms: 'Bahasa Melayu',
};

/** A wire value from `Identity.language`, if it is one we speak. */
export function asLanguage(raw: string | null | undefined): Language | null {
  return raw === 'zh' || raw === 'en' || raw === 'ms' ? raw : null;
}

/** Words that appear on more than one screen. */
export interface CommonStrings {
  readonly loading: string;
  readonly tryAgain: string;
  readonly reload: string;
  readonly cancel: string;
  readonly save: string;
  readonly saving: string;
  /** The server refused because the caller is not an admin. */
  readonly notAdmin: string;
  readonly signedOut: string;
  readonly noAnswer: string;
  readonly wentWrong: string;
  /** A status code nobody has written a sentence for yet. */
  readonly serverAnswered: (status: number) => string;
}

/** The order lifecycle, §6.6. The same words the handset uses. */
export interface StatusStrings {
  readonly confirmed: string;
  readonly measurement_booked: string;
  readonly measured: string;
  readonly material_selected: string;
  readonly in_production: string;
  readonly ready: string;
  readonly installed: string;
  readonly closed: string;
  readonly cancelled: string;
}

export interface NavStrings {
  readonly orders: string;
  readonly measurement: string;
  readonly priceChanges: string;
  readonly priceList: string;
  readonly reports: string;
  readonly people: string;
  readonly signOut: string;
  /** The label on the language picker, for a screen reader. */
  readonly language: string;
}

/** Where an order came from. §6.3. */
export interface ChannelStrings {
  readonly fair: string;
  readonly showroom: string;
  readonly home_visit: string;
  readonly referral: string;
  readonly phone: string;
}

export interface BoardStrings {
  readonly title: string;
  /** "Showing 50 of 512". Two numbers, so a function rather than a template. */
  readonly showing: (shown: number, total: number) => string;
  readonly stage: string;
  readonly whereFrom: string;
  readonly all: string;
  readonly nothingMatches: string;
  /** An order pushed from a handset that has not synced. Never invented. */
  readonly pendingSync: string;
  readonly noName: string;
  readonly taken: string;
  readonly rateHeldTo: (date: string) => string;
  readonly stillToMeasure: (lines: number) => string;
  readonly signedOut: string;
  readonly wentWrong: string;
}

export interface SignInStrings {
  readonly phone: string;
  readonly pin: string;
  readonly action: string;
  readonly busy: string;
  /** Never says which of the two was wrong. */
  readonly wrong: string;
  readonly throttled: string;
  readonly offline: string;
  readonly server: string;
}

/** Everything the dashboard can say, in one language. */
export interface Strings {
  readonly common: CommonStrings;
  readonly status: StatusStrings;
  readonly channel: ChannelStrings;
  readonly nav: NavStrings;
  readonly signIn: SignInStrings;
  readonly board: BoardStrings;
}
