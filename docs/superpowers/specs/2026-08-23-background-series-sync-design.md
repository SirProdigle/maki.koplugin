# Maki background series sync — design

Date: 2026-08-23

## Problem

Maki's auto-sync walks the entire OPDS catalog (every library → series →
chapter) with synchronous HTTP on KOReader's UI thread, and in auto mode it
never yields. On Kindle that is a freeze; on Android (Boox Go 10.3) the
5-second input watchdog kills KOReader with an ANR. It also re-queues every
file that is not on disk, so deleting read chapters causes them to be
re-downloaded.

## Goals

1. Auto-sync is O(followed series), not O(catalog).
2. Auto-sync never blocks the UI; the device stays usable while it runs.
3. Deleting a downloaded chapter is permanent for auto-sync ("I'm done with
   it"); a manual *Download all here* on the series re-fetches.
4. Existing triggers (network connected, resume, periodic) stay, capped to
   one successful run per `sync_interval_hours` (default 24), with the existing
   manual "Sync all catalogs" / per-catalog "Sync" entries as override.
5. Silent while running; one non-blocking notification at the end, only if
   something was downloaded.

Non-goals: removing chapters the server dropped; following series that have
never been long-pressed (see seed tool for migration); multi-server merging of
one folder.

## 1. Per-series marker `<sync_dir>/<series>/.maki.lua`

A `LuaSettings` file written by *Download all here* and by the seed tool:

```lua
return {
  catalog = "https://komga.bussybox.live/opds/v1.2/catalog", -- server.url it belongs to
  feed    = "https://komga.bussybox.live/opds/v1.2/series/0QC…", -- the series' own feed
  title   = "JoJo's Bizarre Adventure - Part 6 - Stone Ocean",
  fetched = { ["Official_Chapter 61.cbz"] = 1787496400, … },   -- filename → os.time()
}
```

- `fetched` is keyed by the on-disk filename Maki derives for the entry
  (`getServerFileName` + `util.getSafeFilename`), i.e. the same string used
  for the existence check.
- Folders without a marker are invisible to auto-sync.
- Markers are only rewritten when their content changed.

## 2. Sync algorithm (`makisync.lua`)

Runs inside the child process.

```
for each server in servers where server.sync and (server.sync_dir or global sync_dir):
  for each dir in <sync_dir>/* with a .maki.lua whose catalog == server.url:
    entries = fetch marker.feed, following rel=next
    plan    = planSeries(entries, dir, marker)      -- pure
    for each item in plan (stop when total downloads >= sync_max_dl):
      download to <dir>/<fname>.part, rename to <fname> on success
      on success: marker.fetched[fname] = now
      on failure: count; abort whole run after SYNC_ABORT_AFTER_CONSECUTIVE_FAILURES
    write marker if changed
return { series = {{title, downloaded, failed}, …}, downloaded, failed, aborted, reason }
```

`planSeries(entries, dir, marker)` returns the acquisition entries whose
derived filename is (a) not on disk and (b) not in `marker.fetched`. That one
rule covers new chapters, gaps that became available, and never re-fetching
deleted chapters. Leftover `*.part` files are treated as absent and
overwritten.

Manual *Download all here* uses the same downloader but **ignores
`fetched`** (only skips files on disk) and writes/updates the marker with the
series feed URL and everything it downloaded.

The persisted `pending_syncs` queue, `fillPendingSyncs`, `prunePendingSyncs`,
`downloadPendingSyncs`, and `checkSyncDownload` are removed. `walkFeedForBulk`
stays for *Download all here*.

## 3. Gate, cap, override (`main.lua`)

```
performAutoSync():
  if self.sync_pid                        → skip ("already running")
  if not NetworkMgr:isOnline()            → skip
  if not syncHostsResolve()               → existing DNS retry chain, unchanged
  if now - last_success < interval_hours*3600 → skip ("too recent")
  launchSync{ manual = false }
```

- `last_success` (settings) is stamped only when a run finishes without
  `aborted`, including zero-download runs. Aborted runs do not consume the
  day, so the next trigger retries.
- Manual sync ("Sync all catalogs" in the Maki settings menu, or a catalog's "Sync" button) calls `launchSync{ manual = true }`:
  bypasses the cap, shows the live progress widget. If a run is active it
  shows "Sync already running".
- Triggers and their debounce/DNS logic are unchanged.
- *Download all here* during a background run is allowed; marker writes are
  additive so last-wins is harmless.

## 4. Background execution (`main.lua` + `makisync.lua`)

- `launchSync` forks via `ffiutil.runInSubProcess(task, true)` → `(pid, fd)`.
  The child calls `makisync.runSync(servers, settings)` and writes the result
  table to the pipe with `ffiutil.writeToFD(fd, dump(result))`, mirroring
  `BookInfoManager`.
- Parent polls every 2 s with `UIManager:scheduleIn(2, self.sync_poll_task)`:
  when `ffiutil.isSubProcessDone(pid)`, read the pipe, `loadstring` the
  result, clear `sync_pid`, stamp `last_success` if not aborted, then:
  - `downloaded > 0` → `Notification` "Maki: N new chapter(s) in M series",
    then broadcast the file-manager refresh event used by bussysync so the
    shelf updates.
  - `downloaded == 0` → nothing.
  - `aborted` → `logger.warn` only.
- Manual run: child additionally writes `<sync_dir>/.maki-progress`
  (`series_index, series_total, series_title, downloaded`) after each file;
  the poller reads it and updates `Trapper:info`-style progress via an
  `InfoMessage` with tap-to-cancel. Cancel →
  `ffiutil.terminateSubProcess(pid)`; completed files and marker updates
  survive; the `.part` in flight is deleted on next run.
- `onCloseWidget` / `onSuspend`: terminate a live child.

## 5. Code organisation

| file | role |
|---|---|
| `makimarker.lua` (new, pure) | `read(dir)`, `write(dir, marker)`, `listFollowed(sync_dir, catalog_url)`, `markFetched(marker, fname, now)` |
| `makisync.lua` (new) | `planSeries(entries, dir, marker)` (pure), `runSync(servers, settings, deps)` — `deps` injects `fetchFeed`, `download`, `lfs`, `now` for tests |
| `main.lua` | gate (§3), `launchSync`, poller, notification (§4) |
| `makibrowser.lua` | `downloadAllHere` writes marker; sync-queue code removed; "Sync all catalogs" / per-catalog "Sync" call `launchSync{manual=true}` (per-catalog passes the server index) |
| `tools/seed_markers.lua` (new, one-off) | see below |

### Seed tool

For folders created before markers existed. Run once with KOReader's Lua on
the device (or desktop KOReader with the same `maki.lua`):

1. For each sync server, fetch root → libraries → series level only (paged).
2. Sanitise each series title with `sanitize_segment`; match against
   directories in `<sync_dir>/*` that lack a marker.
3. For matches, write a marker with the series feed URL and
   `fetched = every file currently in the folder`.
4. Print matched / unmatched so stragglers can be long-pressed manually.

## Testing

Pure-Lua tests in `tests/_test_*.lua`, stub-based, same style as
tana.koplugin (`lua tests/_test_makisync.lua`):

- marker round-trip; `listFollowed` ignores dirs without markers and markers
  for another catalog.
- `planSeries`: new chapter; gap; chapter on disk; chapter deleted but in
  `fetched` (skipped); `.part` leftover (re-fetched); `sync_max_dl` cap.
- `runSync` with stubbed `fetchFeed`/`download`: consecutive-failure abort,
  marker written only on change, `.part` → rename.
- gate: fake clock — "too recent" skip, aborted run does not stamp
  `last_success`, manual bypasses.

Subprocess/pipe plumbing is verified by a smoke test on the Boox: enable
auto-sync, toggle Wi-Fi, confirm no ANR in logcat and the notification
appears; then on the Kindle.

## Rollout

1. Land Maki changes; run seed tool on Kindle and Boox.
2. Re-enable `auto_sync`, `sync_on_network`, `sync_on_resume` in the Boox's
   `maki.lua`.
