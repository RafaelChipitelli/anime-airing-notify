# Export Crunchyroll watch history to MyAnimeList, and automate what comes after

Notes from building my anime tracking setup. The goal was that watching is
the only manual step: progress logging, MAL updates, weekly reports and
new-episode alerts all happen on their own. I'm writing it down because most
of the problems below are invisible until they have already written wrong
data to your list, and MAL has no undo.

Three parts:

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
notifier re-reads the MAL list every cycle, so finishing a show removes it
from episode monitoring without any configuration. Shows watched outside
Crunchyroll get added to MAL by hand and the notifier picks them up the same
way.

## Part 1: exporting Crunchyroll history to MAL

### Getting the history

Crunchyroll has no public API. The private one the apps use
(`beta-api.crunchyroll.com/content/v2/{account_id}/watch-history`) paginates
the full history server-side, which means episodes watched on phone or TV are
included. No browser extension involved. Auth is an exchange of the `etp_rt`
browser cookie for an access token (`grant_type=etp_rt_cookie` against
`/auth/v1/token`, with the public client id).
[CrunchyExporter](https://github.com/ruflas/crunchyexporter-cli) implements
this fetch and was my starting point.

Renewal surprise: the token response includes a `refresh_token`, but the
public web client rejects `grant_type=refresh_token` with
`400 unsupported_grant_type`. The returned value is itself an `etp_rt`. To
renew unattended, redo the cookie login with the stored value. In my testing
it does not rotate, so one pasted cookie has lasted indefinitely.

Standing warning: all of this is a private API with no compatibility
promise. Crunchyroll can change the token exchange, the client id, or the
history endpoint at any time, and the export breaks until adapted. Design
for that: make every failure abort before writing (my sync exits without
touching MAL and the weekly Discord message says why), and keep backups of
the MAL list so no breakage can cost you data. Mine snapshots the full list
(status, progress, scores) before every writing run and keeps 8 weeks.

### The data model will burn you

Everything below was measured on my own history (~7,600 episodes, 146
series). Three assumptions that look safe and are wrong:

1. `season_number` is not a season. Golden Kamuy (4 seasons) shows up with
   season numbers 1, 11 and 15. They are internal indexes, sometimes one per
   audio language.
2. Episode numbering switches scheme per series, sometimes inside one series.
   Jujutsu Kaisen is continuous across seasons (`1-24, 25-47, 48-59`);
   Dr. STONE restarts (`1-24, 1-11, 1-37`); TenSura mixes both. The only
   formula that worked everywhere: franchise total = sum of
   `(range_end - range_start + 1)` over each block's episode range.
3. The history has real gaps (episodes watched but never logged; one of my
   shows logged 1..13 with 10 missing). Per-entry progress must come from the
   highest episode reached, never from counting distinct episodes; a count
   marks a fully-watched show as incomplete.

Also: the same episode appears many times (one row per viewing session per
audio language), and trailers or specials sometimes count as episodes,
inflating a franchise total by 1 to 3. That inflation matters twice below.

### Matching a Crunchyroll series to MAL entries

MAL splits most franchises into one entry per season, so each series maps to
a chain of entries, and the watched total gets distributed down the chain,
capping at each entry's `num_episodes`. What I learned doing that:

- Use the official MAL API for search, not Jikan. Jikan's search endpoint
  was persistently dead for me (`504, "Jikan failed to connect to
  MyAnimeList"`) while its cached endpoints answered 200, which is worse than
  fully down because it looks alive. The official API reads public data with
  just a client id (`X-MAL-CLIENT-ID` header, no OAuth); the README of this
  repo has the step-by-step for creating one.
- Always pass `nsfw=true`. Search and list endpoints silently omit entries
  flagged sensitive, and that does not just hide entries: it makes fuzzy
  matching pick a similarly-named wrong anime because the right one is
  absent. That single flag caused four wrong matches in my list ("Lycoris
  Recoil" matched Dennou Coil, from 2007).
- Search sometimes cannot return a main entry at all, even with `nsfw=true`
  (searching "Naruto" does not return Naruto, id 20). Workaround: find any
  related entry and walk `related_anime` to the Prequel or Parent story.
- Gate fuzzy matches behind a human. Anything below ~0.9 title similarity
  goes to a pending list and never gets written until approved. A wrong
  match writes one anime's progress onto another.

### Writing to MAL without corrupting the list

The sync runs unattended, so any failure becomes silent corruption. Each of
these guards exists because of a real incident or a near miss:

- A failed list read must abort, not look empty. MAL returns errors as JSON
  bodies, so a naive `.json().get("data", [])` turns a 401 or 429 into "empty
  list", which turns a never-regress guard into a mass downgrade of every
  entry. `raise_for_status()` per page, require the `data` key, abort the
  run without writing.
- Re-check each entry right before writing. The paginated list
  (`/users/@me/animelist`) lags: entries written seconds earlier were missing
  from it while `/anime/{id}?fields=my_list_status` was fresh. One GET per
  write, skip if the fresh value is already at or past yours.
- Never regress progress, and never downgrade `completed`. Status is not
  covered by a progress comparison; check it separately.
- Cap progress at the last aired episode (AniList,
  `nextAiringEpisode.episode - 1`, bulk-queryable with `idMal_in`). This
  kills the trailer-inflation class: nobody watched an episode that does not
  exist yet.
- Dedupe writes by MAL id, cap total writes per run, hold a run lock, and
  write a machine-readable summary plus distinct exit codes, so whatever
  wraps the script can tell "all good" from "needs a human".

One more staleness trap: `num_episodes` is 0 until MAL knows the count. A
0-count entry must not absorb unlimited episodes from the chain
distribution, and those counts need a refresh at run start.

### Scheduling

Windows Task Scheduler: weekly trigger, `StartWhenAvailable` (missed slot
runs as soon as the PC turns on), `AllowStartIfOnBatteries`, action pointing
at the venv's `pythonw.exe` so no console window flashes. cron + anacron on
Linux gives the same semantics. Persist the CR `etp_rt` and the MAL OAuth
refresh token (the token endpoint returns one; my first version threw it
away and the pipeline would have died quietly in a month), and make every
interactive prompt fail fast when stdin is not a TTY.

## Part 2: weekly summary on Discord

A Discord webhook is a plain HTTPS POST. No bot account, no library, and
Discord's mobile push comes with it. The sync's exit handler posts an embed
built from the run summary, including aborted runs, which is exactly when a
notification matters: the message carries the command to re-auth.

Noise control: the trailer/special leftovers from the data-model section are
permanent, so they live in a baseline file and only get reported when they
change. A growing leftover is the actual signal that a new season started
and the mapping needs extending.

## A small CLI to drive it

All the moving pieces collapse into a `mal` shell function wrapping one short
Python script that lives next to the sync code. The design rule that keeps it
safe to type without thinking: **a bare command reads or dry-runs; adding
`go` makes it real**. Every write path has a free preview.

```
mal watching [filter]   list by status (completed, on_hold, dropped, ptw, all;
                        one-letter aliases; optional name filter)
mal search <name>       search the MAL catalog with ids, episodes, year
mal sync [go]           weekly sync: dry-run, or write for real
mal fetch               pull the Crunchyroll history only (stored token,
                        no cookie prompt, writes nothing)
mal backup              snapshot the whole list to a dated JSON
mal preview [--only X]  match new Crunchyroll series against MAL entries
mal plan [go]           build the write plan from the reviewed preview,
                        then write it
mal map                 rebuild the series-to-entries mapping
mal add [go]            entries watched outside Crunchyroll
mal scores [sheet|go]   validate the score sheet / rebuild it / write scores
mal summary [go]        print the weekly Discord summary, or post it
mal auth                redo the MAL OAuth
```

Two naming details that earned their place: `plan` is not a status alias
(plan-to-watch is `ptw`, the term people actually use), and the score-sheet
rebuild is the explicit `scores sheet` rather than the default, because
rebuilding overwrites filled-but-unapplied scores and the safest action
should be the laziest one to type.

## Part 3: the new-episode notifier

The code in this repository. GitHub Actions every 15 minutes:

1. Read the MAL list (client-id auth): entries that are watching and
   currently airing.
2. One AniList query for the last aired episode of each.
3. Diff against state in the Actions cache; post one embed per new episode.
4. First run or lost state initializes silently, so a cache eviction cannot
   spam one alert per show.

On public-repo hygiene: Actions logs of public repos are public, and a raw
`requests` exception message contains the full request URL, webhook token
included. The script logs exception types and status codes, nothing else.
Setup steps are in the [README](../README.md).
