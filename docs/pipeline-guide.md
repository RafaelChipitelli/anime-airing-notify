# Export Crunchyroll watch history to MyAnimeList (and automate everything after)

How to export your Crunchyroll history to MAL, keep the two in sync weekly,
and get Discord alerts when new episodes air. This guide documents a
three-part personal automation where *watching anime is the only manual
step*. Everything else — logging progress, updating a MyAnimeList profile,
weekly reports, new-episode alerts — happens on its own.

If you searched for "export Crunchyroll history", "Crunchyroll to
MyAnimeList", or "why is my Crunchyroll export wrong": part 1 is for you,
especially the data-model section — most naive exports silently write wrong
progress for every multi-season series.

The airing notifier in this repository is part 3 and is directly reusable.
Parts 1 and 2 run on a home machine; this guide documents their design and,
more importantly, every trap we hit while building them, because most of those
traps are invisible until they have already corrupted your list.

```
┌─────────────┐   watch history    ┌──────────────┐
│ Crunchyroll │ ─────────────────► │  weekly sync │──► MyAnimeList (progress,
└─────────────┘  (server-side, so  │  (local PC,  │      status, never regress)
                  phone/TV counts)  │  scheduled)  │──► Discord (weekly summary)
                                    └──────────────┘
┌─────────────┐    airing times    ┌──────────────┐
│   AniList   │ ─────────────────► │   notifier   │──► Discord (new-episode
└─────────────┘                    │(GitHub Actions│      alert, ~15 min)
        ▲   MAL list: watching ∩   │  every 15min) │
        └── currently airing ──────┴──────────────┘
```

The parts feed each other: the weekly sync keeps MAL statuses fresh, and the
notifier re-reads the MAL list every cycle, so finishing a show automatically
removes it from episode monitoring. Anime watched outside Crunchyroll can be
added to MAL by hand and the notifier picks them up the same way.

---

## Part 1 — Weekly sync: Crunchyroll history → MyAnimeList

### Getting the history

Crunchyroll has no public API. Its private API
(`beta-api.crunchyroll.com/content/v2/{account_id}/watch-history`) is what the
apps use, and it paginates the full history server-side — which means episodes
watched on phone or TV are included, no browser extension needed. Auth works by
exchanging the `etp_rt` browser cookie for an access token
(`grant_type=etp_rt_cookie` against `/auth/v1/token`, public client id).
[CrunchyExporter](https://github.com/ruflas/crunchyexporter-cli) implements
this fetch and is a good starting point.

**Token renewal trap:** the token response includes a `refresh_token`, but the
public web client does **not** support `grant_type=refresh_token` — it answers
`400 unsupported_grant_type`. The returned value is itself an `etp_rt`: to
renew unattended, redo the *cookie login* with the stored value. In our testing
it does not rotate, so one pasted cookie lasts indefinitely.

### The Crunchyroll data model will lie to you

Measured on a real ~7,600-episode history. Three assumptions that look safe
and are wrong:

1. **`season_number` is not a season.** Golden Kamuy (4 seasons) appears with
   season numbers 1, 11 and 15. They are internal indexes, sometimes one per
   audio language.
2. **Episode numbering switches scheme per series, even inside one series.**
   Jujutsu Kaisen is continuous across seasons (`1-24, 25-47, 48-59`);
   Dr. STONE restarts (`1-24, 1-11, 1-37`); TenSura is a hybrid of both. The
   only formula that works everywhere: *franchise total = sum of
   (range_end - range_start + 1) over each block's episode range*.
3. **The history has real gaps** (an episode watched but never logged). So
   per-entry progress must come from the **highest episode reached**, never
   from counting distinct episodes — a count marks a fully-watched show as
   incomplete.

Also: the same episode appears many times (one row per viewing session per
audio language), and trailers/specials are sometimes counted as episodes,
inflating franchise totals by 1–3. That inflation matters later.

### Matching a Crunchyroll series to MAL entries

MAL usually splits one franchise into one entry per season, so a series must
be matched to a *chain* of entries and the watched total distributed down the
chain, capping at each entry's `num_episodes`.

- **Use the official MAL API, not Jikan, for search.** Jikan's search endpoint
  was persistently dead for us (`504 — Jikan failed to connect to
  MyAnimeList`) while cached endpoints worked, which is worse than being fully
  down: it looks alive. The official API reads public data with just a client
  id (`X-MAL-CLIENT-ID` header, no OAuth) — create one at
  myanimelist.net/apiconfig.
- **Always pass `nsfw=true`.** Both search and list endpoints silently omit
  entries flagged sensitive. That doesn't just hide entries — it makes fuzzy
  search *mis-match*: with the right entry hidden, "Lycoris Recoil" matched
  Dennou Coil (2007). This one flag caused four wrong matches for us.
- **Search sometimes cannot find a main entry at all** (searching "Naruto"
  does not return Naruto, id 20). Workaround: find any related entry and walk
  `related_anime` to the Prequel / Parent story.
- **Gate every fuzzy match behind human review.** Similarity-scored matches
  below ~0.9 should never be auto-written. Write them to a pending list and
  require explicit approval; a wrong match writes one anime's progress onto
  another and MAL has no undo.

### Writing to MAL without ever corrupting the list

The sync runs unattended, so every failure mode becomes silent corruption.
Guarantees worth building (each of these prevented or would have prevented a
real incident):

- **A failed list read must abort, not look empty.** MAL returns errors as
  JSON bodies; naive `.json().get("data", [])` turns a 401/429 into "empty
  list", which turns your never-regress guard into a mass-downgrade of every
  entry. `raise_for_status()` per page, require the `data` key, abort the run.
- **Re-check each entry right before writing.** The paginated list
  (`/users/@me/animelist`) has cache lag — entries written seconds ago are
  missing from it while `/anime/{id}?fields=my_list_status` is fresh. Read the
  fresh endpoint per write; skip if it already has ≥ your value.
- **Never regress progress, never downgrade `completed`.** Status is not
  protected by a progress comparison; check it separately.
- **Cap progress at the last *aired* episode** (AniList
  `nextAiringEpisode.episode - 1`, queryable in bulk by `idMal_in`). This
  kills the trailer-inflation class: nobody watched an episode that doesn't
  exist yet.
- **Dedupe writes by MAL id, cap total writes per run, take a run lock, and
  emit a machine-readable summary + distinct exit codes** so a wrapper (or a
  human reading Discord) knows exactly what happened and what to do.

One more freshness rule: an entry's `num_episodes` is 0 until MAL knows the
count. Never let a 0-count entry absorb unlimited episodes from the chain
distribution, and refresh those counts at run start.

### Scheduling

Windows Task Scheduler with `StartWhenAvailable` (runs as soon as the PC turns
on if the slot was missed) + `AllowStartIfOnBatteries`, action pointing at the
venv's `pythonw.exe` — silent, weekly, no terminal. On Linux, cron + anacron
gives the same semantics. Persist both the CR `etp_rt` and the MAL OAuth
refresh token (the token endpoint returns one — don't discard it) so the
routine renews itself; make every prompt fail fast when there is no TTY.

## Part 2 — Weekly summary on Discord

A Discord **webhook** is a plain HTTPS POST: no bot, no OAuth, phone push
notifications for free. The sync's exit handler posts an embed built from the
run summary — including aborted runs, which is precisely when a notification
matters (the message carries the exact command to re-auth).

Noise control: known permanent quirks (those trailer/special leftovers) are
stored as a baseline and only reported when they *change* — a growing leftover
is the signal that a new season started and the mapping needs extending.

## Part 3 — New-episode notifier (this repository)

Runs on GitHub Actions every 15 minutes, so it works with the PC off:

1. Read the MAL list (public, client-id auth): entries that are **watching**
   AND **currently airing**.
2. One AniList GraphQL query (`idMal_in`) returns the last aired episode for
   all of them.
3. Compare against state kept in the Actions cache; post one Discord embed per
   new episode (English title, romaji subtitle, large cover art).
4. Lost/first state initializes **silently** — a cache eviction can never spam
   one alert per monitored show.

Public-repo hygiene: all personal values (client id, username, webhook) live
in GitHub Secrets; logs print exception *types and status codes only*, because
a raw `requests` exception message contains the full webhook URL and Actions
logs of public repos are public.

Setup for your own copy is in the [README](../README.md).

---

## What this buys you, day to day

- Watch anywhere (app, TV, terminal player) and never log anything: the list
  updates itself weekly, with human review reserved for new-series matching.
- A weekly Discord digest of what synced, plus an actionable alert if a
  credential expired.
- A push notification within ~15 minutes of any followed episode airing,
  24/7, including shows tracked manually outside Crunchyroll.
