# =============================================================================
# blackjack-music-sync - uninstall_v3.ps1 (v3.0 - Phase 3)
#
# Removes the blackjacksync:// custom URI scheme registration created by
# install_v3.ps1. Per-user, no admin needed.
# =============================================================================

$schemeKey = "HKCU:\Software\Classes\blackjacksync"

if (Test-Path $schemeKey) {
    Remove-Item -Path $schemeKey -Recurse -Force
    Write-Host "[OK] blackjacksync:// scheme unregistered."
} else {
    Write-Host "blackjacksync:// is not registered. Nothing to do."
}
