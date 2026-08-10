# anime-airing-notify one-command setup (Windows)
#   irm https://raw.githubusercontent.com/RafaelChipitelli/anime-airing-notify/main/setup.ps1 | iex
# Forks the repo into your account, asks for the three values, validates each
# one live, stores them as repo secrets and fires the first workflow run.
# No prerequisites: if the GitHub CLI is missing, a portable copy is
# downloaded to your temp folder (it handles the OAuth login and the
# libsodium encryption that repo secrets require).

$ErrorActionPreference = "Stop"
$SRC = "RafaelChipitelli/anime-airing-notify"

function Fail($msg) { Write-Host "`n$msg" -ForegroundColor Yellow; exit 1 }

$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) {
    Write-Host "GitHub CLI not found; downloading a portable copy (~14 MB, temp folder only)..."
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/cli/cli/releases/latest" -Headers @{ "User-Agent" = "anime-airing-notify-setup" }
        $asset = $rel.assets | Where-Object name -like "*windows_amd64.zip" | Select-Object -First 1
        $dir = Join-Path $env:TEMP ("gh-portable-" + $rel.tag_name)
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Force $dir | Out-Null
            $zipPath = Join-Path $dir "gh.zip"
            Invoke-WebRequest $asset.browser_download_url -OutFile $zipPath
            Expand-Archive $zipPath -DestinationPath $dir -Force
        }
        $gh = (Get-ChildItem $dir -Recurse -Filter gh.exe | Select-Object -First 1).FullName
        if (-not $gh) { throw "gh.exe not found after extraction" }
    } catch {
        Fail "Could not download the GitHub CLI ($($_.Exception.Message)). Install it manually:`n  winget install --id GitHub.CLI`nand re-run this script."
    }
}

& $gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Logging into GitHub: your browser will open, approve it there (one-time code, no password in this terminal)."
    & $gh auth login --web --hostname github.com --git-protocol https
    & $gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { Fail "GitHub login did not complete. Re-run this script to try again." }
}

$user = & $gh api user -q .login
$repo = "$user/anime-airing-notify"

if ($user -eq $SRC.Split("/")[0]) {
    Write-Host "You own the source repo; configuring $SRC directly."
    $repo = $SRC
} else {
    & $gh repo view $repo *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Forking $SRC into $repo..."
        & $gh repo fork $SRC --default-branch-only *> $null
        if ($LASTEXITCODE -ne 0) { Fail "Fork failed. Fork it manually on github.com and re-run." }
    } else {
        Write-Host "Fork already exists: $repo"
    }
}

Write-Host ""
Write-Host "Three values needed (each gets validated before anything is stored)." -ForegroundColor Cyan

# 1. MAL client id
Write-Host "`n1/3  MAL client id"
Write-Host "     myanimelist.net/apiconfig -> Create ID -> App Type: other -> Redirect URL: http://localhost"
$cid = (Read-Host "     paste the Client ID").Trim()
try {
    Invoke-RestMethod "https://api.myanimelist.net/v2/anime?q=test&limit=1" -Headers @{ "X-MAL-CLIENT-ID" = $cid } | Out-Null
    Write-Host "     ok: MAL accepted the client id" -ForegroundColor Green
} catch { Fail "MAL rejected that client id (HTTP $($_.Exception.Response.StatusCode.value__)). Copy it again from myanimelist.net/apiconfig." }

# 2. MAL username
Write-Host "`n2/3  MAL username (the anime list must be public, which is the MAL default)"
$malUser = (Read-Host "     username").Trim()
try {
    Invoke-RestMethod "https://api.myanimelist.net/v2/users/$malUser/animelist?limit=1&nsfw=true" -Headers @{ "X-MAL-CLIENT-ID" = $cid } | Out-Null
    Write-Host "     ok: list of '$malUser' is readable" -ForegroundColor Green
} catch { Fail "Could not read the list of '$malUser' (HTTP $($_.Exception.Response.StatusCode.value__)). Check the spelling and that the list is public (MAL -> Profile -> Privacy)." }

# 3. Discord webhook
Write-Host "`n3/3  Discord webhook"
Write-Host "     your server -> channel -> gear (Edit Channel) -> Integrations -> Webhooks -> New Webhook -> Copy URL"
$hook = (Read-Host "     paste the Webhook URL").Trim()
if ($hook -notmatch "^https://discord\.com/api/webhooks/") { Fail "That does not look like a Discord webhook URL." }
try {
    Invoke-RestMethod -Method Post -Uri $hook -ContentType "application/json" `
        -Body '{"content": "anime-airing-notify: setup test, this channel will receive the episode pings"}' | Out-Null
    Write-Host "     ok: test message posted, check the channel" -ForegroundColor Green
} catch { Fail "Discord rejected the webhook (HTTP $($_.Exception.Response.StatusCode.value__)). Copy the URL again." }

Write-Host "`nStoring the three values as secrets of $repo..."
$cid     | & $gh secret set MAL_CLIENT_ID   --repo $repo
$malUser | & $gh secret set MAL_USERNAME    --repo $repo
$hook    | & $gh secret set DISCORD_WEBHOOK --repo $repo

Write-Host "Enabling the workflow..."
& $gh api -X PUT "repos/$repo/actions/permissions" -f enabled=true *> $null
& $gh workflow enable airing-check --repo $repo *> $null
& $gh workflow run airing-check --repo $repo *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nCould not start the workflow from here (fresh forks sometimes need one click)." -ForegroundColor Yellow
    Write-Host "Open https://github.com/$repo/actions, press the enable button, then Run workflow."
} else {
    Write-Host "`nDone. First run initializes silently; pings start from the next new episode." -ForegroundColor Green
    Write-Host "Watch it at https://github.com/$repo/actions"
}
