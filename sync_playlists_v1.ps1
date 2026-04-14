# =============================================================================
# blackjack-music-sync - sync_playlists.ps1 v1.0
# https://github.com/0xDonnie/blackjack-music-sync
#
# Keeps your local music folders in sync with YouTube playlists.
# Downloads new tracks as MP3, never deletes or overwrites existing files.
# Matches existing files using duration + title to avoid re-downloading.
# Maintains _id_map.txt, .archive and .m3u for each playlist folder.
# =============================================================================

param(
    # Optional: path to an alternate config file (used by gui.ps1 for partial syncs)
    [string]$ConfigOverride = ""
)

# Load config
$configPath = if ($ConfigOverride -and (Test-Path -LiteralPath $ConfigOverride)) {
    $ConfigOverride
} else {
    Join-Path $PSScriptRoot "config.ps1"
}

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "config.ps1 not found. Copy config.example.ps1 to config.ps1 and fill in your details."
    exit 1
}
. $configPath

# Optional config defaults — keeps older config.ps1 files (without these
# variables) working without error.
if (-not $COOKIES_FROM_BROWSER) { $COOKIES_FROM_BROWSER = "" }
if (-not $COOKIES_FILE)         { $COOKIES_FILE         = "" }

# -----------------------------------------------------------------------------
# FUNCTIONS - FOLDER NAME SANITIZATION
# Replaces characters that Windows forbids in file/folder names with
# visually-similar Unicode equivalents, so the playlist name in the
# config can be used directly as a folder name. Called from Sync-Playlist.
# -----------------------------------------------------------------------------

function ConvertTo-SafeFolderName {
    param([string]$Name)
    if (-not $Name) { return "" }
    # Forbidden-in-Windows → plain ASCII replacements.
    # Separator-like characters become " - "; quotes become '; ? and *
    # are removed entirely (they rarely carry meaning in a playlist name).
    # Square brackets are also replaced with parentheses — technically
    # legal on Windows but PowerShell interprets them as wildcards in
    # some cmdlets and they look ugly as folder names.
    $map = @{
        '<'  = '-'
        '>'  = '-'
        ':'  = ' -'
        '"'  = "'"
        '/'  = ' - '
        '\'  = ' - '
        '|'  = ' - '
        '?'  = ''
        '*'  = ''
        '['  = '('
        ']'  = ')'
    }
    $s = $Name
    foreach ($k in $map.Keys) { $s = $s.Replace($k, $map[$k]) }
    # Strip control chars
    $s = $s -replace '[\x00-\x1F\x7F]', ''
    # Strip emoji and pictographic symbols. Covers:
    #   - BMP misc symbols + dingbats (U+2600..U+27BF, U+2B00..U+2BFF)
    #   - Supplementary-plane emoji (surrogate pairs with high in U+D83C..U+D83E)
    #   - Variation Selector-16 (U+FE0F) and Zero Width Joiner (U+200D)
    #     which decorate base emoji
    $s = $s -replace '[\uD83C-\uD83E][\uDC00-\uDFFF]', ''
    $s = $s -replace '[\u2600-\u27BF]', ''
    $s = $s -replace '[\u2B00-\u2BFF]', ''
    $s = $s -replace '[\uFE0F\u200D]', ''
    # Collapse runs of spaces and dashes introduced by the replacements
    $s = $s -replace '\s+', ' '
    $s = $s -replace '(\s*-\s*){2,}', ' - '
    $s = $s.Trim().TrimEnd('. ')
    # Reserved device names are illegal even without extensions
    $reserved = @('CON','PRN','AUX','NUL',
                  'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
                  'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')
    if ($reserved -contains $s.ToUpper()) { $s = "_$s" }
    return $s
}

# -----------------------------------------------------------------------------
# FUNCTIONS - LOG
# -----------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp][$Level] $Message"
    Write-Host $line
    Add-Content -Path "$BASE_DIR\sync.log" -Value $line
}

# -----------------------------------------------------------------------------
# FUNCTIONS - ID MAP
# Maps local filename => YouTube video ID
# File: _id_map.txt in each playlist folder
# Format: "01. Song title.mp3|youtubeID"
# -----------------------------------------------------------------------------

function Load-IdMap {
    param([string]$MapPath)
    $map = @{}
    if (Test-Path -LiteralPath $MapPath) {
        Get-Content -LiteralPath $MapPath | ForEach-Object {
            $parts = $_ -split '\|'
            if ($parts.Count -eq 2) {
                $map[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
    }
    return $map
}

function Save-IdMap {
    param([string]$MapPath, [hashtable]$Map)
    $lines = $Map.GetEnumerator() | Sort-Object Key | ForEach-Object {
        "$($_.Key)|$($_.Value)"
    }
    Set-Content -LiteralPath $MapPath -Value $lines -Encoding UTF8
}

# -----------------------------------------------------------------------------
# FUNCTIONS - LOCAL FILES
# -----------------------------------------------------------------------------

function Get-LocalMp3s {
    param([string]$FolderPath)
    # Skip yt-dlp's *.temp.mp3 scratch files — they're partial downloads, not finished tracks.
    return Get-ChildItem -LiteralPath $FolderPath -Filter "*.mp3" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*.temp.mp3" }
}

function Get-FileDuration {
    param([string]$FilePath)
    $result = ffprobe -v quiet -show_entries format=duration -of csv=p=0 $FilePath 2>$null
    if ($result) { return [double]$result }
    return $null
}

function Get-M3uFile {
    param([string]$FolderPath)
    return Get-ChildItem -LiteralPath $FolderPath -Filter "*.m3u" -ErrorAction SilentlyContinue | Select-Object -First 1
}

# -----------------------------------------------------------------------------
# FUNCTIONS - YOUTUBE
# -----------------------------------------------------------------------------

function Get-PlaylistEntries {
    param([string]$Url)
    Write-Log "Fetching playlist metadata from YouTube..."
    $tempErr = [System.IO.Path]::GetTempFileName()
    try {
        $json = yt-dlp --flat-playlist --dump-single-json --quiet $Url 2>$tempErr
        if (-not $json -or $json -eq "null") {
            $errText = ""
            if (Test-Path -LiteralPath $tempErr) {
                $errText = (Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue) -as [string]
            }
            if ($errText -match 'does not exist' -or $errText -match '(?i)private') {
                Write-Log "Playlist is PRIVATE or does not exist." "ERROR"
                Write-Log "  → Open it on YouTube and change visibility to 'Unlisted' (or Public) to enable sync." "ERROR"
            } elseif ($errText -match '(?i)sign in|cookies|authentication') {
                Write-Log "Playlist requires authentication (age-restricted or members-only)." "ERROR"
                Write-Log "  → See COOKIES.md for how to pass browser cookies to yt-dlp." "ERROR"
            } else {
                Write-Log "Could not fetch playlist metadata." "ERROR"
                if ($errText) {
                    $firstLine = ($errText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                    if ($firstLine) { Write-Log "  → yt-dlp: $firstLine" "ERROR" }
                }
            }
            return $null
        }
        $data = $json | ConvertFrom-Json
        return $data.entries
    } finally {
        if (Test-Path -LiteralPath $tempErr) {
            Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
        }
    }
}

# -----------------------------------------------------------------------------
# FUNCTIONS - TITLE NORMALIZATION
# -----------------------------------------------------------------------------

function Normalize-Title {
    param([string]$Title)
    $t = $Title.ToLower()
    $t = $t -replace '[^\w\s]', ' '
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

function Strip-TrackNumber {
    param([string]$FileName)
    return ($FileName -replace '^\d+\.\s*', '').Trim()
}

# -----------------------------------------------------------------------------
# FUNCTIONS - MATCHING
# Combines duration + title for reliable matching
# -----------------------------------------------------------------------------

function Match-Entries {
    param(
        [System.IO.FileInfo[]]$LocalFiles,
        [array]$YoutubeEntries,
        [hashtable]$IdMap
    )

    $matched = 0

    foreach ($ytEntry in $YoutubeEntries) {
        $ytId    = $ytEntry.id
        $ytTitle = $ytEntry.title
        $ytDur   = $ytEntry.duration

        # Already mapped - skip
        if ($IdMap.Values -contains $ytId) { continue }

        $normalizedYt = Normalize-Title -Title $ytTitle
        $bestMatch = $null

        foreach ($file in $LocalFiles) {
            $baseName        = Strip-TrackNumber -FileName $file.BaseName
            $normalizedLocal = Normalize-Title -Title $baseName

            # Title check
            $minLen = [Math]::Min($normalizedYt.Length, $normalizedLocal.Length)
            $titleMatch = $minLen -ge 8 -and (
                $normalizedLocal -like "*$normalizedYt*" -or
                $normalizedYt -like "*$normalizedLocal*"
            )
            if (-not $titleMatch) { continue }

            # Duration check
            if ($ytDur -and $ytDur -gt 0) {
                $localDur = Get-FileDuration -FilePath $file.FullName
                if ($localDur) {
                    $diff = [Math]::Abs($localDur - $ytDur)
                    if ($diff -le $DURATION_TOLERANCE) {
                        $bestMatch = $file.Name
                        break
                    }
                    continue  # title matched but duration did not - skip
                }
            }

            # YouTube duration unavailable - trust title only
            $bestMatch = $file.Name
            break
        }

        if ($bestMatch) {
            Write-Log "Match: '$bestMatch' => '$ytTitle' (ID: $ytId)"
            $IdMap[$bestMatch] = $ytId
            $matched++
        }
    }

    Write-Log "New matches found: $matched"
    return $IdMap
}

# -----------------------------------------------------------------------------
# FUNCTIONS - ARCHIVE
# -----------------------------------------------------------------------------

function Populate-Archive {
    param([string]$ArchivePath, [hashtable]$IdMap)
    $archivedIds = @()
    if (Test-Path -LiteralPath $ArchivePath) {
        $archivedIds = Get-Content -LiteralPath $ArchivePath | ForEach-Object { ($_ -split ' ')[-1] }
    }
    $added = 0
    foreach ($id in $IdMap.Values) {
        if ($archivedIds -notcontains $id) {
            Add-Content -LiteralPath $ArchivePath -Value "youtube $id"
            $added++
        }
    }
    Write-Log "IDs added to yt-dlp archive: $added"
}

# -----------------------------------------------------------------------------
# FUNCTIONS - M3U
# -----------------------------------------------------------------------------

function Update-M3u {
    param([string]$FolderPath, [string]$PlaylistName)

    $m3u = Get-M3uFile -FolderPath $FolderPath
    if (-not $m3u) {
        $m3uPath = Join-Path $FolderPath "$PlaylistName.m3u"
        New-Item -Path $m3uPath -ItemType File | Out-Null
        $m3u = Get-Item -LiteralPath $m3uPath
    }

    $existing   = Get-Content -LiteralPath $m3u.FullName | Where-Object { $_ -match '\.mp3$' } | ForEach-Object { $_.Trim() }
    $allMp3s    = Get-ChildItem -LiteralPath $FolderPath -Filter "*.mp3" |
                    Where-Object { $_.Name -notlike "*.temp.mp3" } |
                    Sort-Object Name | ForEach-Object { $_.Name }
    $newEntries = $allMp3s | Where-Object { $existing -notcontains $_ }

    if ($newEntries.Count -gt 0) {
        Add-Content -LiteralPath $m3u.FullName -Value $newEntries
        Write-Log "M3U updated with $($newEntries.Count) new track(s)."
    } else {
        Write-Log "M3U already up to date."
    }
}

# -----------------------------------------------------------------------------
# MAIN SYNC FUNCTION
# -----------------------------------------------------------------------------

function Sync-Playlist {
    param([string]$Name, [string]$Url)

    # Sanitize for filesystem use — keeps $Name unchanged for logging
    $folderName  = ConvertTo-SafeFolderName -Name $Name
    $destDir     = Join-Path $BASE_DIR $folderName
    $archivePath = Join-Path $destDir ".archive"
    $mapPath     = Join-Path $destDir "_id_map.txt"

    Write-Log "==============================="
    Write-Log "Syncing: $Name"
    if ($folderName -ne $Name) {
        Write-Log "  (folder name sanitized to: $folderName)"
    }

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
        Write-Log "Created folder: $destDir"
    }

    # Normalize URL to the clean playlist form. YouTube playlist links
    # often come as "watch?v=VIDEOID&list=PLAYLISTID&pp=sAgC" which yt-dlp
    # can sometimes interpret as "download only this one video in the
    # playlist context" rather than the full playlist. Rewriting it to
    # "playlist?list=PLAYLISTID" makes the intent explicit and consistent.
    if ($Url -match 'list=([\w-]+)') {
        $cleanUrl = "https://www.youtube.com/playlist?list=$($matches[1])"
        if ($cleanUrl -ne $Url) {
            Write-Log "  URL normalized: $cleanUrl"
            $Url = $cleanUrl
        }
    }

    # 1. Fetch YouTube metadata
    $ytEntries = Get-PlaylistEntries -Url $Url
    if (-not $ytEntries) {
        Write-Log "Skipping: $Name" "ERROR"
        return
    }
    Write-Log "Tracks on YouTube: $($ytEntries.Count)"

    # 2. Load existing ID map
    $idMap = Load-IdMap -MapPath $mapPath
    Write-Log "Already mapped: $($idMap.Count)"

    # 3. Match local files to YouTube entries via duration + title
    $localFiles = Get-LocalMp3s -FolderPath $destDir
    if ($localFiles.Count -gt 0) {
        Write-Log "Local files: $($localFiles.Count) - matching..."
        $idMap = Match-Entries -LocalFiles $localFiles -YoutubeEntries $ytEntries -IdMap $idMap
        Save-IdMap -MapPath $mapPath -Map $idMap
    }

    # 4. Populate .archive from ID map so yt-dlp skips already-present tracks
    Populate-Archive -ArchivePath $archivePath -IdMap $idMap

    # 5. Download missing tracks only
    # --remote-components ejs:github enables yt-dlp to download the Enhanced
    # JS Challenge Solver from GitHub, which is required by many modern
    # YouTube videos that use SABR streaming + JS challenges.
    Write-Log "Downloading missing tracks..."
    # IMPORTANT: the Tee-Object target MUST be on local disk. If it lives
    # on the NAS ($destDir), any transient SMB hiccup breaks the pipe
    # mid-download, which kills yt-dlp and leaves later items in the
    # playlist un-downloaded. Keep it in the local %TEMP%.
    $ytOutputPath = Join-Path $env:TEMP ("_yt_output_tmp_" + [guid]::NewGuid().Guid + ".log")
    # Use a local temp dir for all intermediate yt-dlp / ffmpeg work.
    # NAS (SMB) is flaky under heavy concurrent read+write during audio
    # extraction, metadata embedding, and thumbnail merging — causing
    # "audio conversion failed" / "Conversion failed!" errors for large
    # files. With --paths temp:LOCAL and --paths home:$destDir, yt-dlp
    # downloads and processes the files entirely on local disk, then
    # moves only the final .mp3 to the NAS.
    $ytTempDir = Join-Path $env:TEMP "blackjack-ytdlp-work"
    if (-not (Test-Path -LiteralPath $ytTempDir)) {
        New-Item -Path $ytTempDir -ItemType Directory -Force | Out-Null
    }

    $ytArgs = @(
        "--extract-audio",
        "--audio-format", "mp3",
        "--audio-quality", "0",
        "--embed-thumbnail",
        "--add-metadata",
        "--no-overwrites",
        "--yes-playlist",
        "--remote-components", "ejs:github",
        "--download-archive", $archivePath,
        "--paths", "temp:$ytTempDir",
        "--paths", "home:$destDir",
        "--output", "%(playlist_index)s. %(title)s.%(ext)s",
        "--ignore-errors"
    )
    if ($COOKIES_FROM_BROWSER) {
        $ytArgs += @("--cookies-from-browser", $COOKIES_FROM_BROWSER)
        Write-Log "Using cookies from browser: $COOKIES_FROM_BROWSER"
    }
    if ($COOKIES_FILE -and (Test-Path -LiteralPath $COOKIES_FILE)) {
        $ytArgs += @("--cookies", $COOKIES_FILE)
        Write-Log "Using cookies file: $COOKIES_FILE"
    }
    $ytArgs += $Url
    # Use PowerShell's native `*>` redirect to write all yt-dlp output
    # streams directly to the local temp file. No PowerShell pipeline in
    # between (no Tee-Object, no Out-File piping), so yt-dlp's stdout
    # cannot be preempted mid-stream. The call operator `&` plus @ytArgs
    # splatting correctly quotes arguments that contain spaces.
    & yt-dlp @ytArgs *> $ytOutputPath
    $ytExitCode = $LASTEXITCODE
    Write-Log "yt-dlp exit code: $ytExitCode"
    # Relay the captured output to our own stdout so the GUI log sees it
    if (Test-Path -LiteralPath $ytOutputPath) {
        Get-Content -LiteralPath $ytOutputPath | Write-Host
    }

    # 5a. Post-download file name cleanup.
    # yt-dlp names output files after the YouTube title which can contain
    # emoji / reserved chars / weird unicode. The folder was already
    # sanitized but the files inside weren't. Walk the folder and rename
    # each .mp3 to a sanitized version that strips the same characters
    # ConvertTo-SafeFolderName strips, preserving the "NN. " track
    # number prefix.
    Get-ChildItem -LiteralPath $destDir -Filter "*.mp3" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*.temp.mp3" } |
        ForEach-Object {
            $oldName = $_.Name
            $base    = [System.IO.Path]::GetFileNameWithoutExtension($oldName)
            $ext     = $_.Extension
            $trackPrefix = ""
            $title       = $base
            if ($base -match '^(\d+\.\s+)(.*)$') {
                $trackPrefix = $matches[1]
                $title       = $matches[2]
            }
            $cleanTitle = ConvertTo-SafeFolderName -Name $title
            if ([string]::IsNullOrWhiteSpace($cleanTitle)) { return }
            $newName = "$trackPrefix$cleanTitle$ext"
            if ($newName -eq $oldName) { return }
            $newPath = Join-Path $destDir $newName
            if (Test-Path -LiteralPath $newPath) { return }  # don't clobber
            try {
                Rename-Item -LiteralPath $_.FullName -NewName $newName -ErrorAction Stop
                Write-Log "  Renamed: '$oldName' -> '$newName'"
            } catch {
                Write-Log "  Could not rename '$oldName': $($_.Exception.Message)" "ERROR"
            }
        }

    # 5b. Parse yt-dlp output for unavailable videos and REBUILD _unavailable.txt
    # from scratch based on errors from this run only. Any IDs that became
    # available (successfully downloaded, now in .archive) or got removed from
    # the playlist will be cleaned out automatically.
    # Matches lines like "ERROR: [youtube] VIDEOID: Video unavailable..." or "Private video"
    $unavailablePath = Join-Path $destDir "_unavailable.txt"
    $currentUnavailable = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $ytOutputPath) {
        Get-Content -LiteralPath $ytOutputPath | ForEach-Object {
            if ($_ -match 'ERROR: \[youtube\] (\S+):') {
                $id = $matches[1]
                if (-not $currentUnavailable.Contains($id)) {
                    [void]$currentUnavailable.Add($id)
                }
            }
        }
        Remove-Item -LiteralPath $ytOutputPath -ErrorAction SilentlyContinue
    }
    # Compare against what was there before for a meaningful log line
    $previousUnavailable = @()
    if (Test-Path -LiteralPath $unavailablePath) {
        $previousUnavailable = Get-Content -LiteralPath $unavailablePath | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    if ($currentUnavailable.Count -gt 0) {
        Set-Content -LiteralPath $unavailablePath -Value $currentUnavailable -Encoding UTF8
        $recovered = @($previousUnavailable | Where-Object { $currentUnavailable -notcontains $_ }).Count
        if ($recovered -gt 0) {
            Write-Log "Unavailable tracks: $($currentUnavailable.Count) total ($recovered recovered since last sync)"
        } else {
            Write-Log "Unavailable tracks: $($currentUnavailable.Count) total"
        }
    } elseif (Test-Path -LiteralPath $unavailablePath) {
        Remove-Item -LiteralPath $unavailablePath -ErrorAction SilentlyContinue
        Write-Log "All tracks now downloadable - cleaned up _unavailable.txt"
    }

    # 6. Update ID map with newly downloaded files
    $newLocalFiles = Get-LocalMp3s -FolderPath $destDir
    if ($newLocalFiles.Count -gt $localFiles.Count) {
        Write-Log "Updating _id_map.txt with newly downloaded tracks..."
        $idMap = Match-Entries -LocalFiles $newLocalFiles -YoutubeEntries $ytEntries -IdMap $idMap
        Save-IdMap -MapPath $mapPath -Map $idMap
    }

    # 7. Update .m3u
    Update-M3u -FolderPath $destDir -PlaylistName $folderName

    Write-Log "Done: $Name"
    Write-Log "==============================="
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

Write-Log "============================================="
Write-Log "blackjack-music-sync v1.0 - starting"
Write-Log "============================================="

foreach ($entry in $PLAYLISTS.GetEnumerator()) {
    Sync-Playlist -Name $entry.Key -Url $entry.Value
}

Write-Log "============================================="
Write-Log "All playlists synced."
Write-Log "============================================="
