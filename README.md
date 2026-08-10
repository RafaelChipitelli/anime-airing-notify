# anime-airing-notify

Posts to a Discord channel when a new episode airs for anything on my
MyAnimeList that is marked watching and is currently airing. Runs on GitHub
Actions every 15 minutes, so it works with my PC off.

## The whole pipeline

This repo is the always-on piece of a larger personal setup where watching
anime is the only manual step:

1. **Crunchyroll history → MyAnimeList.** A weekly job on my PC pulls my full
   Crunchyroll watch history through the same private API the apps use. The
   history is server-side, so episodes watched on phone or TV count too. It
   then updates my MAL list: advances progress, flips finished seasons to
   completed, and refuses anything unsafe (it never regresses progress, never
   downgrades a completed entry, never writes a fuzzy title match without me
   approving it, and caps progress at the last episode that actually aired).
2. **Weekly summary on Discord.** After each sync, a webhook post tells me
   what advanced, what new series showed up, and whether a credential
   expired, with the exact command to fix it.
3. **New-episode pings (this repo).** Anything on my list that is watching
   and currently airing gets a Discord notification within ~15 minutes of a
   new episode airing, including shows I track manually outside Crunchyroll.

The sync scripts run on my machine and are not published here, but the whole
design is written up in [docs/pipeline-guide.md](docs/pipeline-guide.md),
including every API problem I hit (Crunchyroll's misleading season numbers,
MAL's silent nsfw filtering, Jikan's dead search, cache-lagged list reads).
If you got here trying to export your own Crunchyroll history to MAL, start
there.

## How it works

1. Reads the MAL list (public list, client-id auth, no account credentials)
   and keeps entries that are watching and currently airing.
2. One AniList GraphQL query (`idMal_in`) returns the last aired episode for
   all of them.
3. Compares against state kept in the Actions cache and posts one embed per
   new episode: English title, romaji below, cover art.
4. A missing or lost state file initializes silently, so a cache eviction can
   never spam one alert per show.

## Setup

Fork the repo (or copy `notify.py` and the workflow), then collect three
values.

**MAL client id** (free, takes 2 minutes):

```
myanimelist.net/apiconfig → Create ID
  App Type              → other
  App Description       → anything (minimum 50 characters, no special chars)
  App Redirect URL      → http://localhost
  Homepage URL          → http://localhost
  Commercial / Non-Comm → non-commercial
  Purpose of Use        → hobbyist
  → agree → Submit → copy the Client ID shown at the top of the form
```

Don't pick App Type `web`: it issues a client secret and expects it in the
OAuth flow. Not needed here, this script only reads public data.

**Discord webhook**:

```
your server → channel → gear icon (Edit Channel)
  → Integrations → Webhooks → New Webhook → Copy Webhook URL
```

**MAL username**: yours. The anime list has to be public (that is the MAL
default; check Profile → Privacy if unsure).

Then put the three values in the repo secrets:

```
repo → Settings → Secrets and variables → Actions → New repository secret
  MAL_CLIENT_ID    → the client id
  MAL_USERNAME     → the username
  DISCORD_WEBHOOK  → the webhook URL
```

Before waiting on the scheduler, you can test the whole thing locally in ten
seconds (needs Python 3.10+ and `pip install requests`):

```
MAL_CLIENT_ID=...  MAL_USERNAME=...  DISCORD_WEBHOOK=...  python notify.py
```

A first run prints `state initialized silently for N anime` and posts
nothing; that means your three values work. Delete `state.json` if you want
to re-test from scratch.

Then enable the workflow in the Actions tab. The first cloud run initializes
state the same way; notifications start from the second run onward.

## Notes

- Secrets never appear in the code or in logs. Since Actions logs of public
  repos are public, `notify.py` reports errors as exception type + HTTP
  status only (a raw `requests` error message would contain the webhook URL).
- Airing times come from AniList and reflect the Japanese broadcast.
  Simulcast platforms usually publish within minutes of that, sometimes not.
- The Crunchyroll side of the pipeline uses a private, undocumented API. If
  Crunchyroll changes how the token exchange or the history endpoint works,
  the sync breaks until someone adapts it. It breaks safe: the run aborts
  before writing anything to MAL and the Discord summary says so. The
  notifier in this repo does not touch Crunchyroll at all, so it keeps
  working regardless.

## Doing more with the list API

Everything here builds on one convenient property of the MAL API: you can
pull a list already filtered by status, with one authenticated GET:

```
GET https://api.myanimelist.net/v2/users/@me/animelist
    ?status=watching          # watching | completed | on_hold | dropped | plan_to_watch
    &nsfw=true                # without this, flagged entries silently vanish
    &limit=1000
    &fields=list_status,num_episodes
```

`list_status` carries progress, score and status per entry; omit the `status`
parameter to get everything. For someone else's public list, swap `@me` for
the username and a client id header (`X-MAL-CLIENT-ID`) is enough, no OAuth.

That one call is the whole foundation for small personal commands. Mine is a
`mal` shell function wrapping a short Python script, so things like
`mal watching`, `mal dropped`, `mal completed slime` (filter by name) or
`mal search frieren` print instantly instead of me opening the site. The
notifier in this repo is the same call with `status=watching` plus an AniList
lookup on top.

## Questions, bugs, ideas

Open an [issue](../../issues) for anything: a bug in the notifier, a question
about the pipeline guide, or a suggestion. Questions about the sync part
(the code that lives on my machine) are welcome too; the guide documents the
design and I'm happy to go deeper on any of it.

Want to change something? Fork it and open a PR. It's two files, `notify.py`
and the workflow, and there's no build step: edit, point the secrets at your
own list and webhook, and the Actions run itself is the test.
