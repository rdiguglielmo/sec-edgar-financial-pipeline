"""The one place the SEC access policy is implemented.

Both stages that talk to the SEC go through here: extract.py for the quarterly
archives and incremental.py for the submissions API. Before this module each
kept its own copy of the rate limiter, which meant the published limit was
enforced twice and could drift in one file without the other noticing.

Rate limiting
-------------
The SEC asks clients to stay under 10 requests per second and to identify
themselves by name and email. Both rules are at
https://www.sec.gov/os/webmaster-faq. The limiter is process wide, so the count
is correct however many call sites there are, and the sleep a retry spends also
counts against it: a retry storm cannot push the process over the limit.

Which failures are worth retrying, and which are not
----------------------------------------------------
The distinction matters more than the backoff itself.

Retried: 429 and the 5xx family. These say the server is busy or briefly broken,
and the same request will very likely succeed shortly. A single one of them
aborting a run is the failure this module exists to prevent, because the run
that fails is a 400 MB download or a ten company loop most of the way through.

Not retried, ever:

- 403 means the User-Agent is missing or not accepted. Every retry would fail
  the same way, so retrying converts an error with a one line fix into a slow
  error with a one line fix, while sending the SEC traffic it already refused.
- 404 on the submissions endpoint means the cik was not left padded to ten
  digits, which is a defect in the caller rather than a condition that clears.

Anything else non retryable is raised as it arrives.
"""

from __future__ import annotations

import logging
import time

import requests

from config import (
    REQUEST_TIMEOUT_SECONDS,
    SEC_MIN_REQUEST_INTERVAL_SECONDS,
    sec_headers,
)

LOGGER = logging.getLogger("sec_client")

# 429 is the documented signal for exceeding the rate limit. The 5xx entries are
# the ones a CDN in front of a public endpoint returns while it is busy, all of
# which describe a condition that clears on its own.
RETRYABLE_STATUS_CODES = frozenset({429, 500, 502, 503, 504})

MAX_ATTEMPTS = 5

# 1, 2, 4, 8 seconds between the five attempts. Capped so that a server sending
# an implausible Retry-After cannot park the run for an hour.
INITIAL_BACKOFF_SECONDS = 1.0
MAX_BACKOFF_SECONDS = 30.0

_last_request_at = 0.0


def _throttle() -> None:
    """Hold off until the SEC rate limit allows another request."""
    global _last_request_at
    wait_seconds = SEC_MIN_REQUEST_INTERVAL_SECONDS - (time.monotonic() - _last_request_at)
    if wait_seconds > 0:
        time.sleep(wait_seconds)
    _last_request_at = time.monotonic()


def _retry_delay(response: requests.Response, attempt: int) -> float:
    """Return how long to wait before the next attempt.

    Retry-After is honoured when the server sends a usable one, because the
    server knows better than the client does. It arrives as seconds or as an
    HTTP date; only the seconds form is read, since that is what the SEC sends,
    and an unparseable value falls back to the backoff rather than failing.
    """
    header = response.headers.get("Retry-After", "")
    try:
        return min(float(header), MAX_BACKOFF_SECONDS)
    except ValueError:
        return min(INITIAL_BACKOFF_SECONDS * (2 ** (attempt - 1)), MAX_BACKOFF_SECONDS)


def sec_get(url: str, *, stream: bool = False) -> requests.Response:
    """GET a SEC URL, respecting the rate limit and retrying transient failures.

    Returns a response that has already passed raise_for_status, so callers can
    read it directly. Pass stream=True for the quarterly archives, which are read
    in chunks rather than held in memory; the caller owns closing it.

    Raises requests.HTTPError on a non retryable status, and on a retryable one
    that survived every attempt.
    """
    for attempt in range(1, MAX_ATTEMPTS + 1):
        _throttle()
        try:
            response = requests.get(
                url,
                headers=sec_headers(),
                stream=stream,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
        except (requests.ConnectionError, requests.Timeout) as error:
            # A dropped connection or a timeout is the same kind of condition as
            # a 503: nothing about the request is wrong, so it is worth another
            # attempt on the same schedule.
            if attempt == MAX_ATTEMPTS:
                raise
            delay = min(INITIAL_BACKOFF_SECONDS * (2 ** (attempt - 1)), MAX_BACKOFF_SECONDS)
            LOGGER.warning(
                "%s on attempt %d/%d for %s, retrying in %.1fs",
                type(error).__name__,
                attempt,
                MAX_ATTEMPTS,
                url,
                delay,
            )
            time.sleep(delay)
            continue

        if response.status_code not in RETRYABLE_STATUS_CODES:
            # Includes 403 and 404, which are raised immediately and on purpose.
            response.raise_for_status()
            return response

        if attempt == MAX_ATTEMPTS:
            LOGGER.error(
                "HTTP %d for %s after %d attempts, giving up",
                response.status_code,
                url,
                MAX_ATTEMPTS,
            )
            response.raise_for_status()

        delay = _retry_delay(response, attempt)
        LOGGER.warning(
            "HTTP %d on attempt %d/%d for %s, retrying in %.1fs",
            response.status_code,
            attempt,
            MAX_ATTEMPTS,
            url,
            delay,
        )
        response.close()
        time.sleep(delay)

    # Unreachable: the loop either returns or raises on its last attempt.
    raise RuntimeError(f"sec_get exhausted its attempts without resolving {url}")
