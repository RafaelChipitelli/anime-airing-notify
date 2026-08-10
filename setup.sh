#!/bin/sh
# anime-airing-notify one-command setup (macOS / Linux)
#   curl -fsSL https://raw.githubusercontent.com/RafaelChipitelli/anime-airing-notify/main/setup.sh | sh
# Forks the repo into your account, asks for the three values, validates each
# one live, stores them as repo secrets and fires the first workflow run.
# No prerequisites: if the GitHub CLI is missing, a portable copy is
# downloaded to a temp folder (it handles the OAuth login and the libsodium
# encryption that repo secrets require).

set -e
SRC="RafaelChipitelli/anime-airing-notify"
TTY=/dev/tty

fail() { printf '\n%s\n' "$1" >&2; exit 1; }

GH=$(command -v gh 2>/dev/null || true)
if [ -z "$GH" ]; then
    echo "GitHub CLI not found; downloading a portable copy (~14 MB, temp folder only)..."
    case "$(uname -s)" in
        Darwin) os="macOS"; ext="zip" ;;
        Linux)  os="linux"; ext="tar.gz" ;;
        *) fail "Unsupported OS $(uname -s). Install the GitHub CLI manually and re-run." ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) arch="arm64" ;;
        x86_64)        arch="amd64" ;;
        *) fail "Unsupported arch $(uname -m). Install the GitHub CLI manually and re-run." ;;
    esac
    tag=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [ -n "$tag" ] || fail "Could not resolve the latest GitHub CLI release. Install it manually and re-run."
    ver=${tag#v}
    dir="${TMPDIR:-/tmp}/gh-portable-$tag"
    mkdir -p "$dir"
    url="https://github.com/cli/cli/releases/download/$tag/gh_${ver}_${os}_${arch}.$ext"
    if [ "$ext" = "zip" ]; then
        curl -fsSL "$url" -o "$dir/gh.zip" || fail "Download failed ($url). Install the GitHub CLI manually and re-run."
        unzip -oq "$dir/gh.zip" -d "$dir"
    else
        curl -fsSL "$url" | tar -xzf - -C "$dir" || fail "Download failed ($url). Install the GitHub CLI manually and re-run."
    fi
    GH=$(find "$dir" -type f -name gh | head -n 1)
    [ -n "$GH" ] || fail "gh binary not found after extraction. Install the GitHub CLI manually and re-run."
fi

if ! "$GH" auth status >/dev/null 2>&1; then
    echo "Logging into GitHub: your browser will open, approve it there (one-time code, no password in this terminal)."
    "$GH" auth login --web --hostname github.com --git-protocol https < "$TTY"
    "$GH" auth status >/dev/null 2>&1 || fail "GitHub login did not complete. Re-run this script to try again."
fi

user=$("$GH" api user -q .login)
repo="$user/anime-airing-notify"

if [ "$user" = "${SRC%%/*}" ]; then
    echo "You own the source repo; configuring $SRC directly."
    repo="$SRC"
elif "$GH" repo view "$repo" >/dev/null 2>&1; then
    echo "Fork already exists: $repo"
else
    echo "Forking $SRC into $repo..."
    "$GH" repo fork "$SRC" --default-branch-only >/dev/null 2>&1 || fail "Fork failed. Fork it manually on github.com and re-run."
fi

# prompts must read the terminal, not the piped script
TTY=/dev/tty
printf '\nThree values needed (each gets validated before anything is stored).\n'

printf '\n1/3  MAL client id\n     myanimelist.net/apiconfig -> Create ID -> App Type: other -> Redirect URL: http://localhost\n'
printf '     paste the Client ID: '; read -r cid < "$TTY"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-MAL-CLIENT-ID: $cid" \
    "https://api.myanimelist.net/v2/anime?q=test&limit=1")
[ "$code" = "200" ] || fail "MAL rejected that client id (HTTP $code). Copy it again from myanimelist.net/apiconfig."
echo "     ok: MAL accepted the client id"

printf '\n2/3  MAL username (the anime list must be public, which is the MAL default)\n'
printf '     username: '; read -r maluser < "$TTY"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-MAL-CLIENT-ID: $cid" \
    "https://api.myanimelist.net/v2/users/$maluser/animelist?limit=1&nsfw=true")
[ "$code" = "200" ] || fail "Could not read the list of '$maluser' (HTTP $code). Check the spelling and that the list is public (MAL -> Profile -> Privacy)."
echo "     ok: list of '$maluser' is readable"

printf '\n3/3  Discord webhook\n     your server -> channel -> gear (Edit Channel) -> Integrations -> Webhooks -> New Webhook -> Copy URL\n'
printf '     paste the Webhook URL: '; read -r hook < "$TTY"
case "$hook" in https://discord.com/api/webhooks/*) ;; *) fail "That does not look like a Discord webhook URL." ;; esac
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"content": "anime-airing-notify: setup test, this channel will receive the episode pings"}' "$hook")
case "$code" in 2*) echo "     ok: test message posted, check the channel" ;; *) fail "Discord rejected the webhook (HTTP $code). Copy the URL again." ;; esac

printf '\nStoring the three values as secrets of %s...\n' "$repo"
printf '%s' "$cid"     | "$GH" secret set MAL_CLIENT_ID   --repo "$repo"
printf '%s' "$maluser" | "$GH" secret set MAL_USERNAME    --repo "$repo"
printf '%s' "$hook"    | "$GH" secret set DISCORD_WEBHOOK --repo "$repo"

echo "Enabling the workflow..."
"$GH" api -X PUT "repos/$repo/actions/permissions" -f enabled=true >/dev/null 2>&1 || true
"$GH" workflow enable airing-check --repo "$repo" >/dev/null 2>&1 || true
if "$GH" workflow run airing-check --repo "$repo" >/dev/null 2>&1; then
    printf '\nDone. First run initializes silently; pings start from the next new episode.\nWatch it at https://github.com/%s/actions\n' "$repo"
else
    printf '\nCould not start the workflow from here (fresh forks sometimes need one click).\nOpen https://github.com/%s/actions, press the enable button, then Run workflow.\n' "$repo"
fi
