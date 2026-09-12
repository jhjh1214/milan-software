"""The AI recognition provider seam. SPEC.md Phase 8, "Future: assisted
digitisation".

What matters here is the swap, not any actual recognition -- no real
provider is chosen yet. `get_recognition_provider` must read its config from
the environment, fall back safely on anything it does not recognise, and
never let a typo in an env var take a route down.
"""

from __future__ import annotations

from app.services.recognition import (
    NullRecognitionProvider,
    get_recognition_provider,
)


class TestProviderSelection:
    def test_defaults_to_the_null_provider(self, monkeypatch) -> None:
        monkeypatch.delenv("RECOGNITION_PROVIDER", raising=False)
        provider = get_recognition_provider()
        assert isinstance(provider, NullRecognitionProvider)
        assert provider.name == "none"

    def test_an_unrecognised_name_falls_back_rather_than_raising(
        self, monkeypatch
    ) -> None:
        monkeypatch.setenv("RECOGNITION_PROVIDER", "some-future-vendor")
        provider = get_recognition_provider()
        assert isinstance(provider, NullRecognitionProvider)

    def test_the_model_env_var_is_passed_through(self, monkeypatch) -> None:
        monkeypatch.setenv("RECOGNITION_PROVIDER", "none")
        monkeypatch.setenv("RECOGNITION_MODEL", "some-model-name")
        provider = get_recognition_provider()
        assert provider.model == "some-model-name"

    def test_case_and_whitespace_do_not_matter(self, monkeypatch) -> None:
        monkeypatch.setenv("RECOGNITION_PROVIDER", "  NONE  ")
        provider = get_recognition_provider()
        assert isinstance(provider, NullRecognitionProvider)


class TestNullRecognitionProvider:
    def test_proposes_nothing_and_says_it_is_unconfigured(self) -> None:
        provider = NullRecognitionProvider()
        result = provider.extract(image_data=b"data", content_type="image/jpeg")
        assert result.configured is False
        assert result.provider == "none"
        assert result.openings == []
        assert result.rooms == []
        assert result.note

    def test_is_deterministic_and_makes_no_network_call(self) -> None:
        provider = NullRecognitionProvider()
        first = provider.extract(image_data=b"a", content_type="image/jpeg")
        second = provider.extract(image_data=b"a", content_type="image/jpeg")
        assert first == second
