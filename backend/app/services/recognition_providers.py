"""Real `RecognitionProvider` adapters. SPEC.md §14.7: a capability's own
code never imports a vendor SDK or names a vendor directly -- only its
adapter does. `recognition.py` stays the interface and the registry;
everything vendor-specific lives here.

Every adapter below shares the same shape:

- reads its own API key from the backend's environment, never from a
  request payload or a client -- SPEC.md §14.7's "credentials never leave
  the backend";
- also reads an optional custom base URL from its own env var, so any of
  the three can be pointed at a self-hosted, API-compatible server instead
  of the real vendor's endpoint. This is what lets a locally hosted model,
  wrapped later to speak one of these three protocols, plug in as a fourth
  option with no new code -- just `ANTHROPIC_BASE_URL` (or its OpenAI/
  Gemini equivalent) pointed at `http://<the box>:<port>` and that
  provider's own API key set to whatever the wrapper expects;
- never raises out of `extract()`. A missing key, an unreachable host, a
  timeout, a rate limit, or a response that does not fit the schema all
  become the same typed "not usable this time" result a caller already
  handles -- §14.7's reliability posture, treating every provider (hosted
  or a laptop's own wrapper) as an unreliable external service;
- forces structured output (a tool call, a function call, or a JSON
  schema, depending on what the vendor calls the same idea) rather than
  asking for JSON in prose and hoping -- "structured output is validated,
  not trusted" holds regardless, but a forced schema fails far less often
  than free text does;
- states the tenths-of-a-millimetre unit explicitly in the prompt. A
  vision model has no way to know this codebase's own invariant
  otherwise, and a plain-millimetre answer here would silently violate it
  by a factor of ten on every dimension.

`RECOGNITION_TIMEOUT_SECONDS` (default 120) bounds every call, all three
vendors alike. A real hosted vendor answers in a few seconds; 120s is
already generous. A locally hosted model wrapped behind one of these,
running on modest hardware, is the case this needs raising for -- tested
directly against a real local model on a genuinely complex ten-room plan,
generation ran at roughly 3 tokens/second, so a detailed plan's full
reasoning-plus-answer can take several minutes. A timeout is not a bug to
fix here: it is the same "not usable this time" result a missing key or a
malformed response already produces (see above), so raising this one
number is the whole adjustment needed for slow hardware -- nothing about
the request shape changes.
"""

from __future__ import annotations

import base64
import json
import logging
import os

import anthropic
from google import genai
from google.genai import types as genai_types
from openai import OpenAI

from .recognition import ExtractionResult, ProposedOpening, ProposedRoom

logger = logging.getLogger(__name__)

_DEFAULT_TIMEOUT_SECONDS = 120


def _timeout_seconds() -> float:
    raw = os.environ.get("RECOGNITION_TIMEOUT_SECONDS")
    if not raw:
        return _DEFAULT_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return _DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else _DEFAULT_TIMEOUT_SECONDS


_SYSTEM_PROMPT = (
    "You are assisting a curtain, blinds and flooring measurement business "
    "in reading a property developer's floor plan image. Identify every "
    "window and door opening ('openings') and every room with a floor "
    "('rooms') that you can make out.\n\n"
    "CRITICAL UNIT RULE: every dimension you output is an integer number of "
    "TENTHS OF A MILLIMETRE, never plain millimetres, never feet or inches. "
    "One metre is 10000. A window about 1.2m wide is roughly 12000 -- not "
    "1200, not 1.2. nominal_area_mm2 is a room's area in plain square "
    "millimetres (not tenths): a room of about 12 square metres is roughly "
    "12000000.\n\n"
    "These are rough estimates from a drawing, not a real tape measurement "
    "-- give an honest confidence from 0 to 1 per item rather than a "
    "uniformly high number. Use any printed scale or dimension labels on "
    "the plan if present; otherwise estimate from typical room and window "
    "proportions.\n\n"
    "For each opening, nominal_w_tmm/nominal_h_tmm are the window or door "
    "itself -- the frame, not the curtain. Separately, suggested_track_w_tmm "
    "is what a curtain track could reasonably span if you can see wall space "
    "beside the opening it could extend into (a window with walls close on "
    "both sides has no room to extend, so this should equal nominal_w_tmm or "
    "be left null; a window with visible wall space to one or both sides can "
    "suggest a wider track using that space). Set it to null rather than "
    "guess when you cannot judge the wall space from the drawing.\n\n"
    "suggested_drop_h_tmm is almost always null. A floor plan is a top-down "
    "drawing -- it essentially never shows ceiling height. Only fill this in "
    "if the plan itself prints a ceiling height or floor-to-ceiling "
    "dimension in text; never estimate a 'typical' ceiling height from "
    "nothing. A fabricated number here is worse than an honest null."
)

_USER_PROMPT = (
    "Read this floor plan and report every opening and every room you can "
    "identify, following the unit rule exactly."
)

_RESULT_SCHEMA = {
    "type": "object",
    "properties": {
        "openings": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "room": {"type": "string"},
                    "nominal_w_tmm": {"type": "integer"},
                    "nominal_h_tmm": {"type": "integer"},
                    "confidence": {"type": "number"},
                    "suggested_track_w_tmm": {"type": ["integer", "null"]},
                    "suggested_drop_h_tmm": {"type": ["integer", "null"]},
                },
                "required": [
                    "label",
                    "room",
                    "nominal_w_tmm",
                    "nominal_h_tmm",
                    "confidence",
                    "suggested_track_w_tmm",
                    "suggested_drop_h_tmm",
                ],
                "additionalProperties": False,
            },
        },
        "rooms": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "nominal_area_mm2": {"type": "integer"},
                    "confidence": {"type": "number"},
                },
                "required": ["name", "nominal_area_mm2", "confidence"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["openings", "rooms"],
    "additionalProperties": False,
}

_TOOL_NAME = "report_floor_plan"
_TOOL_DESCRIPTION = "Report every window/door opening and every room found."


def _optional_int(value: object) -> int | None:
    return None if value is None else int(value)


def _openings_from(raw: object) -> list[ProposedOpening]:
    if not isinstance(raw, list):
        return []
    out: list[ProposedOpening] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        try:
            out.append(
                ProposedOpening(
                    label=str(item["label"]),
                    room=str(item["room"]),
                    nominal_w_tmm=int(item["nominal_w_tmm"]),
                    nominal_h_tmm=int(item["nominal_h_tmm"]),
                    confidence=float(item["confidence"]),
                    suggested_track_w_tmm=_optional_int(
                        item.get("suggested_track_w_tmm")
                    ),
                    suggested_drop_h_tmm=_optional_int(
                        item.get("suggested_drop_h_tmm")
                    ),
                )
            )
        except (KeyError, TypeError, ValueError):
            # One malformed item does not sink the rest of the proposal --
            # whatever did parse may still be worth a person's look.
            continue
    return out


def _rooms_from(raw: object) -> list[ProposedRoom]:
    if not isinstance(raw, list):
        return []
    out: list[ProposedRoom] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        try:
            out.append(
                ProposedRoom(
                    name=str(item["name"]),
                    nominal_area_mm2=int(item["nominal_area_mm2"]),
                    confidence=float(item["confidence"]),
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    return out


class AnthropicRecognitionProvider:
    """Claude (or a local model wrapped to speak the Messages API), via
    vision plus a forced tool call for structured output."""

    name = "anthropic"

    def __init__(self, model: str | None = None) -> None:
        self.model = model or "claude-sonnet-5"

    def extract(self, *, image_data: bytes, content_type: str) -> ExtractionResult:
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            return ExtractionResult(
                configured=False,
                provider=self.name,
                note="ANTHROPIC_API_KEY is not set.",
            )

        client = anthropic.Anthropic(
            api_key=api_key,
            base_url=os.environ.get("ANTHROPIC_BASE_URL") or None,
            timeout=_timeout_seconds(),
        )

        try:
            message = client.messages.create(
                model=self.model,
                max_tokens=4096,
                system=_SYSTEM_PROMPT,
                tools=[
                    {
                        "name": _TOOL_NAME,
                        "description": _TOOL_DESCRIPTION,
                        "input_schema": _RESULT_SCHEMA,
                    }
                ],
                tool_choice={"type": "tool", "name": _TOOL_NAME},
                messages=[
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "image",
                                "source": {
                                    "type": "base64",
                                    "media_type": content_type,
                                    "data": base64.b64encode(image_data).decode(
                                        "ascii"
                                    ),
                                },
                            },
                            {"type": "text", "text": _USER_PROMPT},
                        ],
                    }
                ],
            )
        except Exception as exc:
            # Every failure mode a provider can produce -- timeout, refusal,
            # rate limit, a network error to a local wrapper that is not
            # actually running yet -- degrades to the same typed result
            # (SPEC.md §14.7), never an exception a caller must handle.
            logger.warning("Anthropic recognition call failed: %s", exc)
            return ExtractionResult(
                configured=True,
                provider=self.name,
                note=f"the request to Anthropic failed: {exc}",
            )

        tool_use = next(
            (b for b in message.content if getattr(b, "type", None) == "tool_use"),
            None,
        )
        if tool_use is None or not isinstance(tool_use.input, dict):
            return ExtractionResult(
                configured=True,
                provider=self.name,
                note="the model did not return a structured result.",
            )

        return ExtractionResult(
            configured=True,
            provider=self.name,
            openings=_openings_from(tool_use.input.get("openings")),
            rooms=_rooms_from(tool_use.input.get("rooms")),
        )


class OpenAIRecognitionProvider:
    """GPT (or a local model wrapped to speak the Chat Completions API), via
    vision plus a JSON-schema-constrained `response_format`.

    Not tool-calling, on purpose, unlike the Anthropic adapter: OpenAI's own
    `response_format` structured-output mode is built for exactly this --
    "answer only in this shape" -- rather than "decide whether to invoke an
    action," and it is what actually gets honoured wrapping this adapter
    around a local model server. A real Ollama-served vision model, tested
    directly: it silently ignores a forced `tool_choice` and answers in
    plain prose instead (Ollama's own OpenAI-compatibility docs list
    `tool_choice` as unsupported), but honours `response_format` and
    produces exactly the requested shape. Real OpenAI supports this mode
    natively too, so nothing is lost pointing this adapter at the real API
    instead of a local one.
    """

    name = "openai"

    def __init__(self, model: str | None = None) -> None:
        self.model = model or "gpt-5"

    def extract(self, *, image_data: bytes, content_type: str) -> ExtractionResult:
        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            return ExtractionResult(
                configured=False,
                provider=self.name,
                note="OPENAI_API_KEY is not set.",
            )

        client = OpenAI(
            api_key=api_key,
            base_url=os.environ.get("OPENAI_BASE_URL") or None,
            timeout=_timeout_seconds(),
        )
        data_url = (
            f"data:{content_type};base64,"
            f"{base64.b64encode(image_data).decode('ascii')}"
        )

        try:
            response = client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {
                        "role": "user",
                        "content": [
                            {"type": "image_url", "image_url": {"url": data_url}},
                            {"type": "text", "text": _USER_PROMPT},
                        ],
                    },
                ],
                response_format={
                    "type": "json_schema",
                    "json_schema": {
                        "name": _TOOL_NAME,
                        "schema": _RESULT_SCHEMA,
                        "strict": True,
                    },
                },
            )
        except Exception as exc:
            logger.warning("OpenAI recognition call failed: %s", exc)
            return ExtractionResult(
                configured=True,
                provider=self.name,
                note=f"the request to OpenAI failed: {exc}",
            )

        content = response.choices[0].message.content
        if not content:
            return ExtractionResult(
                configured=True,
                provider=self.name,
                note="the model did not return a structured result.",
            )

        try:
            data = json.loads(content)
        except json.JSONDecodeError:
            return ExtractionResult(
                configured=True,
                provider=self.name,
                note="the model's structured result was not valid JSON.",
            )

        return ExtractionResult(
            configured=True,
            provider=self.name,
            openings=_openings_from(data.get("openings")),
            rooms=_rooms_from(data.get("rooms")),
        )


class GeminiRecognitionProvider:
    """Gemini (or a local model wrapped to speak the same API), via vision
    plus a constrained JSON response schema."""

    name = "gemini"

    def __init__(self, model: str | None = None) -> None:
        self.model = model or "gemini-2.5-flash"

    def extract(self, *, image_data: bytes, content_type: str) -> ExtractionResult:
        api_key = os.environ.get("GEMINI_API_KEY")
        if not api_key:
            return ExtractionResult(
                configured=False,
                provider=self.name,
                note="GEMINI_API_KEY is not set.",
            )

        client = genai.Client(
            api_key=api_key,
            http_options=genai_types.HttpOptions(
                base_url=os.environ.get("GEMINI_BASE_URL") or None,
                timeout=int(_timeout_seconds() * 1000),
            ),
        )

        try:
            response = client.models.generate_content(
                model=self.model,
                contents=[
                    genai_types.Part.from_bytes(
                        data=image_data, mime_type=content_type
                    ),
                    f"{_SYSTEM_PROMPT}\n\n{_USER_PROMPT}",
                ],
                config=genai_types.GenerateContentConfig(
                    response_mime_type="application/json",
                    response_json_schema=_RESULT_SCHEMA,
                ),
            )
        except Exception as exc:
            logger.warning("Gemini recognition call failed: %s", exc)
            return ExtractionResult(
                configured=True,
                provider=self.name,
                note=f"the request to Gemini failed: {exc}",
            )

        text = getattr(response, "text", None)
        if not text:
            return ExtractionResult(
                configured=True,
                provider=self.name,
                note="the model did not return a structured result.",
            )

        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return ExtractionResult(
                configured=True,
                provider=self.name,
                note="the model's structured result was not valid JSON.",
            )

        return ExtractionResult(
            configured=True,
            provider=self.name,
            openings=_openings_from(data.get("openings")),
            rooms=_rooms_from(data.get("rooms")),
        )
