"""A per-source-IP request throttle.

Independent of ``app.services.auth``'s own per-phone one: that throttle
answers "is this one phone number being brute-forced" and is silent about
everything else, including a spray of many different phone numbers from one
source, which never touches any single number's counter twice. This answers
"is this IP hammering the API at all" -- login gets its own tighter rule, and
everything else (short of ``/api/health``, exempt below) shares a looser one
as a general abuse backstop.

In-memory, keyed by IP. Correct only because this API runs as exactly one
worker process -- ``backend/Dockerfile``'s own comment says why (Alembic
cannot race itself on boot with more than one) -- so there is exactly one
copy of this dict, ever, for as long as this design holds. A second worker
or a second replica would each keep their own blind counter, silently
multiplying every limit below by however many there were; that would need a
shared store (the database, the way the phone throttle already uses one)
before either happened.

PURE: a plain dict and clock reads passed in, no FastAPI or Starlette import,
so the sliding-window arithmetic is testable without an app or a request.
"""

from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass


@dataclass(frozen=True)
class RateLimitRule:
    """At most `limit` requests per `window_seconds`, per key."""

    limit: int
    window_seconds: float


class RateLimiter:
    """One sliding window per (rule name, key).

    ``check`` never raises: it returns the seconds to wait, or ``None`` if
    the request is allowed, so the caller decides what "not allowed" means
    (a 429, here) rather than this needing to know about HTTP at all.
    """

    def __init__(self) -> None:
        self._hits: dict[tuple[str, str], deque[float]] = defaultdict(deque)

    def check(
        self, rule_name: str, key: str, rule: RateLimitRule, *, now: float
    ) -> float | None:
        window_start = now - rule.window_seconds
        hits = self._hits[(rule_name, key)]
        while hits and hits[0] <= window_start:
            hits.popleft()

        if len(hits) >= rule.limit:
            return max(hits[0] + rule.window_seconds - now, 0.0)

        hits.append(now)
        return None

    def reset(self) -> None:
        """Test-only. The limiter is a module-level singleton so its state
        outlives any one request; without this, one test's burst leaks into
        the next test that shares the same `app` object."""
        self._hits.clear()
