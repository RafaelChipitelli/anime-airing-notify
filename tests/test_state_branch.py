"""
State kept on a git branch of origin (STATE_BRANCH), for runs with no disk or
cache that survives them: a Claude cloud routine.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import notify  # noqa: E402

BRANCH = "airing-data"


def run(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


@pytest.fixture
def origin(tmp_path, monkeypatch):
    """A bare origin plus a clone to run in; the branch does not exist yet."""
    bare = tmp_path / "origin.git"
    run("init", "-q", "--bare", str(bare), cwd=tmp_path)
    work = tmp_path / "work"
    run("clone", "-q", str(bare), str(work), cwd=tmp_path)
    monkeypatch.chdir(work)
    return bare


def commits(bare):
    return int(run("rev-list", "--count", BRANCH, cwd=bare))


def test_missing_branch_is_a_first_run(origin):
    assert notify.load_state_branch(BRANCH) == ("", None)


def test_save_then_load_round_trips_and_chains_commits(origin):
    notify.save_state_branch(BRANCH, '{"1": 3}\n', None)
    text, parent = notify.load_state_branch(BRANCH)
    assert json.loads(text) == {"1": 3}
    assert parent == run("rev-parse", BRANCH, cwd=origin)

    notify.save_state_branch(BRANCH, '{"1": 4}\n', parent)
    assert json.loads(notify.load_state_branch(BRANCH)[0]) == {"1": 4}
    assert commits(origin) == 2


def test_a_concurrent_writer_makes_the_push_fail(origin):
    notify.save_state_branch(BRANCH, '{"1": 3}\n', None)
    _, parent = notify.load_state_branch(BRANCH)
    notify.save_state_branch(BRANCH, '{"1": 4}\n', parent)
    with pytest.raises(RuntimeError):
        notify.save_state_branch(BRANCH, '{"1": 5}\n', parent)  # stale parent


def test_an_unreachable_origin_raises_instead_of_reading_as_empty(origin, tmp_path):
    origin.rename(tmp_path / "gone.git")
    with pytest.raises(RuntimeError):
        notify.load_state_branch(BRANCH)


class Posted:
    def __init__(self):
        self.calls = []

    def __call__(self, webhook, items):
        self.calls.append(items)


def run_main(monkeypatch, aired, posted, branch=True):
    monkeypatch.setenv("MAL_CLIENT_ID", "x")
    monkeypatch.setenv("MAL_USERNAME", "u")
    monkeypatch.setenv("DISCORD_WEBHOOK", "https://example.invalid/hook")
    if branch:
        monkeypatch.setenv("STATE_BRANCH", BRANCH)
    else:
        monkeypatch.delenv("STATE_BRANCH", raising=False)
    monkeypatch.setattr(notify, "monitored",
                        lambda cid, user: {1: {"title": "Show", "progress": 0, "plan": False}})
    monkeypatch.setattr(notify, "latest_aired", lambda ids: {
        1: {"aired": aired, "finished": False, "country": "JP", "english": "Show",
            "romaji": "Show", "cover": ""}})
    monkeypatch.setattr(notify, "post_discord", posted)
    return notify.main()


def test_main_adopts_silently_then_pings_only_new_episodes(origin, monkeypatch):
    posted = Posted()

    assert run_main(monkeypatch, 3, posted) == 0          # first run: adopt, no ping
    assert posted.calls == [] and commits(origin) == 1

    assert run_main(monkeypatch, 3, posted) == 0          # nothing new: no ping, no commit
    assert posted.calls == [] and commits(origin) == 1

    assert run_main(monkeypatch, 4, posted) == 0          # episode 4 aired
    assert [i["ep"] for i in posted.calls[0]] == [4]
    assert commits(origin) == 2
    assert json.loads(run("show", f"{BRANCH}:state.json", cwd=origin)) == {"1": 4}


def test_main_stops_when_the_state_cannot_be_read(origin, tmp_path, monkeypatch):
    origin.rename(tmp_path / "gone.git")
    posted = Posted()
    assert run_main(monkeypatch, 3, posted) == 1
    assert posted.calls == []


def test_file_state_still_works_without_a_branch(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("STATE_FILE", str(tmp_path / "state.json"))
    posted = Posted()

    assert run_main(monkeypatch, 3, posted, branch=False) == 0
    assert json.loads((tmp_path / "state.json").read_text()) == {"1": 3}

    assert run_main(monkeypatch, 4, posted, branch=False) == 0
    assert [i["ep"] for i in posted.calls[0]] == [4]
    assert json.loads((tmp_path / "state.json").read_text()) == {"1": 4}
