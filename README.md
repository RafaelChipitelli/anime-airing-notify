# anime-airing-notify

Export your Crunchyroll watch history to MyAnimeList, keep it synced weekly,
and get a Discord notification when a new episode airs for anything you are
watching. This repository contains the airing notifier (directly reusable,
runs free on GitHub Actions) and the documentation for the whole pipeline.

**Looking for how to export Crunchyroll history to MAL?** Start with
[docs/pipeline-guide.md](docs/pipeline-guide.md): it covers the Crunchyroll
export end to end — how the private watch-history API works, why its season
numbers and episode numbering will corrupt a naive import, and how to write to
MAL without ever regressing your list — plus every API trap we hit building
it (MAL's silent `nsfw` filtering, Jikan's dead search, cache-lagged list
reads).

The notifier below posts a Discord message when a new episode airs for any
anime that is both on a MyAnimeList list as **watching** and
**currently airing**.

Runs on GitHub Actions every 15 minutes. Data sources: the MAL API (public
list, client-id auth) for *what to watch for*, and the AniList GraphQL API
for *when episodes air*. State (last episode notified per anime) is kept in
the Actions cache; a lost cache reinitializes silently instead of re-notifying.

## Setup

1. Fork/clone, then set three repository secrets (Settings → Secrets → Actions):
   - `MAL_CLIENT_ID` — a MyAnimeList API client id
   - `MAL_USERNAME` — the MAL user whose public list is monitored
   - `DISCORD_WEBHOOK` — the Discord webhook URL to post to
2. Enable the workflow. The first run initializes silently; notifications
   start from the second run onward.

No account credentials are used anywhere: the MAL list is read via public
client-id auth, and the only write anywhere is the Discord webhook post.
