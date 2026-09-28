# KCC auto-conversion for the manga library — design

Date: 2026-09-28
Status: approved (brainstorm), pending implementation plan

## Goal

Every manga chapter in the library is optimised for the Boox Go 10.3 with
Kindle Comic Converter (KCC), automatically, and the Boox replaces the copies
it already has with the converted versions.

- New chapters Suwayomi downloads are converted shortly after they land.
- The existing backlog (~3964 chapters, 38 GB) is converted by the same loop.
- The Boox notices a chapter changed on the server and re-downloads it.

## Context

- **Suwayomi** (`manga-stack` on `bussybox.live`) downloads chapters as CBZ into
  `/data/nas/media/manga` (`mangas/<source>/<series>/<chapter>.cbz`).
- **Komga** mounts that tree read-only and serves it (REST + OPDS). Komga book
  IDs are tied to file paths.
- **Boox** pulls chapters with `maki.koplugin` from Komga's OPDS feed. Maki's
  per-series ledger (`.maki.lua`, `fetched[acquisition_url] = {file, at}`) is
  keyed by URL and a fetched URL is never looked at again. The acquisition URL
  contains book ID + filename, so **a file replaced in place under the same
  name is invisible to Maki today.**
- Komga OPDS entries carry `<updated>` (ISO-8601 with offset), which is the
  change signal this design relies on.
- Progress push-back (tana → Komga REST), "Continue from server" and the
  AniList bridge all key on Komga book IDs; the bridge also relies on chapter
  numbers from `ComicInfo.xml`.
- The Kindle is retired; nothing else needs the original scans.
- Disk: 523 GB free on `/data/nas`. Converted chapters are ~1.5x the original
  size (ch1: 28 MB → 42 MB), so the backfill costs roughly +20 GB.

## Approach

Convert **in place**: same path, same filename. Komga keeps the same book ID,
so every ID-keyed integration keeps working unchanged. The original is kept
only as a temporary copy during conversion and deleted once the converted file
is verified and swapped in. Maki learns to compare the feed's `<updated>`
against what it downloaded and re-fetch changed chapters.

Rejected: a separate KCC library in Komga (new book IDs → migrate Boox
markers, progress push-back and bridge library IDs; every series shown twice),
and converting on the device (too slow).

## KCC settings

KCC is pinned to `ciromattia/kcc` commit `f127adb` (v12.0.0). It is not
published on PyPI; install from the git checkout using
`requirements-docker.txt` plus `numpy` and `PyMuPDF`.

```
kcc-c2e -p OTHER --customwidth 1860 --customheight 2480 -m -u -r 1 --norotate \
        --autolevel --forcepng --keepcomicinfo 1 -f CBZ -o <outdir>/ <input.cbz>
```

| Flag | Effect | Why |
|---|---|---|
| `-p OTHER --customwidth 1860 --customheight 2480` | Target the exact panel resolution | No Boox preset in KCC. `OTHER` also means gamma 1.0 (no gamma change). |
| `-m` | Manga mode, right-to-left | Required for correct reading order. |
| `-u` | Upscale pages smaller than the screen | Source scans are 1200×1722; KCC's resample is cleaner than on-the-fly scaling. |
| `-r 1 --norotate` | Do not split spreads; do not rotate them | Spreads stay whole and landscape at native resolution; yoko.koplugin auto-rotates them on the device. |
| `--autolevel` | Set the most common dark grey as the black point | Deepens "black" ink that scans as dark grey. |
| `--forcepng` | PNG output, quantised to the 16-grey palette | Matches the e-ink panel's 16 levels; no JPEG artifacts. |
| `--keepcomicinfo 1` | Keep `ComicInfo.xml` in the output | Komga reads chapter numbers from it; the AniList bridge depends on them. |
| `-f CBZ` | CBZ output | Native to Komga and KOReader. |

Left at defaults: grayscale on, autocontrast on, cropping `-c 2` (margins +
page numbers), gamma 1.0. Gamma 1.8 was compared on the device and not chosen.

Verified on SBR ch1 with these settings: spreads remain whole landscape pages
at source resolution (e.g. 2133×1530); the output page count equals the
source page count (48 = 48), so page positions and reading progress do not
shift; `ComicInfo.xml` is present in the output.

A settings version string, `kcc-f127adb-go103-v1`, identifies this
configuration in the converter state.

## Architecture

```
Suwayomi ──writes CBZ──▶ /data/nas/media/manga ◀──reads (ro)── Komga ──OPDS <updated>──▶ Maki (Boox)
                               ▲                                  ▲
                    manga-kcc ─┘ convert in place                 └─ POST scan after each batch
```

## Component 1: `manga-kcc` container

Lives in `~/manga-stack/kcc/` on `bussybox.live` (the live deployment repo),
added to `docker-compose.yml` as service `kcc`, container name `manga-kcc`.

**Image.** Dockerfile based on `python:3.12-slim`: clones KCC at `f127adb`,
installs `requirements-docker.txt` + `numpy` + `PyMuPDF`, copies
`converter.py`. Built by compose (`build: ./kcc`), like `kindle-sync`.

**Mounts and environment.**
- `/data/nas/media/manga:/manga` (read-write).
- Named volume `kcc_state:/state` holding `state.json` and the scratch dir
  `/state/tmp` (safety copies and KCC job output).
- `KOMGA_URL=http://komga:25600`, `KOMGA_USER`/`KOMGA_PASS` from `.env`
  (same as the bridge), `MANGA_LIBRARY_ID` (Komga library to scan),
  `INTERVAL=300`, `STABLE_SECONDS=600`, `WORKERS=4`.

**Loop (every `INTERVAL` seconds).**
1. Walk `/manga` for `*.cbz`, skipping names ending in `.kcc-tmp`.
2. Candidate filter — skip a file when any of these hold:
   - modified less than `STABLE_SECONDS` ago (Suwayomi may still be writing);
   - `state.json` records it as converted with the same size and mtime;
   - it already contains KCC page names (`kcc-*`) → record in state, skip;
   - it has failed 3 times → skip (logged once when it reaches 3).
3. Order candidates newest-mtime first, so new chapters jump the backlog.
4. Convert with a pool of `WORKERS` processes, each running KCC under
   `nice -n 19`.
5. If any file was replaced this pass, `POST /api/v1/libraries/{id}/scan`.

`converter.py --once --path <file>` converts a single file through the same
code path and exits (used for rollout step 1 and debugging).

**Converting one file.**
1. Record source page count (image entries in the zip) and stat
   (uid, gid, mode).
2. Copy the original to `/state/tmp/<hash>.cbz` (the safety copy).
3. Run KCC on the safety copy, output into a per-job dir under `/state/tmp`.
4. Validate the output: the zip opens; image entry count equals the source
   count; `ComicInfo.xml` is present if the source had one.
5. Copy the output next to the original as `<name>.kcc-tmp`, apply the
   original's uid/gid/mode, then `os.replace` it over the original (atomic
   within the directory, same filename).
6. Record `{path: {size, mtime, settings: "kcc-f127adb-go103-v1", at}}` in
   `state.json` (written atomically via temp + rename).
7. Delete the safety copy and job dir.

**Failure handling.** Any failure in steps 3–5: remove `.kcc-tmp` and the job
dir, leave the original untouched (it was never moved), increment the file's
failure count in state, log the KCC stderr tail. If the process dies between
`os.replace` and the state write, the next pass sees `kcc-*` page names and
records it — no double conversion. Stray `.kcc-tmp` files and `/state/tmp`
leftovers are cleaned at startup. A Komga scan failure is logged and retried
next pass.

The original is copied rather than moved, so there is never a moment when
Komga or Suwayomi sees the path missing.

## Component 2: Maki change detection

All changes in `maki.koplugin`.

1. **Parser.** Capture each OPDS entry's `<updated>` into the item table
   (`item.updated`, raw string).
2. **Timestamp parsing.** New pure helper converting ISO-8601 with offset
   (`2026-05-14T03:40:29.471+01:00`, also `Z`) to a UTC epoch number.
   Unparseable → `nil` (treated as "no change info").
3. **Ledger.** `fetched[url] = {file, at, updated}` where `updated` is the
   server epoch at the time of download. `Marker.markFetched` gains an update
   path (currently it never overwrites an entry) used only after a successful
   replacement.
4. **Planning.** `collect_entries` passes `updated` through. `planSeries`, for
   a URL already in the ledger whose file exists locally, plans a **replace**
   when `server_updated > (rec.updated or rec.at)`. Legacy entries have no
   `updated`, so their download time `at` is used; every chapter converted
   after it was downloaded therefore gets refreshed once, with no migration
   step.
5. **Replace.** Download to `<path>.part` as today, then rename over the
   existing file. The `.sdr` sidecar is left alone (page counts are unchanged,
   so progress stays valid). Update the ledger entry's `at` and `updated`.
6. **Open document.** A replace is skipped for the document currently open in
   the reader (passed in via `deps`), and retried next sync.
7. **Caps.** Replacements count against the existing per-run download cap, so
   the initial refresh spreads across several syncs.

## Rollout

1. Build the image. Convert one chapter manually with the container's
   converter (`--once --path <file>`).
2. Verify in Komga: book ID unchanged, `<updated>` in the OPDS feed is newer,
   page count unchanged, metadata (number/title) intact.
3. Trigger a library scan with no file changes and verify `<updated>` does
   **not** change for untouched books. If it does, stop: the change signal
   needs revisiting before the Maki change ships.
4. Deploy Maki to the Boox; run a sync of that one series and confirm only
   the converted chapter is re-downloaded.
5. Start the container for the backfill. Watch the first pass; spot-check a
   few series on the device.

## Testing

- **Converter:** Python `unittest` in `~/manga-stack/kcc/test_converter.py`,
  run like the bridge tests. Pure logic: stability check, already-converted
  detection (state + `kcc-` names), candidate ordering, output validation
  (page count, ComicInfo), failure counting. One integration test converts a
  small fixture CBZ inside the image.
- **Maki:** plain-Lua test scripts in `maki.koplugin/tests/` (repo style:
  `lua tests/_test_*.lua`). Cases: ISO-8601 parsing (offsets, `Z`, fractional
  seconds, garbage); `planSeries` plans a replace when server is newer than
  `updated`, and when newer than `at` for a legacy entry; no replace when equal
  or older; no replace for the open document; replace respects the cap.

## Trade-offs

- Originals are deleted after conversion. Changing KCC settings later cannot
  re-convert from source; chapters would need re-downloading through
  Suwayomi (delete the files and let Suwayomi re-fetch).
- Converted files are larger than the originals (~1.5x).
- If Komga ever bumps `<updated>` for reasons other than file content, the Boox
  re-downloads those chapters unnecessarily. Rollout step 3 checks this.
