# =============================================================================
# blackjack-music-sync - bjsync_handler_v1.ps1 (v3.0 - Phase 3)
#
# Custom URI handler for blackjacksync://...
#
# Launched by Windows when the user clicks an action button on a
# blackjack-music-sync toast notification. Registered in the user's
# registry by install_v3.ps1.
#
# Currently supports a single action:
#   blackjacksync://sync-pending
#     - Reads _v3_pending.json
#     - Builds a temp config file containing only playlists with pending tracks
#     - Launches sync_playlists_v1.ps1 in a new visible PowerShell window so
#       the user can watch progress
# =============================================================================

param(
    [string]$Uri = ""
)

# Lightweight log for debugging URI handler invocations
$logPath = Join-Path $PSScriptRoot "_v3_handler.log"
function Write-HandlerLog {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Add-Content -Path $logPath
}

Write-HandlerLog "Invoked with URI: '$Uri'"

# Strip the scheme prefix and any trailing slashes
$action = $Uri -replace '^blackjacksync:[/]*', ''
$action = $action.TrimEnd('/')
Write-HandlerLog "Parsed action: '$action'"

# Helper for visible error popups (handler runs hidden, so console errors
# would be invisible)
function Show-Error {
    param([string]$Message, [string]$Title = "blackjack-music-sync")
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, "OK", "Error") | Out-Null
}

# -----------------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------------

$configPath = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-HandlerLog "config.ps1 not found at $configPath"
    Show-Error "config.ps1 not found at:`n$configPath"
    exit 1
}
. $configPath
if (-not $COOKIES_FROM_BROWSER) { $COOKIES_FROM_BROWSER = "" }
if (-not $COOKIES_FILE)         { $COOKIES_FILE         = "" }

# -----------------------------------------------------------------------------
# Action: sync-pending
# -----------------------------------------------------------------------------

if (-not $action -or $action -eq "sync-pending") {
    $pendingPath = Join-Path $PSScriptRoot "_v3_pending.json"
    if (-not (Test-Path -LiteralPath $pendingPath)) {
        Write-HandlerLog "No pending state file"
        Show-Error "No pending state file found.`n`nRun check_updates_v1.ps1 first to populate it."
        exit 1
    }

    try {
        $state = Get-Content -LiteralPath $pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-HandlerLog "Failed to parse pending JSON: $_"
        Show-Error "Could not read _v3_pending.json:`n$_"
        exit 1
    }

    if (-not $state.PlaylistsWithUpdates -or @($state.PlaylistsWithUpdates).Count -eq 0) {
        Write-HandlerLog "Nothing pending in state file"
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            "Nothing pending right now.`n`nThe state may be stale — re-run check_updates_v1.ps1 to refresh.",
            "blackjack-music-sync", "OK", "Information") | Out-Null
        exit 0
    }

    Write-HandlerLog "Pending playlists: $(@($state.PlaylistsWithUpdates).Count)"

    # Build temp config with only playlists that have pending
    $tempConfig = Join-Path $PSScriptRoot "_temp_v3_sync_config.ps1"
    $lines = @(
        "`$BASE_DIR = `"$BASE_DIR`"",
        "`$DURATION_TOLERANCE = $DURATION_TOLERANCE",
        "`$COOKIES_FROM_BROWSER = `"$($COOKIES_FROM_BROWSER -replace '"','`"')`"",
        "`$COOKIES_FILE = `"$($COOKIES_FILE -replace '"','`"')`"",
        "`$PLAYLISTS = [ordered]@{"
    )
    foreach ($p in $state.PlaylistsWithUpdates) {
        $escapedKey = $p.Name -replace '"', '`"'
        $lines += "    `"$escapedKey`" = `"$($p.Url)`""
    }
    $lines += "}"
    Set-Content -LiteralPath $tempConfig -Value $lines -Encoding UTF8
    Write-HandlerLog "Wrote temp config: $tempConfig"

    # Launch the sync in a new visible PowerShell window so the user sees
    # progress. -NoExit keeps the window open after the sync finishes so
    # the user can read the final summary.
    $syncScript = Join-Path $PSScriptRoot "sync_playlists_v1.ps1"
    if (-not (Test-Path -LiteralPath $syncScript)) {
        Write-HandlerLog "sync_playlists_v1.ps1 not found"
        Show-Error "sync_playlists_v1.ps1 not found at:`n$syncScript"
        exit 1
    }

    Write-HandlerLog "Launching sync in new pwsh window..."
    Start-Process -FilePath "pwsh.exe" -ArgumentList @(
        "-NoExit",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$syncScript`"",
        "-ConfigOverride", "`"$tempConfig`""
    ) | Out-Null

    Write-HandlerLog "Sync launched."
    exit 0
}

# -----------------------------------------------------------------------------
# Unknown action
# -----------------------------------------------------------------------------

Write-HandlerLog "Unknown action: $action"
Show-Error "Unknown blackjacksync:// action: '$action'"
exit 1
