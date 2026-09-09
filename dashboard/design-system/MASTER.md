# Milan Dashboard — Design System

Source of truth for the office web dashboard's visual decisions. Implemented
in `dashboard/src/styles.css` (tokens and shared classes); this file records
**why**. `mobile/design-system/MASTER.md` is the sibling document for the
handset — the two apps share a business and a rough palette lineage, and
diverge everywhere their actual constraints diverge.

CLAUDE.md is binding and wins over anything here. Where the two disagree,
CLAUDE.md is right and this file is stale.

---

## The one constraint that decides everything

This is used **sitting at a desk, with a screen, by office staff who spend
hours in it daily** — the opposite constraint from the handset, which is used
standing, one-handed, in a bright hall, for a few minutes at a time. That is
why the two apps' design systems make opposite calls on the same questions:

| Question | Mobile | Dashboard | Why they differ |
|---|---|---|---|
| Dark mode | Rejected outright (§8.1 forces light) | Full light **and** dark | A bright hall washes out a dark screen; an office at 6pm does not. Nobody controls the office's lighting the way §8.1 controls the wizard's. |
| Density | One decision per screen | Data-dense tables, filters, multi-column reports | A part-timer taps through a wizard once per customer; office staff scan fifty rows looking for one. |
| Touch targets | 48–64dp, thumb-first | 44px minimum, mouse-and-keyboard-first | Desk software is driven by a pointer and a keyboard far more than a finger. |

## Colour

Same family as the handset — navy with a money green — because it is one
business, but the values are **not** copied verbatim: the mobile palette was
tuned for direct sunlight on a phone screen, and re-deriving it for a desk
monitor in both light and dark surfaced a few different numbers.

Light:

| Token | Hex | Use |
|---|---|---|
| `--color-primary` | `#1E3A5F` | Header/nav underline, primary buttons, brand |
| `--color-accent` | `#2563EB` | Focus rings, links, "in progress" tint |
| `--color-success` | `#059669` | Paid, active, confirmed |
| `--color-warning` | `#D97706` | A rate hold running out, a wait getting long |
| `--color-danger` | `#DC2626` | Refusals, destructive actions, breaches of §8.5's promise |
| `--color-bg` / `--color-surface` | `#F8FAFC` / `#FFFFFF` | Page / card |
| `--color-fg` / `--color-fg-muted` | `#0F172A` / `#56637A` | Text / secondary text |

Dark is **not** light inverted — desaturated, lighter tonal variants of the
same roles, so navy becomes a muted blue-grey rather than going to near-black,
which is what an inverted brand colour does and why inversion is rejected here
the same way the handset rejects a system dark theme. Full values are in
`styles.css`'s `[data-theme='dark']` block.

Colour is never the only signal. A rate hold's urgency, a wait's severity, and
every refusal are all also said in words, next to the colour — the same rule
CLAUDE.md's `color-not-only` guidance names, and the one this codebase had
already half-adopted before this pass gave it a name.

## Three states, one shape

Both the language pick (`i18n/text.ts`) and the theme pick (`theme/theme.ts`)
resolve the same way, on purpose — a reader should not have to learn two
different mental models for "what does this app show me and why":

1. What was explicitly picked, this browser, right now
2. A fact about the person (their account's language) or the platform (the
   OS's `prefers-color-scheme`) — whichever the concept actually has
3. A default that always exists (`zh`; light)

The **persistence** differs deliberately: language follows the **account**
(`POST /api/auth/language`) because SPEC.md §13 C9 says it is a fact about the
person, portable to any machine. Theme is a `localStorage` **browser**
preference, because it is not a fact about the person — it is a preference
for what they are looking at, the boss and whoever borrows their desk for five
minutes can each have it their own way, and there is no reason to make it
follow anyone anywhere.

## Type

**Lexend** for headings, **Source Sans 3** for body — the "Corporate Trust"
pairing: Lexend was designed for reading proficiency, which matters more for
software read for hours than a display face would. Loaded from Google Fonts;
this app runs on a desk with a wire in it (CLAUDE.md), so unlike the handset
there is no bundle-size reason to avoid a web font.

Neither face carries CJK glyphs. That is not a gap to fill — the font stack
falls through to the OS's own CJK font for Chinese text, which is exactly the
handset's own reasoning for shipping no bundled font at all: the platform
already has a correct answer, and duplicating it just adds bytes.

16px body minimum, 1.5 line-height, per CLAUDE.md's own conventions elsewhere
in this repo.

## Spacing, radius, motion

4px rhythm (`--space-1` … `--space-7`, 4 to 48px). Two radii in practice:
`--radius-sm` (6px) for controls, `--radius-md` (10px) for cards. Motion is
120–200ms, transform/opacity only, and every animated rule has a
`prefers-reduced-motion` fallback that removes or freezes it — a dashboard
used all day is exactly where an unwanted motion preference matters most.

## Loading and empty states

Two rules, applied at every list and every fetch:

- **A skeleton, not a bare "loading" sentence**, wherever the eventual shape
  is known ahead of the data — a few grey bars in the shape of a card, a row,
  or a table. `.skeleton` in `styles.css`.
- **A sentence and an icon, never a blank area**, wherever a list can
  legitimately be empty. Some of these (an admin roster with nobody on it)
  cannot actually happen — signing in here means being one of the rows — but
  a blank screen still reads as broken rather than as quiet, so it gets a
  state anyway. `.empty-state`.

Both existed piecemeal before this pass — the order board and the measurement
queue already had real empty messages — this made them the rule rather than
the exception, and gave the boards a skeleton where before there was only a
line of text.

## What this pass did not touch

No new charts, no new navigation pattern, no animation beyond hover/focus and
the two loading primitives above. The nine screens' actual information
architecture — what each one shows and in what order — was already right;
this pass gave it one consistent skin, both themes, and the missing states,
not a redesign of what the office actually needs to see.
