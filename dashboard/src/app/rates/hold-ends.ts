/**
 * When every deposit taken at a fair stops holding its price. SPEC.md §6.1.
 *
 * Twelve months from the day AFTER the fair ends; the anniversary is the last
 * good day. Mirrors `hold_starts_on` + `twelve_months_from` on both engines,
 * which are the authority -- this is only so an admin setting the dates sees
 * the consequence before saving them.
 *
 * Calendar arithmetic on the `YYYY-MM-DD` parts, never through a `Date` and
 * its timezone: `new Date('2026-08-31')` is UTC midnight, which is still 30
 * August anywhere west of Greenwich.
 */
export function holdEndsOn(fairEndsOn: string): string | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(fairEndsOn);
  if (match === null) return null;
  let [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  if (month < 1 || month > 12 || day < 1 || day > daysIn(year, month)) return null;

  // The day after the fair ends.
  day += 1;
  if (day > daysIn(year, month)) {
    day = 1;
    month += 1;
    if (month > 12) {
      month = 1;
      year += 1;
    }
  }

  // Its anniversary, clamped to the month's end: 29 Feb has none.
  year += 1;
  day = Math.min(day, daysIn(year, month));
  return `${year}-${pad(month)}-${pad(day)}`;
}

function daysIn(year: number, month: number): number {
  const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
}

function pad(n: number): string {
  return n.toString().padStart(2, '0');
}
