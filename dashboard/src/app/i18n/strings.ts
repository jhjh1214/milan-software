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

/**
 * The measurement queue. §11 Phase 5, §13 C10.
 *
 * Every count is a function rather than a number dropped beside a noun.
 * English needs the plural `s`, Chinese needs a measure word and no plural at
 * all, and Malay needs neither — three shapes that cannot be assembled from
 * one template without one of them reading like a translation.
 */
export interface QueueStrings {
  readonly title: string;
  readonly show: string;
  readonly all: string;
  readonly unbooked: string;
  readonly booked: string;
  /** "12 jobs across 5 trips". */
  readonly jobsAcrossTrips: (jobs: number, trips: number) => string;
  readonly stillToMeasure: (lines: number) => string;
  readonly nothingWaiting: string;
  readonly noTripsMatch: string;
  readonly noName: string;
  readonly waiting: (days: number) => string;
  readonly someBooked: (booked: number, jobs: number) => string;
  readonly oneVisitCovers: (orders: number) => string;
  readonly noPhone: string;
  readonly pendingSync: string;
  readonly toMeasure: (unmeasured: number, lines: number) => string;
  readonly materialsToChoose: (materials: number) => string;
  readonly bookedOn: (date: string) => string;
  readonly notBooked: string;
  readonly tripTotal: (total: string, oldest: string) => string;
  readonly signedOut: string;
  readonly wentWrong: string;
}

/** The weekly override review. §6.5 — this screen *is* the control. */
export interface OverridesStrings {
  readonly title: string;
  readonly week: string;
  readonly earlier: string;
  readonly later: string;
  readonly quietWeek: string;
  /** "3 changes, RM -132.00 net" — the number to read before any row. */
  readonly netForWeek: (changes: number, net: string) => string;
  readonly caption: (from: string, to: string) => string;
  readonly who: string;
  readonly from: string;
  readonly to: string;
  readonly change: string;
  readonly why: string;
  readonly when: string;
  readonly notAdmin: string;
  readonly wentWrong: string;
}

/** The three roles. §3. Server-enforced; these are only what to call them. */
export interface RoleStrings {
  readonly admin: string;
  readonly staff: string;
  readonly parttime: string;
}

/** Who can sign in, and who used to. §11 Phase 5, §12. */
export interface PeopleStrings {
  readonly title: string;
  readonly addSomebody: string;
  readonly name: string;
  readonly phone: string;
  readonly pin: string;
  readonly role: string;
  readonly add: string;
  readonly status: string;
  readonly actions: string;
  readonly active: string;
  readonly left: (date: string) => string;
  readonly you: string;
  readonly removeAccess: string;
  readonly letBackIn: string;
  readonly keepIt: string;
  readonly removeTitle: (name: string) => string;
  readonly removeWhat: string;
  /**
   * The instruction, and the name is shown under it rather than inside it.
   *
   * §11 Phase 5's acceptance criterion is that removing access requires typing
   * the person's name. A sentence with the name embedded in it needs a
   * different word order in each language and puts markup in the middle of a
   * translated string; putting the name on its own line reads the same in all
   * three and keeps the emphasis where it belongs.
   */
  readonly typeToConfirm: string;
  readonly canSignInNow: (name: string) => string;
  readonly cannotSignIn: (name: string) => string;
  readonly cannotSignInAndOut: (name: string, handsets: number) => string;
  readonly canSignInAgain: (name: string) => string;
  readonly phoneTaken: string;
  readonly weakPin: string;
  readonly notAdmin: string;
  readonly noSuchPerson: string;
  readonly wentWrong: string;
}

/**
 * Publishing a price list. §11 Phase 5's first acceptance criterion.
 *
 * The one screen where a wrong word costs money directly: it sets the price of
 * everything, for every handset, on the next pull.
 */
export interface PublishStrings {
  readonly title: string;
  readonly whichList: string;
  readonly fair: string;
  readonly standard: string;
  readonly cardAsJson: string;
  readonly or: string;
  readonly showMeWhatChanges: string;
  readonly working: string;
  readonly publishThis: string;
  readonly publishing: string;
  readonly publishAnother: string;
  readonly publishedAs: (version: number) => string;
  readonly nothingWouldChange: (unchanged: number) => string;
  readonly summary: (
    changed: number,
    added: number,
    removed: number,
    unchanged: number,
  ) => string;
  readonly net: (amount: string) => string;
  readonly pricesThatMove: string;
  readonly product: string;
  readonly from: string;
  readonly to: string;
  readonly change: string;
  readonly productsThatDisappear: string;
  readonly wasPriced: (rate: string) => string;
  readonly newProducts: string;
  readonly liveNote: string;
  readonly notAdmin: string;
  readonly notACard: string;
  readonly versionMustGoUp: string;
  readonly wentWrong: string;
}

/** One order, and why its numbers are what they are. §6.3, §6.5, §10.3. */
export interface OrderStrings {
  readonly backToOrders: string;
  readonly numberPending: string;
  readonly noName: string;
  readonly estimate: string;
  readonly taken: string;
  /** §8.5, binding. The promise, in the reader's own language. */
  readonly referencePrice: string;
  readonly rateHeldTo: (date: string) => string;
  readonly whatWasOrdered: string;
  readonly sizeEstimate: (size: string) => string;
  readonly sizeMeasured: (estimate: string, measured: string) => string;
  /** "12 ft at RM 46.00 · up to 10ft · list v1 · held 20% off". */
  readonly basis: (
    quantity: string,
    unit: string,
    rate: string,
    band: string,
    version: number,
    discount: string,
  ) => string;
  readonly materialToChoose: string;
  readonly priceChangedByHand: string;
  readonly pricesChangedByHand: string;
  readonly movedBy: (before: string, after: string, who: string) => string;
  readonly whatHasHappened: string;
  readonly noSuchOrder: string;
  readonly signedOut: string;
  readonly wentWrong: string;
}

/** The buyer block on an order. §10.3, §13 C14. */
export interface BuyerStrings {
  readonly title: string;
  readonly whyOverThreshold: string;
  readonly whyRequested: string;
  readonly nobodyHasTaken: string;
  readonly name: string;
  readonly tin: string;
  readonly id: string;
  readonly address: string;
  readonly msic: string;
  readonly taken: string;
  readonly complete: string;
  readonly stillNeeded: string;
  readonly missingName: string;
  readonly missingIdentifier: string;
  readonly missingAddress: string;
  /** Hard rule 7: SQL Account is the sole issuer, and this says so. */
  readonly notAnIssuer: string;
  readonly addThese: string;
  readonly correctThese: string;
  readonly onlyWhatYouChange: string;
  readonly notStated: string;
  readonly askedForEinvoice: string;
  readonly fieldName: string;
  readonly fieldTin: string;
  readonly fieldIdType: string;
  readonly fieldIdNumber: string;
  readonly fieldAddress1: string;
  readonly fieldAddress2: string;
  readonly fieldCity: string;
  readonly fieldState: string;
  readonly fieldPostcode: string;
  readonly fieldMsic: string;
  readonly savedComplete: string;
  readonly savedIncomplete: string;
  readonly refusedStale: string;
  readonly refusedUnknown: string;
  readonly refusedOther: (reason: string) => string;
}

/** The four reports. §11 Phase 5, §6.2, §8.5, §13 C11. */
export interface ReportsStrings {
  readonly title: string;
  readonly variance: string;
  readonly fairs: string;
  readonly balances: string;
  readonly deposits: string;
  readonly notAdmin: string;
  readonly wentWrong: string;

  /** §8.5. Said BEFORE the table: read cold it accuses honest people. */
  readonly varianceBias: string;
  readonly nothingPricedYet: string;
  readonly varianceCaption: string;
  readonly salesperson: string;
  readonly priced: string;
  readonly awaiting: string;
  readonly estimated: string;
  readonly final: string;
  readonly varianceColumn: string;
  readonly overEstimate: string;
  readonly nobodyRecorded: string;

  readonly noFairsYet: string;
  readonly fairsCaption: string;
  readonly fair: string;
  readonly dates: string;
  readonly orders: string;
  readonly quoted: string;
  readonly depositsTaken: string;
  readonly ratesHeld: string;
  readonly noPromotion: string;

  /** §13 C11. Nothing on this report is ever called overdue. */
  readonly agedFromDeposit: string;
  readonly allEstimated: string;
  readonly someEstimated: string;
  readonly bucketRange: (from: number, to: number) => string;
  readonly bucketOver: (from: number) => string;
  readonly bucketOrders: (orders: number) => string;
  readonly outstandingOfWhich: (total: string, estimated: string) => string;
  readonly nothingOutstanding: string;
  readonly balancesCaption: string;
  readonly order: string;
  readonly customer: string;
  readonly stage: string;
  readonly sinceDeposit: string;
  readonly total: string;
  readonly paid: string;
  readonly balance: string;
  readonly days: (days: number) => string;
  readonly estimateMark: string;
  readonly pendingSync: string;
  readonly noName: string;

  readonly last: string;
  readonly weeks: (weeks: number) => string;
  readonly declinesNote: string;
  readonly declinesCaption: string;
  readonly category: string;
  readonly categoryCurtain: string;
  readonly categoryFlooring: string;
  readonly categoryWallpaper: string;
  readonly asked: string;
  readonly collected: string;
  readonly declined: string;
  readonly linesRemoved: string;
  readonly dismissed: string;
  readonly takeRate: string;
  readonly leftOnTheTable: string;
  readonly takeRateOf: (taken: number, asked: number) => string;
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
  readonly queue: QueueStrings;
  readonly overrides: OverridesStrings;
  readonly role: RoleStrings;
  readonly people: PeopleStrings;
  readonly publish: PublishStrings;
  readonly order: OrderStrings;
  readonly buyer: BuyerStrings;
  readonly reports: ReportsStrings;
}
