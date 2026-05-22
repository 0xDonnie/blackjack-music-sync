# =============================================================================
# config.example.ps1
# Copy this file to config.ps1 and fill in your own values.
# config.ps1 is gitignored and will never be committed.
# =============================================================================

# Base folder where your playlist subfolders live
# Examples:
#   "C:\Music\Playlists"
#   "Z:\MyPlaylists"          (network drive)
#   "\\YOUR-NAS-IP\music"     (UNC path)
$BASE_DIR = "Z:\Music\Playlists"

# Duration tolerance in seconds for local file vs YouTube duration matching
# 5 seconds works well for most cases
$DURATION_TOLERANCE = 5

# OPTIONAL: cookies for authenticated YouTube access (private/age-restricted videos,
# Premium features, etc.). Leave empty if you don't need them.
#
# Two mutually exclusive ways to provide cookies:
#
#   1. Browser-based: yt-dlp reads cookies directly from your browser.
#      The browser must be CLOSED while the sync runs, otherwise the cookie
#      database is locked. Examples:
#         $COOKIES_FROM_BROWSER = "firefox"
#         $COOKIES_FROM_BROWSER = "chrome"
#         $COOKIES_FROM_BROWSER = "edge"
#      For Chromium-based browsers that aren't natively supported (e.g. Comet,
#      Brave, Vivaldi), pass the profile directory path after a colon:
#         $COOKIES_FROM_BROWSER = "chrome:C:\Users\YOU\AppData\Local\Perplexity\Comet\User Data\Default"
#
#   2. File-based: export cookies from your browser to a cookies.txt file using
#      an extension like "Get cookies.txt LOCALLY". Browser can stay open.
#         $COOKIES_FILE = "C:\path\to\cookies.txt"
$COOKIES_FROM_BROWSER = ""
$COOKIES_FILE         = ""

# OPTIONAL: Linux worker host for SSH proxy. If set, the Windows GUI
# (Fetch Name, Multi Add, Refresh Status) tunnels yt-dlp calls through
# this remote machine instead of running them locally. Useful when the
# Windows side has no yt-dlp / no cookies / hits YouTube anti-bot.
# Format: "user@host" (ssh-style). Leave empty to use local yt-dlp.
#   Example: "user@192.168.1.42"
$LINUX_WORKER_HOST = ""

# Your playlists: folder name => YouTube playlist URL
# The folder name must match the subfolder that already exists (or will be created)
$PLAYLISTS = [ordered]@{
    "My Chill Playlist"  = "https://www.youtube.com/playlist?list=XXXXXXXXXXXXXXXXXXX"
    "Workout Mix"        = "https://www.youtube.com/playlist?list=XXXXXXXXXXXXXXXXXXX"
    "Late Night Drives"  = "https://www.youtube.com/playlist?list=XXXXXXXXXXXXXXXXXXX"
    # Add as many as you want...
}
