# The airing-check session

The runbook for the scheduled Claude session that runs the notifier (Rafael,
22/11/2026). It replaces the GitHub Actions cron, which GitHub throttled to
about four runs a day on this repo (median gap 6 hours, longest 10).

It runs in an Anthropic cloud session (a routine), in the repo root of the
clone. `MAL_CLIENT_ID`, `MAL_USERNAME` and `DISCORD_WEBHOOK` come from the
environment. The state lives on the `airing-data` branch of origin
(`STATE_BRANCH`), because a cloud run keeps no disk: `notify.py` reads that
branch at the start and pushes it again, only when something changed.

## Never

- Never print or post a secret, the webhook URL or an environment value. Do not
  run `env` or `printenv`.
- Never edit code, config or this runbook, never open a PR, and never push
  anything yourself: `notify.py` pushes the state branch.
- Never post to Discord by any other path, and never run `notify.py` a second
  time in the same session.

## Steps

1. Install the one dependency (the cloud image does not ship it):

       python -m pip install -q requests

2. Run the notifier:

       STATE_BRANCH=airing-data python notify.py

3. End with one line.
   - Exit code 0: `ok: ` followed by the last line `notify.py` printed.
   - Anything else: send one PushNotification, `Anime pings failed: ` followed by
     the line `notify.py` printed that names the failure, then stop. Do not
     diagnose, retry or fix. The next scheduled run tries again, and the state
     only moves forward after a successful post, so nothing is lost.

The first run after a fresh install creates the `airing-data` branch and posts
nothing: every show is adopted silently, as designed.
