"""
AniList rate limits per IP. A cloud routine shares its egress IP with other
sessions, so a 429 can land on the notifier's single query (27/11/2026, which
skipped a run and sent a failure push). One retry after Retry-After absorbs it.
"""
import json
import sys
from pathlib import Path

import pytest
import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import notify  # noqa: E402

MEDIA = {"idMal": 1, "status": "RELEASING", "episodes": 12, "countryOfOrigin": "JP",
         "title": {"english": "Show", "romaji": "Show"}, "coverImage": {},
         "nextAiringEpisode": {"episode": 5}}


def response(status: int, body: dict | None = None, headers: dict | None = None) -> requests.Response:
    r = requests.Response()
    r.status_code = status
    r.headers.update(headers or {})
    r._content = json.dumps(body or {}).encode()
    return r


@pytest.fixture
def anilist(monkeypatch):
    """Queue responses for requests.post and record every sleep."""
    queue: list[requests.Response] = []
    sleeps: list[float] = []
    monkeypatch.setattr(notify.requests, "post", lambda *a, **k: queue.pop(0))
    monkeypatch.setattr(notify.time, "sleep", sleeps.append)
    return queue, sleeps


OK = {"data": {"Page": {"media": [MEDIA]}}}


def test_429_then_ok_waits_retry_after_and_succeeds(anilist):
    queue, sleeps = anilist
    queue += [response(429, headers={"Retry-After": "42"}), response(200, OK)]
    assert notify.latest_aired([1])[1]["aired"] == 4
    assert sleeps == [42]
    assert queue == []


def test_two_429s_fail_like_before(anilist):
    queue, sleeps = anilist
    queue += [response(429, headers={"Retry-After": "5"}), response(429)]
    with pytest.raises(requests.HTTPError) as e:
        notify.latest_aired([1])
    assert e.value.response.status_code == 429
    assert sleeps == [5]


def test_ok_first_time_never_sleeps(anilist):
    queue, sleeps = anilist
    queue += [response(200, OK)]
    assert notify.latest_aired([1])[1]["aired"] == 4
    assert sleeps == []


@pytest.mark.parametrize("header, wait", [(None, 60), ("junk", 60), ("600", 65), ("0", 1)])
def test_retry_after_is_defaulted_and_capped(anilist, header, wait):
    queue, sleeps = anilist
    queue += [response(429, headers={"Retry-After": header} if header else {}), response(200, OK)]
    notify.latest_aired([1])
    assert sleeps == [wait]


def test_other_errors_are_not_retried(anilist):
    queue, sleeps = anilist
    queue += [response(500), response(200, OK)]
    with pytest.raises(requests.HTTPError):
        notify.latest_aired([1])
    assert sleeps == []
    assert len(queue) == 1
