"""The sliding-window IP throttle. Pure: every case below drives the clock
by hand, so none of it depends on how fast the test happens to run.
"""

from __future__ import annotations

from app.core.rate_limit import RateLimiter, RateLimitRule

RULE = RateLimitRule(limit=3, window_seconds=60)


class TestRateLimiter:
    def test_requests_under_the_limit_are_allowed(self) -> None:
        limiter = RateLimiter()
        for i in range(3):
            assert limiter.check("r", "1.2.3.4", RULE, now=float(i)) is None

    def test_the_request_that_crosses_the_limit_is_blocked(self) -> None:
        limiter = RateLimiter()
        for i in range(3):
            limiter.check("r", "1.2.3.4", RULE, now=float(i))
        assert limiter.check("r", "1.2.3.4", RULE, now=3.0) is not None

    def test_the_wait_returned_is_when_the_oldest_hit_falls_out_of_the_window(
        self,
    ) -> None:
        limiter = RateLimiter()
        for i in range(3):
            limiter.check("r", "1.2.3.4", RULE, now=float(i))  # hits at 0, 1, 2
        wait = limiter.check("r", "1.2.3.4", RULE, now=3.0)
        # The oldest hit (at t=0) falls out of a 60s window at t=60.
        assert wait == 57.0

    def test_the_window_slides_rather_than_resetting_wholesale(self) -> None:
        limiter = RateLimiter()
        for i in range(3):
            limiter.check("r", "1.2.3.4", RULE, now=float(i))  # hits at 0, 1, 2
        assert limiter.check("r", "1.2.3.4", RULE, now=3.0) is not None
        # The t=0 hit has now aged out; one slot is free, not all three.
        assert limiter.check("r", "1.2.3.4", RULE, now=60.1) is None
        assert limiter.check("r", "1.2.3.4", RULE, now=60.2) is not None

    def test_different_keys_never_share_a_bucket(self) -> None:
        limiter = RateLimiter()
        for i in range(3):
            limiter.check("r", "1.2.3.4", RULE, now=float(i))
        # A different source IP has spent none of that budget.
        assert limiter.check("r", "5.6.7.8", RULE, now=3.0) is None

    def test_different_rule_names_never_share_a_bucket(self) -> None:
        limiter = RateLimiter()
        for i in range(3):
            limiter.check("login", "1.2.3.4", RULE, now=float(i))
        # The global rule's own bucket for the same IP is untouched.
        assert limiter.check("global", "1.2.3.4", RULE, now=3.0) is None

    def test_reset_clears_every_bucket(self) -> None:
        limiter = RateLimiter()
        for i in range(3):
            limiter.check("r", "1.2.3.4", RULE, now=float(i))
        limiter.reset()
        assert limiter.check("r", "1.2.3.4", RULE, now=3.0) is None
