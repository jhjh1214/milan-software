"""Fixtures shared across every test file.

The `app` object FastAPI tests import is a genuine module-level singleton,
reused by every test file's own `client` fixture (there are four, each
defined locally rather than through this file) -- so anything that keeps
state on `app` outlives any one test unless something clears it in between.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest

from app.main import reset_rate_limits


@pytest.fixture(autouse=True)
def _reset_rate_limits() -> Iterator[None]:
    """The IP rate limiter (`app.core.rate_limit`) is exactly this kind of
    state: without this, one test's burst of requests -- or the whole
    suite's worth of `sign_in()` calls sharing one login bucket -- would
    start returning 429 to tests that have nothing to do with rate limiting."""
    reset_rate_limits()
    yield
    reset_rate_limits()
