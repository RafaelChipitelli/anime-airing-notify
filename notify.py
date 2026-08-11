#!/usr/bin/env python3
"""
New-episode notifier: MAL watching list x AniList airing schedule -> Discord.

Runs on a schedule (GitHub Actions). For every anime that is BOTH on the
user's MAL list as "watching" AND currently airing, posts a Discord message
when a new episode has aired since the last check.

All personal values come from the environment; nothing identifying lives in
this repository:
  MAL_CLIENT_ID    MyAnimeList API client id
  MAL_USERNAME     MAL username whose public list is read
  DISCORD_WEBHOOK  Discord webhook URL to post to
  STATE_FILE       optional, defaults to state.json

State maps anime id -> last episode notified. A missing/empty state file
initializes silently (no notifications), so a lost cache can never spam.

Log hygiene: this runs in a PUBLIC repo, so logs are public. Never print
URLs or env values; exceptions are reported as type + status code only.
"""
import os
import sys
import json
from pathlib import Path

import requests

MAL_API = "https://api.myanimelist.net/v2"
ANILIST = "https://graphql.anilist.co"

ANILIST_QUERY = """
query($ids: [Int]) {
  Page(perPage: 50) {
    media(idMal_in: $ids, type: ANIME) {
      idMal
      status
      episodes
      title { english romaji }
      coverImage { extraLarge large }
      nextAiringEpisode { episode }
    }
  }
}"""


def env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        print(f"missing env: {name}")
        sys.exit(1)
    return v


def sanitize(e: Exception) -> str:
    """Error description safe for public logs: no URLs, no bodies."""
    status = getattr(getattr(e, "response", None), "status_code", None)
    return f"{type(e).__name__}" + (f" HTTP {status}" if status else "")


def monitored(client_id: str, username: str) -> dict[int, dict]:
    """
    mal_id -> {title, progress, plan} for entries worth watching for new
    episodes: list status watching OR plan_to_watch, airing status
    currently_airing OR not_yet_aired. not_yet_aired is deliberate twice
    over: it is what makes premiere pings possible for planned shows, and
    MAL is slow to flip simulcasts to currently_airing, which would
    otherwise silently drop shows from monitoring.
    """
    out: dict[int, dict] = {}
    for list_status in ("watching", "plan_to_watch"):
        url = (f"{MAL_API}/users/{username}/animelist"
               f"?status={list_status}&limit=100&nsfw=true&fields=list_status,status")
        while url:
            r = requests.get(url, headers={"X-MAL-CLIENT-ID": client_id}, timeout=30)
            r.raise_for_status()
            j = r.json()
            for it in j.get("data", []):
                node = it["node"]
                if node.get("status") not in ("currently_airing", "not_yet_aired"):
                    continue
                ls = it.get("list_status") or {}
                out[node["id"]] = {"title": node["title"],
                                   "progress": ls.get("num_episodes_watched", 0),
                                   "plan": list_status == "plan_to_watch"}
            url = (j.get("paging") or {}).get("next")
    return out


def latest_aired(mal_ids: list[int]) -> dict[int, dict]:
    """mal_id -> {aired, title, finished} from AniList. Absent ids are skipped."""
    r = requests.post(ANILIST, json={"query": ANILIST_QUERY,
                                     "variables": {"ids": mal_ids}}, timeout=30)
    r.raise_for_status()
    out: dict[int, dict] = {}
    for m in r.json()["data"]["Page"]["media"]:
        nxt = m.get("nextAiringEpisode")
        if nxt and nxt.get("episode"):
            aired = nxt["episode"] - 1
            finished = False
        elif m.get("status") == "FINISHED" and m.get("episodes"):
            aired = m["episodes"]
            finished = True
        else:
            continue
        titulo = m.get("title") or {}
        out[m["idMal"]] = {"aired": aired, "finished": finished,
                           "english": titulo.get("english") or "",
                           "romaji": titulo.get("romaji") or "",
                           "cover": (m.get("coverImage") or {}).get("extraLarge")
                                    or (m.get("coverImage") or {}).get("large") or ""}
    return out


def post_discord(webhook: str, items: list[dict]) -> None:
    """One embed per episode: English title first, romaji lighter below, cover
    art full-width under the text. Discord caps a post at 10 embeds, so chunk."""
    for i in range(0, len(items), 10):
        embeds = []
        for it in items[i:i + 10]:
            titulo = it["english"] or it["romaji"]
            linhas = []
            if it["english"] and it["romaji"] and it["romaji"] != it["english"]:
                linhas.append(f"-# {it['romaji']}")
            ep = f"Episode **{it['ep']}** is out"
            if it["ep"] == 1:
                ep += "  (premiere!)"
            if it["finished"]:
                ep += "  (season finale!)"
            if it.get("plan"):
                ep += ", on your plan-to-watch list"
            elif it["atras"]:
                ep += f", you're on {it['atras']}"
            linhas.append(ep)
            embed = {"title": titulo, "description": "\n".join(linhas), "color": 0x5a6e8a}
            if it["cover"]:
                # "image" renders full-width below the text ("thumbnail" is the small side one)
                embed["image"] = {"url": it["cover"]}
            embeds.append(embed)
        r = requests.post(webhook, json={"embeds": embeds}, timeout=20)
        r.raise_for_status()


def main() -> int:
    client_id = env("MAL_CLIENT_ID")
    username = env("MAL_USERNAME")
    webhook = env("DISCORD_WEBHOOK")
    state_file = Path(os.environ.get("STATE_FILE", "state.json"))

    state: dict[str, int] = {}
    if state_file.exists():
        try:
            state = json.loads(state_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print("state file corrupt; reinitializing silently")

    try:
        watching = monitored(client_id, username)
    except Exception as e:
        print(f"MAL list read failed: {sanitize(e)}")
        return 1
    print(f"monitored (watching or planned, airing or upcoming): {len(watching)}")
    if not watching:
        return 0

    try:
        aired = latest_aired(list(watching))
    except Exception as e:
        print(f"AniList query failed: {sanitize(e)}")
        return 1

    novos: list[dict] = []
    adotados = 0
    sem_dados = 0
    for mal_id, info in watching.items():
        a = aired.get(mal_id)
        if not a:
            sem_dados += 1
            continue
        key = str(mal_id)
        if key not in state:
            # a show tracked for the first time is adopted silently: its
            # latest episode did not "just air", and this is also what makes
            # a lost cache or a code deploy unable to spam one ping per show
            state[key] = a["aired"]
            adotados += 1
            continue
        if a["aired"] <= state[key]:
            state[key] = max(a["aired"], state[key])
            continue
        novos.append({"ep": a["aired"], "finished": a["finished"],
                      "english": a["english"], "romaji": a["romaji"] or info["title"],
                      "cover": a["cover"], "plan": info["plan"],
                      "atras": 0 if info["plan"] else
                               (info["progress"] if info["progress"] < a["aired"] - 1 else 0)})
        state[key] = a["aired"]
    if sem_dados:
        print(f"no airing data yet for {sem_dados} upcoming/unscheduled show(s)")
    if adotados:
        print(f"silently adopted {adotados} newly tracked anime")

    # drop entries no longer monitored so state does not grow forever
    state = {k: v for k, v in state.items() if int(k) in watching}

    if novos:
        try:
            post_discord(webhook, novos)
            print(f"notified {len(novos)} new episode(s)")
        except Exception as e:
            print(f"Discord post failed: {sanitize(e)}")
            return 1
    else:
        print("no new episodes")

    state_file.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
