# =============================================================================
# blackjack-music-sync - schedule_v3.ps1 (v3.0 - Phase 4)
#
# Interactive installer/manager for the Windows Task Scheduler entry that
# runs check_updates_v1.ps1 on a recurring schedule and fires a toast when
# there are pending tracks.
#
# Per-user task — no admin required. The task only runs while the user is
# logged on (so the toast can actually appear in the user session).
#
# Frequency options use -Daily -DaysInterval N because the underlying
# Task Scheduler trigger types don't natively cover "every 3 days" or
# "every 6 months". DaysInterval supports values from 1 to 365.
# =============================================================================

$taskName    = "BlackjackMusicSyncCheck"
$scriptRoot  = $PSScriptRoot
$checkScript = Join-Path $scriptRoot "check_updates_v1.ps1"

if (-not (Test-Path $checkScript)) {
    Write-Error "check_updates_v1.ps1 not found at: $checkScript"
    exit 1
}

$pwshCmd  = Get-Command pwsh -ErrorAction SilentlyContinue
$pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { "pwsh.exe" }

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------

function Show-Header {
    Write-Host ""
    Write-Host "============================================="
    Write-Host "blackjack-music-sync v3 - schedule installer"
    Write-Host "============================================="
}

function Show-CurrentStatus {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "Current task '$taskName' : INSTALLED" -ForegroundColor Green
        if ($info) {
            # Task Scheduler returns sentinel values like 11/30/1999 or
            # 12/30/1899 for "never run". Filter anything before 2010.
            if ($info.LastRunTime -and $info.LastRunTime.Year -ge 2010) {
                Write-Host "  Last run: $($info.LastRunTime)"
            } else {
                Write-Host "  Last run: never"
            }
            if ($info.NextRunTime -and $info.NextRunTime.Year -ge 2010) {
                Write-Host "  Next run: $($info.NextRunTime)"
            }
        }
    } else {
        Write-Host ""
        Write-Host "Current task '$taskName' : not installed" -ForegroundColor DarkGray
    }
}

function Show-Menu {
    Write-Host ""
    Write-Host "Choose what to do:"
    Write-Host ""
    Write-Host "  [1] Install schedule: DAILY"
    Write-Host "  [2] Install schedule: every 3 DAYS"
    Write-Host "  [3] Install schedule: WEEKLY (every 7 days)"
    Write-Host "  [4] Install schedule: MONTHLY (every 30 days)"
    Write-Host "  [5] Install schedule: SEMESTRAL (every 180 days)"
    Write-Host ""
    Write-Host "  [N] Run check NOW (one-off, no schedule change)"
    Write-Host "  [U] Uninstall existing schedule"
    Write-Host "  [Q] Quit"
    Write-Host ""
}

function Install-CheckTask {
    param(
        [Parameter(Mandatory)][int]$DaysInterval,
        [Parameter(Mandatory)][string]$Label
    )

    Write-Host ""
    $timeInput = Read-Host "Time of day to run, HH:MM (default 09:00)"
    if (-not $timeInput) { $timeInput = "09:00" }
    try {
        $atTime = [datetime]::ParseExact($timeInput, "HH:mm", $null)
    } catch {
        Write-Host "Invalid time format. Use HH:MM (e.g. 09:00 or 21:30)." -ForegroundColor Red
        return
    }

    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$checkScript`" -Notify -Quiet"

    $action = New-ScheduledTaskAction `
        -Execute $pwshPath `
        -Argument $argString `
        -WorkingDirectory $scriptRoot

    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $DaysInterval -At $atTime

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    $userId = "$env:USERDOMAIN\$env:USERNAME"
    if (-not $env:USERDOMAIN) { $userId = "$env:COMPUTERNAME\$env:USERNAME" }

    $principal = New-ScheduledTaskPrincipal `
        -UserId $userId `
        -LogonType Interactive `
        -RunLevel Limited

    # Wipe any existing task before re-registering
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    try {
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Description "blackjack-music-sync: checks YouTube playlists for new tracks ($Label)" `
            -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ""
        Write-Host "Failed to register task: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "[OK] Task installed: $taskName" -ForegroundColor Green
    Write-Host "  Frequency: $Label"
    Write-Host "  Time:      $timeInput"
    Write-Host "  Command:   $pwshPath $argString"
    Write-Host ""
    Write-Host "Open Task Scheduler ('taskschd.msc') to inspect or modify it."
    Write-Host "To remove the schedule, re-run this script and choose [U]."
}

function Uninstall-CheckTask {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host ""
        Write-Host "[OK] Task '$taskName' uninstalled." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "Task '$taskName' is not installed. Nothing to do."
    }
}

function Run-Now {
    Write-Host ""
    Write-Host "Running check_updates_v1.ps1 -Notify ..."
    & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $checkScript -Notify
    Write-Host ""
    Write-Host "Done."
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

Show-Header
Show-CurrentStatus
Show-Menu
$choice = Read-Host "Choice"

switch ($choice.ToUpper().Trim()) {
    "1" { Install-CheckTask -DaysInterval 1   -Label "daily" }
    "2" { Install-CheckTask -DaysInterval 3   -Label "every 3 days" }
    "3" { Install-CheckTask -DaysInterval 7   -Label "weekly" }
    "4" { Install-CheckTask -DaysInterval 30  -Label "monthly (~30 days)" }
    "5" { Install-CheckTask -DaysInterval 180 -Label "semestral (~180 days)" }
    "N" { Run-Now }
    "U" { Uninstall-CheckTask }
    "Q" { Write-Host ""; Write-Host "Goodbye." }
    default {
        Write-Host ""
        Write-Host "Invalid choice: '$choice'" -ForegroundColor Red
    }
}
