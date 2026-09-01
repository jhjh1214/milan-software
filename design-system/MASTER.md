# Milan Quote — Design System

Source of truth for the mobile app's visual and interaction decisions.
Implemented in `mobile/lib/ui/theme.dart`; this file records **why**.

`SPEC.md` §8 is binding and wins over anything here. Where the two disagree,
§8 is right and this file is stale.

---

## The one constraint that decides everything

The app is used **standing, one-handed, in a bright hall, by someone hired last
week**, on their own low-end Android phone. Every choice below follows from
that, not from taste.

That is why two common recommendations were **rejected**:

| Rejected | Why |
|---|---|
| **Dark mode / OLED theme** | §8.1 forces light in the wizard. A dark system setting washes the screen out in daylight, and we do not control the staff's personal phones. The app ignores the system theme on purpose — the one place it does. |
| **Space Grotesk** (or any Latin-only display face) | No CJK coverage. Chinese would render as tofu boxes. |

## Type

**No bundled font.** Four weights of Noto Sans SC is roughly 40MB against the
`<30MB` bundle target in §12, and Flutter does not subset CJK text fonts the way
it tree-shakes icon fonts. Android ships Noto Sans CJK system-wide, so all three
languages fall back correctly for zero bytes. If a device is ever found showing
tofu, the fix is a `pyftsubset` build step over the strings we actually use — not
shipping the whole family.

Scale, from `AppText`. Nothing under 14sp, per §8.1.

| Token | Size | Weight | Use |
|---|---|---|---|
| `totalDisplay` | 34 | 700 | The running total. Tabular figures so it does not jitter as digits change. |
| `headline` | 24 | 600 | Step headings |
| `title` | 19 | 600 | Product and room names, list choices |
| `money` | 17 | 600 | Line prices. Tabular, so columns align. |
| `body` | 16 | 400 | Everything else |
| `label` | 15 | 500 | Field labels |
| `caption` | 14 | 400 | Entered-vs-billed, band labels |

## Colour

The invoice-and-billing family: navy with a money green. High contrast on white
is what survives sunlight.

| Token | Hex | Contrast | Use |
|---|---|---|---|
| `primary` | `#1E3A5F` | 11:1 on white | App bar, primary buttons, unit chip |
| `secondary` | `#2563EB` | — | Focused field border |
| `accent` | `#047857` | 4.6:1 with white text | Confirm key, money affirmations |
| `background` | `#F8FAFC` | — | Page. Faintly tinted, not pure white, to cut glare. |
| `foreground` | `#0F172A` | 16:1 | Body text |
| `mutedForeground` | `#56637A` | 4.6:1 | Secondary text — the lightest grey §8.1 permits |
| `destructive` | `#B91C1C` | — | Invalid input, delete |
| `warning` / `warningSurface` | `#92400E` / `#FEF3C7` | — | Soft warnings, and the reference-price disclaimer |
| `alarm` / `alarmSurface` | `#7F1D1D` / `#FEE2E2` | — | Provisional rate card banner |

The accent was darkened from the palette's `#059669`, which sits at 3.7:1 with
white text and fails AA for anything but large text.

## Spacing and touch

4dp rhythm (`Space`). Touch targets (`Touch`):

- **48dp** minimum for anything tappable
- **56dp** wizard primaries
- **64dp** keypad keys — hit hardest and fastest

## The keypad

`mobile/lib/ui/widgets/numeric_keypad.dart`. §8.1 calls this the widget that
removes most of the input friction in the app, and it earns that only if the
system keyboard never appears.

```
7  8  9   ⌫
4  5  6   尺 / ft
1  2  3   寸 / in
.  0  mm  好 / OK
```

It implements **"errors prevented, not reported"** literally: a key that would
produce input `SPEC.md` §5.3 must reject is disabled, not allowed and then
complained about. `7''6` cannot be typed. Disabled keys stay in place at reduced
opacity so the layout never shifts under a thumb already in motion.

## Interaction rules

- **One decision per screen.** Room → product → sizes. Back never loses input.
- **Undo, not confirm.** Deleting a line shows a 5-second undo snackbar. Modal
  confirmations get tapped through blindly under pressure.
- **The running total is pinned bottom-right**, in the largest type in the app.
  The part-timer and the customer both watch it.
- **Primary actions live in the bottom third**, where a thumb reaches.
- **Rates are never selectable.** Choosing a product shows no price at all —
  hard rule 8. Nothing selectable is nothing to get wrong.
- **Motion is 120–200ms**, meaningful, and never blocks input.

## Language

Three: `zh` (default), `en`, `ms`. Per user, not per device.

- Every user-visible string comes from `lib/l10n/*.arb`. A hardcoded string in a
  widget is a bug, and CI fails on any key missing from any language.
- **Wire values never reach the screen.** `PriceBasis.unit` returns `ft` and
  `sqft`; those are correct in JSON and wrong in front of a customer. Use
  `lib/ui/unit_labels.dart`. A line reading `按 13 ft 计` is half-translated,
  which reads worse than not translating at all.
- Malay uses `kaki` and `inci`, not `ft` and `in`.

## Two blocks that are not decoration

**The reference-price disclaimer** (`§8.5`) is permanent and non-dismissible on
every quote. The engine rounds every quoted quantity up and bills the exact
measurement later, so an unexplained quote reads as a bait price. Saying so is
what turns it into a reason to trust the number.

**The provisional rate-card banner** is deliberately alarming and appears
whenever `rate-card-seed.json` carries `"provisional": true`. It goes away when
the real price list arrives — by editing data, not code.
