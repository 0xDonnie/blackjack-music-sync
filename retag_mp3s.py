#!/usr/bin/env python3
"""
retag_mp3s.py — applica ID3 tags coerenti agli mp3 scaricati da yt-dlp.

Logica:
  - Album        = nome cartella playlist (parent dir)
  - Album Artist = nome cartella playlist (per raggruppare in Plex)
  - Track #      = numero estratto dal nome file "NN. *.mp3"
  - Durata < 60min  → "song mode": prova a parsare "Title - Artist" dal video title,
                                   se match: Title = parte SX, Artist = parte DX
  - Durata >= 60min → "mix mode":  mantiene il titolo intero come Title,
                                   Artist resta uploader (o nome playlist se assente)

Idempotente: rieseguibile, sovrascrive sempre Album/Album Artist/Track per coerenza.

Usage:
    retag_mp3s.py <path>                  # path = file o cartella (ricorsivo)
    retag_mp3s.py <path> --dry-run        # mostra cosa farebbe senza scrivere
    retag_mp3s.py <path> --threshold 90   # soglia mix mode in minuti (default 60)

Dipendenze: mutagen (pip install mutagen)
"""

import argparse
import re
import sys
from pathlib import Path

try:
    from mutagen.mp3 import MP3, HeaderNotFoundError
    from mutagen.id3 import ID3, TIT2, TPE1, TPE2, TALB, TRCK, ID3NoHeaderError
except ImportError:
    print("ERROR: serve 'mutagen'. Installa con:  pip install mutagen", file=sys.stderr)
    sys.exit(1)

# Pattern "Left - Right" (con eventuali em-dash o en-dash)
SPLIT_PATTERN = re.compile(r'^\s*(.+?)\s+[-–—]\s+(.+?)\s*$')

# Pattern "NN. Rest of name" per estrarre track number dal filename
TRACK_NUM_PATTERN = re.compile(r'^(\d+)\.\s*(.*)$')


def get_tag(tags, key: str) -> str:
    """Restituisce stringa del primo valore del tag, o '' se assente."""
    if tags is None:
        return ''
    frame = tags.get(key)
    if frame is None:
        return ''
    text = getattr(frame, 'text', None)
    if not text:
        return ''
    return str(text[0]) if isinstance(text, list) else str(text)


def retag_file(path: Path, threshold_seconds: int, dry_run: bool) -> dict:
    """Applica logica di retag a un singolo mp3.

    Returns: dict con info dell'azione, per logging.
    """
    result = {'path': str(path), 'action': '', 'error': None}

    try:
        audio = MP3(path)
    except HeaderNotFoundError:
        result['error'] = 'not a valid mp3'
        return result
    except Exception as e:
        result['error'] = f'mutagen load failed: {e}'
        return result

    duration = audio.info.length
    result['duration_sec'] = duration

    # Assicura che ci sia un ID3 frame
    try:
        if audio.tags is None:
            audio.add_tags()
    except Exception:
        try:
            audio.tags = ID3()
        except Exception as e:
            result['error'] = f'add_tags failed: {e}'
            return result

    tags = audio.tags

    # === Estrazione info ===
    parent_name = path.parent.name
    stem = path.stem
    track_num_match = TRACK_NUM_PATTERN.match(stem)
    track_num = track_num_match.group(1) if track_num_match else ''
    stem_no_track = track_num_match.group(2) if track_num_match else stem

    existing_title = get_tag(tags, 'TIT2')
    existing_artist = get_tag(tags, 'TPE1')

    # Title sorgente: preferisci il TIT2 esistente (yt-dlp video title),
    # altrimenti usa il nome file senza prefisso numerico
    source_title = existing_title if existing_title else stem_no_track

    # === Album / Album Artist / Track # ===
    new_album = parent_name
    new_album_artist = parent_name  # uniformità per Plex
    new_track = track_num

    # === Title / Artist via dispatch durata ===
    if duration < threshold_seconds:
        # Song mode: prova a splittare "X - Y"
        m = SPLIT_PATTERN.match(source_title)
        if m:
            new_title = m.group(1).strip()
            new_artist = m.group(2).strip()
            mode_desc = f'song mode split'
        else:
            new_title = source_title
            new_artist = existing_artist or parent_name
            mode_desc = f'song mode no-split'
    else:
        # Mix mode: tieni il titolo intero, Artist dal uploader o playlist
        new_title = source_title
        new_artist = existing_artist or parent_name
        mode_desc = f'mix mode (>{threshold_seconds//60}min)'

    # Applica
    changes = []
    if get_tag(tags, 'TALB') != new_album:
        changes.append(f'Album: "{get_tag(tags, "TALB")}" → "{new_album}"')
    if get_tag(tags, 'TPE2') != new_album_artist:
        changes.append(f'AlbumArtist: "{get_tag(tags, "TPE2")}" → "{new_album_artist}"')
    if new_track and get_tag(tags, 'TRCK') != new_track:
        changes.append(f'Track#: "{get_tag(tags, "TRCK")}" → "{new_track}"')
    if get_tag(tags, 'TIT2') != new_title:
        changes.append(f'Title: "{get_tag(tags, "TIT2")}" → "{new_title}"')
    if get_tag(tags, 'TPE1') != new_artist:
        changes.append(f'Artist: "{get_tag(tags, "TPE1")}" → "{new_artist}"')

    if not changes:
        result['action'] = f'{mode_desc} — no changes needed'
        return result

    if dry_run:
        result['action'] = f'{mode_desc} DRY-RUN — {" | ".join(changes)}'
        return result

    # Scrittura
    tags.delall('TALB');  tags.add(TALB(encoding=3, text=new_album))
    tags.delall('TPE2');  tags.add(TPE2(encoding=3, text=new_album_artist))
    if new_track:
        tags.delall('TRCK');  tags.add(TRCK(encoding=3, text=new_track))
    tags.delall('TIT2');  tags.add(TIT2(encoding=3, text=new_title))
    tags.delall('TPE1');  tags.add(TPE1(encoding=3, text=new_artist))

    try:
        audio.save()
        result['action'] = f'{mode_desc} — {" | ".join(changes)}'
    except Exception as e:
        result['error'] = f'save failed: {e}'

    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('path', help='File mp3 o cartella (ricorsivo)')
    parser.add_argument('--threshold', type=int, default=60, help='Soglia mix mode in minuti (default 60)')
    parser.add_argument('--dry-run', action='store_true', help='Non scrive, mostra solo cosa farebbe')
    parser.add_argument('--verbose', '-v', action='store_true', help='Stampa anche le tracce no-op')
    args = parser.parse_args()

    threshold_sec = args.threshold * 60
    target = Path(args.path)

    if not target.exists():
        print(f'ERROR: path non trovato: {target}', file=sys.stderr)
        sys.exit(1)

    if target.is_file():
        files = [target]
    else:
        files = sorted(target.rglob('*.mp3'))
        files = [f for f in files if not f.name.endswith('.temp.mp3')]

    total = len(files)
    print(f'=== retag_mp3s ===')
    print(f'Path:      {target}')
    print(f'Threshold: {args.threshold} min')
    print(f'Dry-run:   {args.dry_run}')
    print(f'Files:     {total}')
    print()

    n_changed = 0
    n_noop    = 0
    n_error   = 0

    for i, f in enumerate(files, 1):
        result = retag_file(f, threshold_sec, args.dry_run)
        if result.get('error'):
            n_error += 1
            print(f'[{i}/{total}] ERROR {f.name}: {result["error"]}', file=sys.stderr)
        elif 'no changes needed' in result.get('action', ''):
            n_noop += 1
            if args.verbose:
                print(f'[{i}/{total}] = {f.name}')
        else:
            n_changed += 1
            print(f'[{i}/{total}] ✓ {f.name}')
            print(f'         {result["action"]}')

    print()
    print(f'=== Riepilogo ===')
    print(f'  Modified:  {n_changed}')
    print(f'  No-change: {n_noop}')
    print(f'  Errors:    {n_error}')


if __name__ == '__main__':
    main()
