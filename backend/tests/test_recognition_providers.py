"""The three real `RecognitionProvider` adapters. SPEC.md §14.7's reliability
posture, exercised directly: a missing key, a malformed response, and a
provider failure must all degrade to the same typed result, never raise.

No network call is made anywhere in this file -- each vendor SDK's client
class is replaced with a fake that returns a canned response shaped exactly
like the real one, so what is under test is this module's own parsing and
error handling, not any vendor's API actually answering.
"""

from __future__ import annotations

import json

import pytest

from app.services import recognition_providers as rp

# --- Anthropic ---------------------------------------------------------------


class _AnthropicBlock:
    def __init__(self, type_: str, input_: object = None) -> None:
        self.type = type_
        self.input = input_


class _AnthropicMessage:
    def __init__(self, content: list) -> None:
        self.content = content


class _FakeAnthropicMessages:
    def __init__(self, response=None, error: Exception | None = None) -> None:
        self._response = response
        self._error = error
        self.last_kwargs: dict = {}

    def create(self, **kwargs):
        self.last_kwargs = kwargs
        if self._error is not None:
            raise self._error
        return self._response


class _FakeAnthropicClient:
    def __init__(self, response=None, error: Exception | None = None, **init_kwargs):
        self.init_kwargs = init_kwargs
        self.messages = _FakeAnthropicMessages(response, error)


def _patch_anthropic(monkeypatch, *, response=None, error: Exception | None = None):
    captured: dict = {}

    def factory(**kwargs):
        captured["init_kwargs"] = kwargs
        client = _FakeAnthropicClient(response, error)
        captured["client"] = client
        return client

    monkeypatch.setattr(rp.anthropic, "Anthropic", factory)
    return captured


VALID_PAYLOAD = {
    "openings": [
        {
            "label": "Window 1",
            "room": "Living Room",
            "nominal_w_tmm": 12000,
            "nominal_h_tmm": 15000,
            "confidence": 0.8,
            "suggested_track_w_tmm": 13500,
            "suggested_drop_h_tmm": None,
        }
    ],
    "rooms": [{"name": "Living Room", "nominal_area_mm2": 12000000, "confidence": 0.7}],
}


class TestAnthropicRecognitionProvider:
    def test_missing_api_key_is_unconfigured_with_no_call_made(
        self, monkeypatch
    ) -> None:
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        captured = _patch_anthropic(monkeypatch)
        result = rp.AnthropicRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is False
        assert result.provider == "anthropic"
        assert "ANTHROPIC_API_KEY" in result.note
        assert captured == {}

    def test_a_valid_tool_use_response_is_parsed(self, monkeypatch) -> None:
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
        response = _AnthropicMessage([_AnthropicBlock("tool_use", VALID_PAYLOAD)])
        _patch_anthropic(monkeypatch, response=response)

        result = rp.AnthropicRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert result.configured is True
        assert result.provider == "anthropic"
        assert len(result.openings) == 1
        assert result.openings[0].label == "Window 1"
        assert result.openings[0].nominal_w_tmm == 12000
        assert result.openings[0].suggested_track_w_tmm == 13500
        assert result.openings[0].suggested_drop_h_tmm is None
        assert len(result.rooms) == 1
        assert result.rooms[0].nominal_area_mm2 == 12000000

    def test_a_custom_base_url_reaches_the_client(self, monkeypatch) -> None:
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
        monkeypatch.setenv("ANTHROPIC_BASE_URL", "http://localhost:9999")
        response = _AnthropicMessage([_AnthropicBlock("tool_use", VALID_PAYLOAD)])
        captured = _patch_anthropic(monkeypatch, response=response)

        rp.AnthropicRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert captured["init_kwargs"]["base_url"] == "http://localhost:9999"

    def test_a_non_tool_response_is_a_safe_empty_result(self, monkeypatch) -> None:
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
        response = _AnthropicMessage([_AnthropicBlock("text", None)])
        _patch_anthropic(monkeypatch, response=response)

        result = rp.AnthropicRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert result.configured is True
        assert result.openings == []
        assert result.rooms == []
        assert result.note

    def test_a_provider_failure_never_raises(self, monkeypatch) -> None:
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
        _patch_anthropic(monkeypatch, error=TimeoutError("upstream timed out"))

        result = rp.AnthropicRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert result.configured is True
        assert "failed" in result.note

    def test_one_malformed_item_does_not_sink_the_others(self, monkeypatch) -> None:
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
        payload = {
            "openings": [
                {"label": "ok"},  # missing required keys
                VALID_PAYLOAD["openings"][0],
            ],
            "rooms": VALID_PAYLOAD["rooms"],
        }
        response = _AnthropicMessage([_AnthropicBlock("tool_use", payload)])
        _patch_anthropic(monkeypatch, response=response)

        result = rp.AnthropicRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert len(result.openings) == 1
        assert result.openings[0].label == "Window 1"

    def test_the_default_model_is_a_real_looking_claude_model(self) -> None:
        assert rp.AnthropicRecognitionProvider().model.startswith("claude-")

    def test_an_explicit_model_overrides_the_default(self) -> None:
        provider = rp.AnthropicRecognitionProvider(model="claude-opus-5")
        assert provider.model == "claude-opus-5"


# --- OpenAI ------------------------------------------------------------------


class _OpenAIMessage:
    def __init__(self, content: str | None) -> None:
        self.content = content


class _OpenAIChoice:
    def __init__(self, message: _OpenAIMessage) -> None:
        self.message = message


class _OpenAIResponse:
    def __init__(self, choices: list) -> None:
        self.choices = choices


class _FakeOpenAICompletions:
    def __init__(self, response=None, error: Exception | None = None) -> None:
        self._response = response
        self._error = error

    def create(self, **kwargs):
        self.last_kwargs = kwargs
        if self._error is not None:
            raise self._error
        return self._response


class _FakeOpenAIChat:
    def __init__(self, response=None, error: Exception | None = None) -> None:
        self.completions = _FakeOpenAICompletions(response, error)


class _FakeOpenAIClient:
    def __init__(self, response=None, error: Exception | None = None, **init_kwargs):
        self.init_kwargs = init_kwargs
        self.chat = _FakeOpenAIChat(response, error)


def _patch_openai(monkeypatch, *, response=None, error: Exception | None = None):
    captured: dict = {}

    def factory(**kwargs):
        captured["init_kwargs"] = kwargs
        client = _FakeOpenAIClient(response, error)
        captured["client"] = client
        return client

    monkeypatch.setattr(rp, "OpenAI", factory)
    return captured


class TestOpenAIRecognitionProvider:
    def test_missing_api_key_is_unconfigured(self, monkeypatch) -> None:
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        result = rp.OpenAIRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is False
        assert "OPENAI_API_KEY" in result.note

    def test_a_valid_json_response_is_parsed(self, monkeypatch) -> None:
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        response = _OpenAIResponse(
            [_OpenAIChoice(_OpenAIMessage(json.dumps(VALID_PAYLOAD)))]
        )
        _patch_openai(monkeypatch, response=response)

        result = rp.OpenAIRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert result.configured is True
        assert result.provider == "openai"
        assert len(result.openings) == 1
        assert len(result.rooms) == 1

    def test_uses_response_format_not_tool_choice(self, monkeypatch) -> None:
        # Ollama's OpenAI-compatible endpoint documents tool_choice as
        # unsupported and was confirmed, against a real local model, to
        # silently ignore a forced tool call and answer in plain prose
        # instead -- response_format is what it actually honours.
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        response = _OpenAIResponse(
            [_OpenAIChoice(_OpenAIMessage(json.dumps(VALID_PAYLOAD)))]
        )
        captured = _patch_openai(monkeypatch, response=response)

        rp.OpenAIRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        kwargs = captured["client"].chat.completions.last_kwargs
        assert "tool_choice" not in kwargs
        assert "tools" not in kwargs
        assert kwargs["response_format"]["type"] == "json_schema"

    def test_a_custom_base_url_reaches_the_client(self, monkeypatch) -> None:
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        monkeypatch.setenv("OPENAI_BASE_URL", "http://localhost:8123/v1")
        response = _OpenAIResponse([_OpenAIChoice(_OpenAIMessage(None))])
        captured = _patch_openai(monkeypatch, response=response)

        rp.OpenAIRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert captured["init_kwargs"]["base_url"] == "http://localhost:8123/v1"

    def test_empty_content_is_a_safe_empty_result(self, monkeypatch) -> None:
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        response = _OpenAIResponse([_OpenAIChoice(_OpenAIMessage(None))])
        _patch_openai(monkeypatch, response=response)

        result = rp.OpenAIRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is True
        assert result.openings == []

    def test_invalid_json_content_is_a_safe_failure(self, monkeypatch) -> None:
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        response = _OpenAIResponse([_OpenAIChoice(_OpenAIMessage("{not valid json"))])
        _patch_openai(monkeypatch, response=response)

        result = rp.OpenAIRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is True
        assert result.openings == []
        assert "JSON" in result.note

    def test_a_provider_failure_never_raises(self, monkeypatch) -> None:
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        _patch_openai(monkeypatch, error=ConnectionError("refused"))

        result = rp.OpenAIRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is True
        assert "failed" in result.note


# --- Gemini --------------------------------------------------------------


class _GeminiResponse:
    def __init__(self, text: str | None) -> None:
        self.text = text


class _FakeGeminiModels:
    def __init__(self, response=None, error: Exception | None = None) -> None:
        self._response = response
        self._error = error

    def generate_content(self, **kwargs):
        self.last_kwargs = kwargs
        if self._error is not None:
            raise self._error
        return self._response


class _FakeGeminiClient:
    def __init__(self, response=None, error: Exception | None = None, **init_kwargs):
        self.init_kwargs = init_kwargs
        self.models = _FakeGeminiModels(response, error)


def _patch_gemini(monkeypatch, *, response=None, error: Exception | None = None):
    captured: dict = {}

    def factory(**kwargs):
        captured["init_kwargs"] = kwargs
        return _FakeGeminiClient(response, error)

    monkeypatch.setattr(rp.genai, "Client", factory)
    return captured


class TestGeminiRecognitionProvider:
    def test_missing_api_key_is_unconfigured(self, monkeypatch) -> None:
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        result = rp.GeminiRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is False
        assert "GEMINI_API_KEY" in result.note

    def test_a_valid_json_response_is_parsed(self, monkeypatch) -> None:
        monkeypatch.setenv("GEMINI_API_KEY", "key-test")
        _patch_gemini(monkeypatch, response=_GeminiResponse(json.dumps(VALID_PAYLOAD)))

        result = rp.GeminiRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert result.configured is True
        assert result.provider == "gemini"
        assert len(result.openings) == 1
        assert len(result.rooms) == 1

    def test_a_custom_base_url_reaches_the_http_options(self, monkeypatch) -> None:
        monkeypatch.setenv("GEMINI_API_KEY", "key-test")
        monkeypatch.setenv("GEMINI_BASE_URL", "http://localhost:11434")
        captured = _patch_gemini(monkeypatch, response=_GeminiResponse("{}"))

        rp.GeminiRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        http_options = captured["init_kwargs"]["http_options"]
        assert http_options.base_url == "http://localhost:11434"

    def test_no_base_url_set_means_no_base_url_override(self, monkeypatch) -> None:
        monkeypatch.setenv("GEMINI_API_KEY", "key-test")
        monkeypatch.delenv("GEMINI_BASE_URL", raising=False)
        captured = _patch_gemini(monkeypatch, response=_GeminiResponse("{}"))

        rp.GeminiRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert captured["init_kwargs"]["http_options"].base_url is None

    def test_empty_text_is_a_safe_empty_result(self, monkeypatch) -> None:
        monkeypatch.setenv("GEMINI_API_KEY", "key-test")
        _patch_gemini(monkeypatch, response=_GeminiResponse(None))

        result = rp.GeminiRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is True
        assert result.openings == []

    def test_invalid_json_is_a_safe_failure(self, monkeypatch) -> None:
        monkeypatch.setenv("GEMINI_API_KEY", "key-test")
        _patch_gemini(monkeypatch, response=_GeminiResponse("{not valid"))

        result = rp.GeminiRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is True
        assert "JSON" in result.note

    def test_a_provider_failure_never_raises(self, monkeypatch) -> None:
        monkeypatch.setenv("GEMINI_API_KEY", "key-test")
        _patch_gemini(monkeypatch, error=RuntimeError("503"))

        result = rp.GeminiRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )
        assert result.configured is True
        assert "failed" in result.note


# --- Timeout configuration ----------------------------------------------


class TestTimeoutSeconds:
    def test_defaults_to_120(self, monkeypatch) -> None:
        monkeypatch.delenv("RECOGNITION_TIMEOUT_SECONDS", raising=False)
        assert rp._timeout_seconds() == 120

    def test_a_configured_value_is_used(self, monkeypatch) -> None:
        monkeypatch.setenv("RECOGNITION_TIMEOUT_SECONDS", "600")
        assert rp._timeout_seconds() == 600

    def test_garbage_falls_back_to_the_default(self, monkeypatch) -> None:
        monkeypatch.setenv("RECOGNITION_TIMEOUT_SECONDS", "not-a-number")
        assert rp._timeout_seconds() == 120

    def test_zero_or_negative_falls_back_to_the_default(self, monkeypatch) -> None:
        monkeypatch.setenv("RECOGNITION_TIMEOUT_SECONDS", "0")
        assert rp._timeout_seconds() == 120
        monkeypatch.setenv("RECOGNITION_TIMEOUT_SECONDS", "-5")
        assert rp._timeout_seconds() == 120


class TestTimeoutReachesEachClient:
    # A slow, locally hosted model is the exact case this exists for (see
    # this module's own docstring) -- each vendor's client actually has to
    # receive the configured value, not just have a function that computes it.

    def test_anthropic(self, monkeypatch) -> None:
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
        monkeypatch.setenv("RECOGNITION_TIMEOUT_SECONDS", "900")
        response = _AnthropicMessage([_AnthropicBlock("tool_use", VALID_PAYLOAD)])
        captured = _patch_anthropic(monkeypatch, response=response)

        rp.AnthropicRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert captured["init_kwargs"]["timeout"] == 900

    def test_openai(self, monkeypatch) -> None:
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        monkeypatch.setenv("RECOGNITION_TIMEOUT_SECONDS", "900")
        response = _OpenAIResponse(
            [_OpenAIChoice(_OpenAIMessage(json.dumps(VALID_PAYLOAD)))]
        )
        captured = _patch_openai(monkeypatch, response=response)

        rp.OpenAIRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        assert captured["init_kwargs"]["timeout"] == 900

    def test_gemini(self, monkeypatch) -> None:
        monkeypatch.setenv("GEMINI_API_KEY", "key-test")
        monkeypatch.setenv("RECOGNITION_TIMEOUT_SECONDS", "900")
        captured = _patch_gemini(monkeypatch, response=_GeminiResponse("{}"))

        rp.GeminiRecognitionProvider().extract(
            image_data=b"x", content_type="image/jpeg"
        )

        # Gemini's HttpOptions.timeout is documented in milliseconds.
        assert captured["init_kwargs"]["http_options"].timeout == 900_000


# --- The suggested track/drop fields, shared parsing logic -------------------


class TestSuggestedTrackAndDropParsing:
    """`_openings_from` is one function all three providers share -- these
    drive it directly rather than through a specific vendor's fake client,
    since the parsing rule (fields absent or explicitly null both mean
    "no suggestion") is the same regardless of which one produced the JSON.
    """

    def test_present_values_are_parsed(self) -> None:
        result = rp._openings_from(
            [
                {
                    "label": "W1",
                    "room": "R1",
                    "nominal_w_tmm": 1000,
                    "nominal_h_tmm": 2000,
                    "confidence": 0.9,
                    "suggested_track_w_tmm": 1400,
                    "suggested_drop_h_tmm": 2700,
                }
            ]
        )
        assert result[0].suggested_track_w_tmm == 1400
        assert result[0].suggested_drop_h_tmm == 2700

    def test_explicit_null_means_no_suggestion(self) -> None:
        result = rp._openings_from(
            [
                {
                    "label": "W1",
                    "room": "R1",
                    "nominal_w_tmm": 1000,
                    "nominal_h_tmm": 2000,
                    "confidence": 0.9,
                    "suggested_track_w_tmm": None,
                    "suggested_drop_h_tmm": None,
                }
            ]
        )
        assert result[0].suggested_track_w_tmm is None
        assert result[0].suggested_drop_h_tmm is None

    def test_missing_keys_also_mean_no_suggestion(self) -> None:
        # Backward compatible with a provider (or an older cached job) that
        # never included these keys at all.
        result = rp._openings_from(
            [
                {
                    "label": "W1",
                    "room": "R1",
                    "nominal_w_tmm": 1000,
                    "nominal_h_tmm": 2000,
                    "confidence": 0.9,
                }
            ]
        )
        assert result[0].suggested_track_w_tmm is None
        assert result[0].suggested_drop_h_tmm is None


# --- Shared shape ------------------------------------------------------------


@pytest.mark.parametrize(
    "provider_cls",
    [
        rp.AnthropicRecognitionProvider,
        rp.OpenAIRecognitionProvider,
        rp.GeminiRecognitionProvider,
    ],
)
class TestEveryRealProvider:
    def test_has_a_stable_registry_name(self, provider_cls) -> None:
        assert provider_cls().name in {"anthropic", "openai", "gemini"}

    def test_accepts_an_explicit_model(self, provider_cls) -> None:
        assert provider_cls(model="a-specific-model").model == "a-specific-model"
