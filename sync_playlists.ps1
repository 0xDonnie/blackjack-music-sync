# =============================================================================
# blackjack-music-sync - sync_playlists.ps1 v1.0
# https://github.com/0xDonnie/blackjack-music-sync
#
# Keeps your local music folders in sync with YouTube playlists.
# Downloads new tracks as MP3, never deletes or overwrites existing files.
# Matches existing files using duration + title to avoid re-downloading.
# Maintains _id_map.txt, .archive and .m3u for each playlist folder.
# =============================================================================

# Load private config (playlists, paths, settings)
$configPath = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $configPath)) {
    Write-Error "config.ps1 not found. Copy config.example.ps1 to config.ps1 and fill in your details."
    exit 1
}
. $configPath

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
    if (Test-Path $MapPath) {
        Get-Content $MapPath | ForEach-Object {
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
    Set-Content -Path $MapPath -Value $lines -Encoding UTF8
}

# -----------------------------------------------------------------------------
# FUNCTIONS - LOCAL FILES
# -----------------------------------------------------------------------------

function Get-LocalMp3s {
    param([string]$FolderPath)
    return Get-ChildItem -Path $FolderPath -Filter "*.mp3" -ErrorAction SilentlyContinue
}

function Get-FileDuration {
    param([string]$FilePath)
    $result = ffprobe -v quiet -show_entries format=duration -of csv=p=0 $FilePath 2>$null
    if ($result) { return [double]$result }
    return $null
}

function Get-M3uFile {
    param([string]$FolderPath)
    return Get-ChildItem -Path $FolderPath -Filter "*.m3u" -ErrorAction SilentlyContinue | Select-Object -First 1
}

# -----------------------------------------------------------------------------
# FUNCTIONS - YOUTUBE
# -----------------------------------------------------------------------------

function Get-PlaylistEntries {
    param([string]$Url)
    Write-Log "Fetching playlist metadata from YouTube..."
    $json = yt-dlp --flat-playlist --dump-single-json --quiet $Url 2>$null
    if (-not $json) {
        Write-Log "Could not fetch playlist metadata." "ERROR"
        return $null
    }
    $data = $json | ConvertFrom-Json
    return $data.entries
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
    if (Test-Path $ArchivePath) {
        $archivedIds = Get-Content $ArchivePath | ForEach-Object { ($_ -split ' ')[-1] }
    }
    $added = 0
    foreach ($id in $IdMap.Values) {
        if ($archivedIds -notcontains $id) {
            Add-Content -Path $ArchivePath -Value "youtube $id"
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
        $m3u = Get-Item $m3uPath
    }

    $existing   = Get-Content $m3u.FullName | Where-Object { $_ -match '\.mp3$' } | ForEach-Object { $_.Trim() }
    $allMp3s    = Get-ChildItem -Path $FolderPath -Filter "*.mp3" | Sort-Object Name | ForEach-Object { $_.Name }
    $newEntries = $allMp3s | Where-Object { $existing -notcontains $_ }

    if ($newEntries.Count -gt 0) {
        Add-Content -Path $m3u.FullName -Value $newEntries
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

    $destDir     = Join-Path $BASE_DIR $Name
    $archivePath = Join-Path $destDir ".archive"
    $mapPath     = Join-Path $destDir "_id_map.txt"

    Write-Log "==============================="
    Write-Log "Syncing: $Name"

    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
        Write-Log "Created folder: $destDir"
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
    Write-Log "Downloading missing tracks..."
    yt-dlp `
        --extract-audio `
        --audio-format mp3 `
        --audio-quality 0 `
        --embed-thumbnail `
        --add-metadata `
        --no-overwrites `
        --download-archive $archivePath `
        --output "$destDir\%(playlist_index)s. %(title)s.%(ext)s" `
        --ignore-errors `
        $Url

    # 6. Update ID map with newly downloaded files
    $newLocalFiles = Get-LocalMp3s -FolderPath $destDir
    if ($newLocalFiles.Count -gt $localFiles.Count) {
        Write-Log "Updating _id_map.txt with newly downloaded tracks..."
        $idMap = Match-Entries -LocalFiles $newLocalFiles -YoutubeEntries $ytEntries -IdMap $idMap
        Save-IdMap -MapPath $mapPath -Map $idMap
    }

    # 7. Update .m3u
    Update-M3u -FolderPath $destDir -PlaylistName $Name

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
