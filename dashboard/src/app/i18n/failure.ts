/**
 * A request that did not work, kept as what happened rather than as a sentence.
 *
 * Every screen used to hold `signal<string | null>` and fill it with English at
 * the moment of failure. That freezes the message in whichever language was on
 * screen when the server answered, so switching language afterwards leaves one
 * line of the old one behind — on the line that is telling somebody why they
 * cannot see their work.
 *
 * Holding the status instead means the sentence is chosen at render time, from
 * the current dictionary, every time.
 */

import type { Strings } from './strings';

export interface Failure {
  /**
   * The HTTP status, `0` for "no answer at all", or `null` when the thing
   * thrown was not an `HttpErrorResponse` — a bug in our own code rather than
   * an answer from the server, and it must not be reported as one.
   */
  readonly status: number | null;
}

export function failureOf(err: unknown): Failure {
  if (typeof err === 'object' && err !== null && 'status' in err) {
    return { status: (err as { status: number }).status };
  }
  return { status: null };
}

/**
 * The sentences every screen says the same way.
 *
 * A screen with better words for one of these answers it before calling here —
 * "sign in again to see the board" beats "sign in again" when that is what the
 * reader is looking at.
 */
export function commonMessage(t: Strings, failure: Failure): string {
  const { status } = failure;
  if (status === null) return t.common.wentWrong;
  if (status === 0) return t.common.noAnswer;
  if (status === 401) return t.common.signedOut;
  if (status === 403) return t.common.notAdmin;
  return t.common.serverAnswered(status);
}
