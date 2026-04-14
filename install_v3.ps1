# =============================================================================
# blackjack-music-sync - install_v3.ps1 (v3.0 - Phase 3)
#
# Registers the blackjacksync:// custom URI scheme in the user's registry
# (HKEY_CURRENT_USER\Software\Classes), so toast notifications can launch
# bjsync_handler_v1.ps1 when the user clicks "Sync now".
#
# Per-user install — does NOT require admin privileges and does NOT touch
# system-wide registry keys.
#
# Run this ONCE after cloning the repo (or whenever you move the repo).
# Reverse it with uninstall_v3.ps1.
# =============================================================================

$ErrorActionPreference = 'Stop'

$scriptRoot  = $PSScriptRoot
$handlerPath = Join-Path $scriptRoot "bjsync_handler_v1.ps1"

if (-not (Test-Path $handlerPath)) {
    Write-Error "Handler script not found: $handlerPath"
    exit 1
}

# Resolve full path to pwsh.exe (PowerShell 7+). Fall back to bare name if not found.
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { "pwsh.exe" }

$schemeKey = "HKCU:\Software\Classes\blackjacksync"
$cmdKey    = Join-Path $schemeKey "shell\open\command"

# The command Windows runs when blackjacksync:// is activated.
# %1 is replaced by the full URI (e.g. blackjacksync://sync-pending).
# -WindowStyle Hidden keeps the handler invisible — it'll spawn its own
# visible sync window if needed.
$cmdValue = "`"$pwshPath`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$handlerPath`" -Uri `"%1`""

Write-Host "============================================="
Write-Host "blackjack-music-sync v3 - URI scheme install"
Write-Host "============================================="
Write-Host "Registry root:  HKEY_CURRENT_USER\Software\Classes"
Write-Host "Scheme:         blackjacksync"
Write-Host "Handler:        $handlerPath"
Write-Host "Pwsh:           $pwshPath"
Write-Host ""

# Create scheme keys
New-Item -Path $schemeKey -Force | Out-Null
Set-ItemProperty -Path $schemeKey -Name "(default)"    -Value "URL:blackjack-music-sync"
Set-ItemProperty -Path $schemeKey -Name "URL Protocol" -Value ""

# Create shell\open\command path
New-Item -Path (Join-Path $schemeKey "shell")            -Force | Out-Null
New-Item -Path (Join-Path $schemeKey "shell\open")       -Force | Out-Null
New-Item -Path $cmdKey                                   -Force | Out-Null
Set-ItemProperty -Path $cmdKey -Name "(default)" -Value $cmdValue

Write-Host "[OK] blackjacksync:// scheme registered."
Write-Host ""
Write-Host "Test it from PowerShell with:"
Write-Host "    Start-Process 'blackjacksync://sync-pending'"
Write-Host ""
Write-Host "If something goes wrong, check the log at:"
Write-Host "    $(Join-Path $scriptRoot '_v3_handler.log')"
Write-Host ""
Write-Host "To remove the registration, run uninstall_v3.ps1."
