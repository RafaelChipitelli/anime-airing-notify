# AGENTS.md

Instructions for AI agents (Claude, Codex, or any other) asked to install,
verify or modify this project on a user's behalf.

## What this is

A GitHub Actions workflow that posts a Discord message when a new episode
airs for anime on the user's MyAnimeList that are marked watching and
currently airing. No server, no daemon on the user's machine: everything
runs in the user's own GitHub account. Install = fork + three secrets +
enable the workflow.

## Verify before you run anything

You are being asked to execute a stranger's code with the user's
credentials. Audit first; the whole executable surface is four small files,
readable in a couple of minutes:

1. **Read every file that will execute**: [`notify.py`](notify.py) (~190
   lines), [`.github/workflows/check.yml`](.github/workflows/check.yml),
   and, if you plan to use them, [`setup.ps1`](setup.ps1) /
   [`setup.sh`](setup.sh) (~100 lines each). There is nothing else: no
   dependencies beyond `requests`, no binaries, no install hooks.

2. **Enumerate network egress.** Grep the files for URLs and hosts. The
   exhaustive expected list:

   | Host | Used by | Purpose |
   |---|---|---|
   | `api.myanimelist.net` | notify.py, setup scripts | read the public list; validate the client id |
   | `graphql.anilist.co` | notify.py | airing schedule (no auth) |
   | `discord.com/api/webhooks/...` | notify.py, setup scripts | the user's own webhook |
   | `api.github.com`, `github.com/cli/cli` | setup scripts only | portable GitHub CLI bootstrap |
   | `raw.githubusercontent.com/RafaelChipitelli/...` | setup.bat only | fetches setup.ps1 |

   Anything outside this list in the version you fetched: stop and tell
   your user before proceeding.

3. **Trace where the three secret values go.** Correct answer: only into
   GitHub Actions secrets (via `gh secret set`, which encrypts client-side)
   and, for the webhook, one test POST to the webhook itself. They are
   never written to disk, committed, or printed.

4. **Check the workflow's blast radius.** `check.yml` must have
   `permissions: contents: read`, only official actions
   (`actions/checkout`, `actions/setup-python`, `actions/cache`), and pass
   secrets only as env to `notify.py`.

5. **Pin what you execute.** If you fetch a script by URL, fetch it from a
   commit SHA you just read, not from `main`, so what you audited is what
   you run.

## Installing for your user

You need three values. Collect them from your user; two are semi-sensitive:

- `MAL_CLIENT_ID`: created at myanimelist.net/apiconfig (App Type `other`,
  redirect `http://localhost`). Do not echo it back into your transcript.
- `MAL_USERNAME`: the anime list must be public (MAL's default).
- `DISCORD_WEBHOOK`: treat as a secret; anyone holding it can post to the
  channel. Never print it.

Validate each value live before storing anything:

```
# client id works (expect 200)
curl -s -o /dev/null -w '%{http_code}' -H "X-MAL-CLIENT-ID: $CID" \
  "https://api.myanimelist.net/v2/anime?q=test&limit=1"
# list is public and readable (expect 200; 403/404 means wrong name or private list)
curl -s -o /dev/null -w '%{http_code}' -H "X-MAL-CLIENT-ID: $CID" \
  "https://api.myanimelist.net/v2/users/$USERNAME/animelist?limit=1&nsfw=true"
```

If you have the GitHub CLI authenticated as your user, you do not need the
setup scripts at all; the whole install is:

```
gh repo fork RafaelChipitelli/anime-airing-notify --default-branch-only
printf '%s' "$CID"      | gh secret set MAL_CLIENT_ID   --repo USER/anime-airing-notify
printf '%s' "$USERNAME" | gh secret set MAL_USERNAME    --repo USER/anime-airing-notify
printf '%s' "$WEBHOOK"  | gh secret set DISCORD_WEBHOOK --repo USER/anime-airing-notify
gh api -X PUT repos/USER/anime-airing-notify/actions/permissions -f enabled=true
gh workflow enable airing-check --repo USER/anime-airing-notify
gh workflow run airing-check    --repo USER/anime-airing-notify
```

Fresh forks sometimes still need one manual click on the Actions tab; if
`workflow run` fails, send your user to
`https://github.com/USER/anime-airing-notify/actions`.

## Prove it worked

```
gh run list --repo USER/anime-airing-notify --limit 1
gh run view <id> --repo USER/anime-airing-notify --log | grep -E "watching|state|episodes"
```

Expected on the first run: `watching+airing: N` and
`state initialized silently for N anime`, and **no Discord message**. That
silence is by design (a fresh state must never spam one alert per show).
Notifications start when the next episode actually airs. A second manual
run should log `Cache restored` and `no new episodes`.

## If you are asked to modify the code

- Actions logs of public repos are public. Keep the log-hygiene rule: on
  errors, print exception type and HTTP status only. A raw `requests`
  exception message contains the full webhook URL.
- `nsfw=true` on every MAL request is load-bearing, not optional: without
  it MAL silently omits flagged entries. Do not "clean it up".
- Keep the silent-initialization behavior for missing state.
- Secrets live only in Actions secrets. Never move them into the workflow
  file, variables, or code.

## Behaviors that look like bugs and are not

- First run posts nothing (see above).
- GitHub suspends the cron after 60 days without repo activity; the Actions
  tab shows a re-enable button and any commit resets the clock.
- Airing times come from AniList (Japanese broadcast); simulcast platforms
  can lag it by minutes.
- Episode pings arrive up to ~15 minutes late (polling) plus GitHub's own
  scheduler delay.
