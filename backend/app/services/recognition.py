"""AI-assisted floor-plan recognition. SPEC.md Phase 8, "Future: assisted
digitisation".

    uploaded plan -> AI extracts rooms, openings, dimensions -> CONFIDENCE
                  -> human verification -> approved version -> library

**Never production truth.** This module only ever proposes a set of openings
and rooms with a confidence per value; nothing here writes to the database,
and nothing it returns can become a unit type version except through the
existing human-typed path in `library.py` (`create_unit_type` /
`add_corrected_version` / `submit_from_device`) -- the same rule that already
keeps a part-timer's own submission out of the library until an admin
approves it. A proposal is a faster way to fill that form in, never a
shortcut past it.

## Providers are swappable, and three real ones now exist

A `RecognitionProvider` is anything with an `extract` method, chosen at
runtime by `get_recognition_provider()` from two environment variables
(`RECOGNITION_PROVIDER`, `RECOGNITION_MODEL`). `NullRecognitionProvider`
stays the default (`RECOGNITION_PROVIDER` unset, or any name it does not
recognise) -- it recognises nothing, says so plainly, and costs nothing.
`recognition_providers.py` now also registers `anthropic`, `openai` and
`gemini`, each calling out to a hosted vision model and each individually
disabled until its own API key is set (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GEMINI_API_KEY`) -- so going live is entirely a config change on a box that
already has this code deployed: set `RECOGNITION_PROVIDER` and the matching
key, nothing here changes. Each also reads its own `_BASE_URL` env var, so
any of the three doubles as the adapter for a self-hosted model later,
wrapped to speak that vendor's API shape, with no new code.

*Which* of the three (or none) actually runs in production remains a real
commercial decision -- cost per call, and whether a developer's floor plan is
consistent enough to be worth trusting at all -- that this module still does
not make for anyone; it only makes trying any of them, or switching between
them, cost nothing but an environment variable. Callers (the `/api/recognize`
route, the dashboard's and the handset's own "try recognition" buttons) were
built and tested against the placeholder's contract before any of this
existed, so none of them changed to support it.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Protocol


@dataclass(frozen=True)
class ProposedOpening:
    """One window or door the provider thinks it saw. Display-only until a
    person copies it into the form -- never written to `Opening` directly.

    `nominal_w_tmm`/`nominal_h_tmm` are the opening itself -- the glass or
    frame, not the curtain. `suggested_track_w_tmm`/`suggested_drop_h_tmm`
    are a separate, honest judgement about the *product*: a track commonly
    runs wider than the window it dresses, and a drop commonly runs closer
    to the ceiling than the window's own top edge, when the wall around the
    opening has room for either. Both stay `None` rather than a guessed
    "typical" number when the provider has nothing to base one on.

    A floor plan is a top-down drawing: it can show wall space beside an
    opening (so a wider track fits), but it does not show elevation, so it
    essentially never shows a ceiling height -- `suggested_drop_h_tmm` stays
    `None` in the overwhelming majority of cases, and should only be filled
    from a ceiling height actually printed on the plan, never estimated
    from "what ceilings are usually". A confident-looking number here that
    turns out to be fabricated is worse than none.
    """

    label: str
    room: str
    nominal_w_tmm: int
    nominal_h_tmm: int
    #: 0..1. Never used for pricing or for a decision of any kind; shown to
    #: the reviewer so a low-confidence guess reads differently from a
    #: confident one.
    confidence: float
    #: A track/rail width accounting for visible wall space beside the
    #: opening -- still a suggestion, confirmed or corrected at the real
    #: site visit like everything else this library proposes.
    suggested_track_w_tmm: int | None = None
    #: A drop accounting for a *printed* ceiling height only -- see the
    #: class docstring for why this is almost always None.
    suggested_drop_h_tmm: int | None = None


@dataclass(frozen=True)
class ProposedRoom:
    name: str
    nominal_area_mm2: int
    confidence: float


@dataclass(frozen=True)
class ExtractionResult:
    #: False for the placeholder and for any provider missing its API key/
    #: model config -- lets a caller show "not configured" rather than an
    #: empty result that looks like "the plan has nothing on it".
    configured: bool
    #: The provider's registry name, e.g. "none" -- shown in diagnostics so a
    #: mismatch between what an admin set and what actually ran is visible.
    provider: str
    openings: list[ProposedOpening] = field(default_factory=list)
    rooms: list[ProposedRoom] = field(default_factory=list)
    #: A short human-readable note, in English -- this is a diagnostics/admin
    #: surface, not customer-facing copy, so it is exempt from the trilingual
    #: rule that governs everything in the mobile and dashboard UIs.
    note: str = ""


class RecognitionProvider(Protocol):
    name: str

    def extract(self, *, image_data: bytes, content_type: str) -> ExtractionResult: ...


class NullRecognitionProvider:
    """The placeholder in force until a real provider is chosen.

    Proposes nothing, every time, deterministically, with no network call and
    no cost -- so the whole review-and-prefill UI can be built and tested
    against a stable contract before any model is picked. The empty result is
    not an error state; `configured=False` is what tells a caller that.
    """

    name = "none"

    def __init__(self, model: str | None = None) -> None:
        # Unused by the placeholder. Kept so every provider's constructor has
        # the same shape (`model` is what `RECOGNITION_MODEL` feeds), which is
        # what lets `get_recognition_provider` construct any of them the same
        # way without a per-provider special case.
        self.model = model

    def extract(self, *, image_data: bytes, content_type: str) -> ExtractionResult:
        _ = image_data, content_type
        return ExtractionResult(
            configured=False,
            provider=self.name,
            note=(
                "AI recognition is not configured yet -- enter openings and "
                "rooms from the developer's schedule."
            ),
        )


#: Registered by name, looked up from `RECOGNITION_PROVIDER`. Adding a real
#: provider is: implement `RecognitionProvider`, add it here under a new
#: name, and point the env var at it -- no caller of `get_recognition_provider`
#: changes.
#:
#: Imported from `recognition_providers`, not defined here: this module is
#: the interface and the registry, and SPEC.md §14.7 draws the line at
#: "only its adapter" imports a vendor SDK -- `anthropic`/`openai`/
#: `google.genai` are that module's business, not this one's.
def _providers() -> dict[str, type]:
    from .recognition_providers import (
        AnthropicRecognitionProvider,
        GeminiRecognitionProvider,
        OpenAIRecognitionProvider,
    )

    return {
        "none": NullRecognitionProvider,
        "anthropic": AnthropicRecognitionProvider,
        "openai": OpenAIRecognitionProvider,
        "gemini": GeminiRecognitionProvider,
    }


def get_recognition_provider() -> RecognitionProvider:
    """Reads `RECOGNITION_PROVIDER` (default ``"none"``) and `RECOGNITION_MODEL`
    (passed through to whichever provider is selected; unused by the
    placeholder). Never raises on an unrecognised name -- an admin mistyping
    an env var should fall back to "recognition is off", not take the
    floor-plan screen down.
    """
    name = os.environ.get("RECOGNITION_PROVIDER", "none").strip().lower()
    model = os.environ.get("RECOGNITION_MODEL") or None
    provider_cls = _providers().get(name, NullRecognitionProvider)
    return provider_cls(model)
