#!/bin/sh
# anime-airing-notify one-command setup (macOS / Linux)
#   curl -fsSL https://raw.githubusercontent.com/RafaelChipitelli/anime-airing-notify/main/setup.sh | sh
# Forks the repo into your account, asks for the three values, validates each
# one live, stores them as repo secrets and fires the first workflow run.
# Requires the GitHub CLI, authenticated.

set -e
SRC="RafaelChipitelli/anime-airing-notify"

fail() { printf '\n%s\n' "$1" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || fail "GitHub CLI not found. Install it (brew install gh / your package manager), run 'gh auth login', then re-run this script."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not logged in. Run 'gh auth login' and re-run this script."

user=$(gh api user -q .login)
repo="$user/anime-airing-notify"

if [ "$user" = "${SRC%%/*}" ]; then
    echo "You own the source repo; configuring $SRC directly."
    repo="$SRC"
elif gh repo view "$repo" >/dev/null 2>&1; then
    echo "Fork already exists: $repo"
else
    echo "Forking $SRC into $repo..."
    gh repo fork "$SRC" --default-branch-only >/dev/null 2>&1 || fail "Fork failed. Fork it manually on github.com and re-run."
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
printf '%s' "$cid"     | gh secret set MAL_CLIENT_ID   --repo "$repo"
printf '%s' "$maluser" | gh secret set MAL_USERNAME    --repo "$repo"
printf '%s' "$hook"    | gh secret set DISCORD_WEBHOOK --repo "$repo"

echo "Enabling the workflow..."
gh api -X PUT "repos/$repo/actions/permissions" -f enabled=true >/dev/null 2>&1 || true
gh workflow enable airing-check --repo "$repo" >/dev/null 2>&1 || true
if gh workflow run airing-check --repo "$repo" >/dev/null 2>&1; then
    printf '\nDone. First run initializes silently; pings start from the next new episode.\nWatch it at https://github.com/%s/actions\n' "$repo"
else
    printf '\nCould not start the workflow from here (fresh forks sometimes need one click).\nOpen https://github.com/%s/actions, press the enable button, then Run workflow.\n' "$repo"
fi
