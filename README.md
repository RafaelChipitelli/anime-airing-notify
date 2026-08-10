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

Enable the workflow in the Actions tab. The first run only initializes state;
notifications start from the second run onward.

## Notes

- Secrets never appear in the code or in logs. Since Actions logs of public
  repos are public, `notify.py` reports errors as exception type + HTTP
  status only (a raw `requests` error message would contain the webhook URL).
- Airing times come from AniList and reflect the Japanese broadcast.
  Simulcast platforms usually publish within minutes of that, sometimes not.

## Questions, bugs, ideas

Open an [issue](../../issues) for anything: a bug in the notifier, a question
about the pipeline guide, or a suggestion. Questions about the sync part
(the code that lives on my machine) are welcome too; the guide documents the
design and I'm happy to go deeper on any of it.

Want to change something? Fork it and open a PR. It's two files, `notify.py`
and the workflow, and there's no build step: edit, point the secrets at your
own list and webhook, and the Actions run itself is the test.
