# =============================================================================
# blackjack-music-sync - notify_helper_v1.ps1 (v3.0 - Phase 2)
#
# Windows toast notification helper using BurntToast. Dot-source this from
# check_updates_v1.ps1 (or any other caller) and call Show-PendingToast.
#
# Requires the BurntToast PowerShell module:
#     Install-Module -Name BurntToast -Scope CurrentUser
# =============================================================================

function Show-PendingToast {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TotalPending,

        [Parameter(Mandatory = $true)]
        [array]$Playlists   # array of objects with Name + Pending properties
    )

    # Bail out cleanly if BurntToast isn't installed
    if (-not (Get-Module -ListAvailable -Name BurntToast)) {
        Write-Warning "BurntToast module not installed."
        Write-Warning "Install with: Install-Module -Name BurntToast -Scope CurrentUser"
        return $false
    }
    Import-Module BurntToast -Force -ErrorAction SilentlyContinue

    if ($TotalPending -le 0)                  { return $true }
    if (-not $Playlists -or $Playlists.Count -eq 0) { return $true }

    $playlistCount = $Playlists.Count
    $title         = "blackjack-music-sync"

    # Plural-aware first body line
    $trackWord    = if ($TotalPending -eq 1)  { "new track" }    else { "new tracks" }
    $playlistWord = if ($playlistCount -eq 1) { "playlist" }     else { "playlists" }
    $line1        = "$TotalPending $trackWord in $playlistCount $playlistWord"

    # Second line: top playlists by pending count
    $topPlaylists = @($Playlists | Sort-Object -Property Pending -Descending | Select-Object -First 3)
    $line2parts   = $topPlaylists | ForEach-Object { "$($_.Name) ($($_.Pending))" }
    $line2        = $line2parts -join "  ·  "
    if ($playlistCount -gt 3) {
        $line2 += "  ·  +$($playlistCount - 3) more"
    }

    try {
        # Phase 3: actionable toast with "Sync now" button that fires the
        # blackjacksync://sync-pending URI. Requires install_v3.ps1 to have
        # been run once to register the URI scheme. If it wasn't, Windows
        # will show the "choose an app" dialog instead of launching the sync.
        $btnSync    = New-BTButton -Content "Sync now" -Arguments "blackjacksync://sync-pending" -ActivationType Protocol
        $btnDismiss = New-BTButton -Content "Dismiss"  -Dismiss

        New-BurntToastNotification `
            -Text $title, $line1, $line2 `
            -Button $btnSync, $btnDismiss `
            -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "Failed to show toast: $($_.Exception.Message)"
        return $false
    }
}
