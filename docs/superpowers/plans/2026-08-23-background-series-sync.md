# Maki Background Series Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use claude-superpowers:subagent-driven-development (recommended) or claude-superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Maki's blocking whole-catalog auto-sync with a per-series, ledger-driven sync that runs in a forked subprocess and never blocks KOReader's UI.

**Architecture:** Each followed series folder carries a `.maki.lua` marker (series feed URL + ledger of fetched acquisition URLs). A new pure module `makisync.lua` plans and performs the sync given injected I/O deps; `main.lua` forks it via `ffiutil.runInSubProcess` and polls for completion, showing a Notification at the end. `makibrowser.lua` loses its persisted `pending_syncs` queue; *Download all here* writes markers.

**Tech Stack:** Lua 5.1/LuaJIT (KOReader plugin), KOReader `ffi/util` subprocess API, `dump` serialiser, plain-`lua` stub-based tests (`lua tests/_test_*.lua`).

**Code Areas:** sync-core, plugin-shell

**Global Constraints:**
- Spec: `docs/superpowers/specs/2026-08-23-background-series-sync-design.md` — binding.
- Nothing that runs inside the forked child may call `UIManager:show` or touch widgets. The child may only do I/O and write to its pipe fd.
- `fetched` ledger is keyed by acquisition URL; value is `{ file = <string|nil>, at = <os.time()> }`.
- Marker filename is exactly `.maki.lua` inside the series folder.
- `settings.last_sync_time` is the "last successful run" stamp; it is written only when a run finishes with `aborted == false`.
- No new dependencies beyond what KOReader ships. No `busted`; tests are `lua tests/_test_<module>.lua` and exit non-zero on failure.
- Repo root for all paths below is `~/projects/maki.koplugin`; plugin code lives in `maki.koplugin/`. Run tests from inside `maki.koplugin/` (`cd maki.koplugin && lua tests/_test_makisync.lua`).
- Commit after every task with a conventional message (`feat:`, `refactor:`, `test:`, `tools:`).

**User decisions (already made):**
- Deleting a downloaded chapter is permanent for auto-sync (ledger remembers); manual *Download all here* is the re-fetch escape hatch and ignores the ledger.
- Series are followed via a per-folder marker file, not by name-matching a catalog walk.
- Silent while running; one non-blocking Notification at the end only if something was downloaded.
- Keep the three triggers (network, resume, periodic) but cap to one successful run per `sync_interval_hours` (default 24); manual sync bypasses the cap and shows live progress.
- Background execution via forked subprocess (not a yielding coroutine).
- Write a one-off seed tool for pre-existing folders.
- Ledger keyed by acquisition URL to avoid per-chapter HEAD requests; seed tool writes a baseline (every entry on the feed marked fetched, no HEADs).

---

## File Structure

| File | Responsibility |
|---|---|
| `maki.koplugin/makimarker.lua` (new) | Read/write `.maki.lua`, list followed series dirs. Pure; deps injected. |
| `maki.koplugin/makisync.lua` (new) | `planSeries`, `runSync`, `shouldAutoSync`, `summarize`. Pure; deps injected. |
| `maki.koplugin/main.lua` (modify) | Gate, `launchSync` (fork + poll), manual progress widget, Notification, cancel. |
| `maki.koplugin/makibrowser.lua` (modify) | `walkFeedForBulk` records the series feed root; `runBulkDownload` writes markers; sync buttons call `launchSync`; old queue code removed. |
| `maki.koplugin/tools/seed_markers.lua` (new) | One-off: name-match existing folders to series, write baseline markers. |
| `maki.koplugin/tests/_test_makimarker.lua`, `tests/_test_makisync.lua` (new) | Stub-based unit tests. |

---

### Task 1: `makimarker.lua` — marker read/write/list

**Goal:** A pure module that reads and atomically writes `.maki.lua` markers and lists followed series folders for a catalog.

**Files:**
- Create: `maki.koplugin/makimarker.lua`
- Test: `maki.koplugin/tests/_test_makimarker.lua`

**Acceptance Criteria:**
- [ ] `Marker.read(dir, deps)` returns the table from `<dir>/.maki.lua`, or `nil` if absent/unparseable; `fetched` is always a table.
- [ ] `Marker.write(dir, marker, deps)` writes `<dir>/.maki.lua.tmp` then renames to `<dir>/.maki.lua`; returns `true` or `false, err`.
- [ ] `Marker.listFollowed(sync_dir, catalog_url, deps)` returns `{ {dir=..., marker=...}, ... }` for every immediate subdirectory with a marker whose `catalog == catalog_url`, sorted by dir; ignores dirs with no marker or another catalog.
- [ ] `Marker.markFetched(marker, url, file, now)` sets `marker.fetched[url] = {file=file, at=now}` and returns `true` if that changed the marker (new key), `false` if already present.

**Verify:** `cd maki.koplugin && lua tests/_test_makimarker.lua` → `N/N tests passed`, exit 0

**Steps:**

- [ ] **Step 1: Write the failing tests**

`maki.koplugin/tests/_test_makimarker.lua`:

```lua
-- tests/_test_makimarker.lua
-- Pure-Lua tests for makimarker.lua using an in-memory filesystem.
-- Usage: cd maki.koplugin && lua tests/_test_makimarker.lua

package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

-- Minimal serializer standing in for KOReader's `dump`.
local function dump(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local out = { "{\n" }
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local ks = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        out[#out + 1] = indent .. "    " .. ks .. " = " .. dump(v[k], indent .. "    ") .. ",\n"
    end
    out[#out + 1] = indent .. "}"
    return table.concat(out)
end
package.loaded["dump"] = dump

local M = dofile("makimarker.lua")

-- In-memory FS: files[path] = content; dirs[path] = { child names }
local files, dirs
local function deps()
    return {
        readFile = function(path) return files[path] end,
        writeFile = function(path, content) files[path] = content; return true end,
        rename = function(from, to)
            if files[from] == nil then return nil, "no such file" end
            files[to] = files[from]; files[from] = nil; return true
        end,
        listDirs = function(path) return dirs[path] or {} end,
    }
end

local pass, fail = 0, 0
local function test(name, fn)
    files, dirs = {}, {}
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

test("read: returns nil when marker missing", function()
    assert(M.read("/m/S", deps()) == nil)
end)

test("read: parses marker and guarantees fetched table", function()
    files["/m/S/.maki.lua"] = 'return { catalog = "C", feed = "F", title = "S" }'
    local mk = M.read("/m/S", deps())
    assert(mk.catalog == "C" and mk.feed == "F" and mk.title == "S")
    assert(type(mk.fetched) == "table")
end)

test("read: returns nil on unparseable content", function()
    files["/m/S/.maki.lua"] = "return {{{"
    assert(M.read("/m/S", deps()) == nil)
end)

test("write: writes tmp then renames; round-trips", function()
    local d = deps()
    local mk = { catalog = "C", feed = "F", title = "S",
                 fetched = { ["http://x/1"] = { file = "a.cbz", at = 5 } } }
    assert(M.write("/m/S", mk, d) == true)
    assert(files["/m/S/.maki.lua.tmp"] == nil)
    local back = M.read("/m/S", d)
    assert(back.fetched["http://x/1"].file == "a.cbz")
    assert(back.fetched["http://x/1"].at == 5)
end)

test("write: returns false,err when rename fails", function()
    local d = deps()
    d.rename = function() return nil, "EACCES" end
    local ok, err = M.write("/m/S", { catalog = "C", fetched = {} }, d)
    assert(ok == false and err == "EACCES")
end)

test("listFollowed: only dirs with a marker for this catalog, sorted", function()
    dirs["/m"] = { "Zeta", "Alpha", "NoMarker", "Other" }
    files["/m/Zeta/.maki.lua"]  = 'return { catalog = "C", feed = "fz" }'
    files["/m/Alpha/.maki.lua"] = 'return { catalog = "C", feed = "fa" }'
    files["/m/Other/.maki.lua"] = 'return { catalog = "D", feed = "fo" }'
    local list = M.listFollowed("/m", "C", deps())
    assert(#list == 2, "got " .. #list)
    assert(list[1].dir == "/m/Alpha" and list[1].marker.feed == "fa")
    assert(list[2].dir == "/m/Zeta")
end)

test("listFollowed: trailing slash on sync_dir is tolerated", function()
    dirs["/m"] = { "A" }
    files["/m/A/.maki.lua"] = 'return { catalog = "C", feed = "f" }'
    local list = M.listFollowed("/m/", "C", deps())
    assert(#list == 1 and list[1].dir == "/m/A")
end)

test("markFetched: adds entry and reports change; repeat is no change", function()
    local mk = { fetched = {} }
    assert(M.markFetched(mk, "u", "f.cbz", 9) == true)
    assert(mk.fetched.u.file == "f.cbz" and mk.fetched.u.at == 9)
    assert(M.markFetched(mk, "u", "f.cbz", 10) == false)
    assert(mk.fetched.u.at == 9, "existing entry must not be overwritten")
end)

print(string.format("%d/%d tests passed", pass, pass + fail))
if fail > 0 then os.exit(1) end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd maki.koplugin && lua tests/_test_makimarker.lua`
Expected: error `cannot open makimarker.lua` (dofile fails) — non-zero exit.

- [ ] **Step 3: Implement `makimarker.lua`**

```lua
-- makimarker.lua
-- Per-series marker file `<series_dir>/.maki.lua`:
--   { catalog = <server.url>, feed = <series feed URL>, title = <string>,
--     fetched = { [acquisition_url] = { file = <string|nil>, at = <os.time()> } } }
-- Pure module: all filesystem access goes through `deps` so it can run in
-- tests and inside a forked child alike. Default deps use io/lfs.

local dump = require("dump")
local logger = require("logger")

local M = {}

M.FILENAME = ".maki.lua"

local function default_deps()
    local lfs = require("libs/libkoreader-lfs")
    return {
        readFile = function(path)
            local f = io.open(path, "r")
            if not f then return nil end
            local s = f:read("*a"); f:close(); return s
        end,
        writeFile = function(path, content)
            local f, err = io.open(path, "w")
            if not f then return nil, err end
            f:write(content); f:close(); return true
        end,
        rename = function(from, to) return os.rename(from, to) end,
        listDirs = function(path)
            local out = {}
            local ok, iter, dir_obj = pcall(lfs.dir, path)
            if not ok then return out end
            for name in iter, dir_obj do
                if name ~= "." and name ~= ".." then
                    local attr = lfs.attributes(path .. "/" .. name)
                    if attr and attr.mode == "directory" then out[#out + 1] = name end
                end
            end
            return out
        end,
    }
end

local function with_deps(deps)
    if deps then return deps end
    M._default = M._default or default_deps()
    return M._default
end

local function strip_slash(p) return (p:gsub("/+$", "")) end

function M.path(dir) return strip_slash(dir) .. "/" .. M.FILENAME end

function M.read(dir, deps)
    deps = with_deps(deps)
    local src = deps.readFile(M.path(dir))
    if not src then return nil end
    local chunk = loadstring and loadstring(src) or load(src)
    if not chunk then
        logger.warn("Maki: unparseable marker in", dir)
        return nil
    end
    local ok, tbl = pcall(chunk)
    if not ok or type(tbl) ~= "table" then
        logger.warn("Maki: unparseable marker in", dir)
        return nil
    end
    if type(tbl.fetched) ~= "table" then tbl.fetched = {} end
    return tbl
end

function M.write(dir, marker, deps)
    deps = with_deps(deps)
    local final = M.path(dir)
    local tmp = final .. ".tmp"
    local ok, err = deps.writeFile(tmp, "return " .. dump(marker) .. "\n")
    if not ok then return false, err end
    local rok, rerr = deps.rename(tmp, final)
    if not rok then return false, rerr end
    return true
end

function M.listFollowed(sync_dir, catalog_url, deps)
    deps = with_deps(deps)
    sync_dir = strip_slash(sync_dir)
    local names = deps.listDirs(sync_dir)
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        local dir = sync_dir .. "/" .. name
        local marker = M.read(dir, deps)
        if marker and marker.catalog == catalog_url and marker.feed then
            out[#out + 1] = { dir = dir, marker = marker }
        end
    end
    return out
end

function M.markFetched(marker, url, file, now)
    marker.fetched = marker.fetched or {}
    if marker.fetched[url] then return false end
    marker.fetched[url] = { file = file, at = now }
    return true
end

return M
```

- [ ] **Step 4: Run tests**

Run: `cd maki.koplugin && lua tests/_test_makimarker.lua`
Expected: `8/8 tests passed`

- [ ] **Step 5: Commit**

```bash
git add maki.koplugin/makimarker.lua maki.koplugin/tests/_test_makimarker.lua
git commit -m "feat(sync): per-series .maki.lua marker module"
```

---

### Task 2: `makisync.lua` — `planSeries` and `shouldAutoSync`

**Goal:** Pure planning logic: which entries of a series feed to fetch, and whether an automatic run is due.

**Files:**
- Create: `maki.koplugin/makisync.lua`
- Test: `maki.koplugin/tests/_test_makisync.lua`

**Acceptance Criteria:**
- [ ] `planSeries(entries, dir, marker, deps)` returns `{ to_fetch = {...}, adopted = n, changed = bool }` where each `to_fetch` item is `{ url, file, path, title }`.
- [ ] Entry whose URL is in `marker.fetched` → skipped, no HEAD (`deps.fileName` not called).
- [ ] Entry not in ledger but file on disk → adopted into ledger, not fetched, `changed == true`.
- [ ] Entry not in ledger, `<path>.part` on disk → `.part` removed, entry fetched.
- [ ] Entry not in ledger, nothing on disk → fetched.
- [ ] `deps.fileName` returning nil → entry skipped with a warning (not adopted, not fetched).
- [ ] `shouldAutoSync(settings, now)` returns `false, "too recent"` when `now - last_sync_time < sync_interval_hours*3600`, else `true`. `last_sync_time == nil` → `true`.

**Verify:** `cd maki.koplugin && lua tests/_test_makisync.lua` → all pass, exit 0

**Steps:**

- [ ] **Step 1: Write the failing tests**

`maki.koplugin/tests/_test_makisync.lua`:

```lua
-- tests/_test_makisync.lua
-- Usage: cd maki.koplugin && lua tests/_test_makisync.lua

package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }
package.loaded["dump"] = function(v) -- tiny serializer, enough for markers
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        local ks = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        parts[#parts + 1] = ks .. "=" .. package.loaded["dump"](val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local S = dofile("makisync.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- Build deps over an in-memory disk set and a url→filename map.
local function mkdeps(disk, names, log)
    log = log or {}
    return {
        exists = function(p) return disk[p] == true end,
        remove = function(p) disk[p] = nil; log[#log + 1] = "rm " .. p; return true end,
        fileName = function(url, filetype)
            log[#log + 1] = "head " .. url
            return names[url]
        end,
        now = function() return 100 end,
    }, log
end

local function entry(url, title) return { url = url, title = title or url, filetype = "cbz" } end

-- ─── planSeries ──────────────────────────────────────────────────────────

test("planSeries: url in ledger is skipped without HEAD", function()
    local deps, log = mkdeps({}, {})
    local marker = { fetched = { u1 = { file = "a.cbz", at = 1 } } }
    local plan = S.planSeries({ entry("u1") }, "/m/S", marker, deps)
    assert(#plan.to_fetch == 0 and plan.adopted == 0 and plan.changed == false)
    assert(#log == 0, "no HEAD expected")
end)

test("planSeries: file on disk is adopted, not fetched", function()
    local deps = mkdeps({ ["/m/S/a.cbz"] = true }, { u1 = "a.cbz" })
    local marker = { fetched = {} }
    local plan = S.planSeries({ entry("u1") }, "/m/S", marker, deps)
    assert(#plan.to_fetch == 0 and plan.adopted == 1 and plan.changed == true)
    assert(marker.fetched.u1.file == "a.cbz" and marker.fetched.u1.at == 100)
end)

test("planSeries: missing file is fetched with derived path", function()
    local deps = mkdeps({}, { u1 = "a.cbz" })
    local plan = S.planSeries({ entry("u1", "Chapter 1") }, "/m/S", { fetched = {} }, deps)
    assert(#plan.to_fetch == 1)
    local f = plan.to_fetch[1]
    assert(f.url == "u1" and f.file == "a.cbz" and f.path == "/m/S/a.cbz" and f.title == "Chapter 1")
end)

test("planSeries: leftover .part is removed and entry fetched", function()
    local disk = { ["/m/S/a.cbz.part"] = true }
    local deps, log = mkdeps(disk, { u1 = "a.cbz" })
    local plan = S.planSeries({ entry("u1") }, "/m/S", { fetched = {} }, deps)
    assert(#plan.to_fetch == 1)
    assert(disk["/m/S/a.cbz.part"] == nil)
end)

test("planSeries: fileName nil → entry skipped entirely", function()
    local deps = mkdeps({}, {})
    local marker = { fetched = {} }
    local plan = S.planSeries({ entry("u1") }, "/m/S", marker, deps)
    assert(#plan.to_fetch == 0 and plan.adopted == 0 and plan.changed == false)
    assert(marker.fetched.u1 == nil)
end)

test("planSeries: entries without url are ignored", function()
    local deps = mkdeps({}, {})
    local plan = S.planSeries({ { title = "nav only" } }, "/m/S", { fetched = {} }, deps)
    assert(#plan.to_fetch == 0)
end)

test("planSeries: mixed feed — new, gap, deleted, present", function()
    local disk = { ["/m/S/c3.cbz"] = true }
    local deps, log = mkdeps(disk, { u1 = "c1.cbz", u2 = "c2.cbz", u3 = "c3.cbz", u4 = "c4.cbz" })
    local marker = { fetched = { u1 = { file = "c1.cbz", at = 1 } } } -- c1 deleted on purpose
    local plan = S.planSeries({ entry("u1"), entry("u2"), entry("u3"), entry("u4") }, "/m/S", marker, deps)
    local urls = {}
    for _, f in ipairs(plan.to_fetch) do urls[#urls + 1] = f.url end
    assert(table.concat(urls, ",") == "u2,u4", table.concat(urls, ","))
    assert(plan.adopted == 1)
    assert(#log == 3, "HEAD only for u2,u3,u4; got " .. #log)
end)

-- ─── shouldAutoSync ──────────────────────────────────────────────────────

test("shouldAutoSync: never synced → true", function()
    assert(S.shouldAutoSync({ sync_interval_hours = 24 }, 1000) == true)
end)

test("shouldAutoSync: within interval → false, too recent", function()
    local ok, why = S.shouldAutoSync({ sync_interval_hours = 24, last_sync_time = 1000 }, 1000 + 3600)
    assert(ok == false and why == "too recent")
end)

test("shouldAutoSync: past interval → true", function()
    assert(S.shouldAutoSync({ sync_interval_hours = 24, last_sync_time = 1000 }, 1000 + 24 * 3600) == true)
end)

test("shouldAutoSync: missing interval defaults to 24h", function()
    local ok = S.shouldAutoSync({ last_sync_time = 1000 }, 1000 + 23 * 3600)
    assert(ok == false)
end)

print(string.format("%d/%d tests passed", pass, pass + fail))
if fail > 0 then os.exit(1) end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd maki.koplugin && lua tests/_test_makisync.lua`
Expected: `cannot open makisync.lua` — non-zero exit.

- [ ] **Step 3: Implement `makisync.lua` (planning half)**

```lua
-- makisync.lua
-- Ledger-driven per-series sync. Pure: every side effect goes through
-- `deps`, so the same code runs in unit tests, in the forked child, and in
-- the seed tool.
--
-- deps (all required unless noted):
--   fetchFeed(url)            -> item_table | nil, err   (one page; item_table.hrefs.next for pagination)
--   fileName(url, filetype)   -> filename | nil           (HEAD for Content-Disposition)
--   download(url, path, username, password) -> ok, err
--   exists(path)              -> bool
--   remove(path)              -> ok
--   rename(from, to)          -> ok, err
--   now()                     -> os.time()
--   marker                    -> makimarker deps table (optional; default io)
--   progress(state)           -> nil                     (optional; manual runs only)
--   cancelled()               -> bool                    (optional)

local logger = require("logger")
local Marker = require("makimarker")

local M = {}

M.DEFAULT_INTERVAL_HOURS = 24
M.ABORT_AFTER_CONSECUTIVE_FAILURES = 2

local function strip_slash(p) return (p:gsub("/+$", "")) end

-- Decide what to do for every acquisition entry of one series feed.
function M.planSeries(entries, dir, marker, deps)
    dir = strip_slash(dir)
    marker.fetched = marker.fetched or {}
    local plan = { to_fetch = {}, adopted = 0, changed = false }
    for _, e in ipairs(entries) do
        if e.url then
            if not marker.fetched[e.url] then
                local fname = deps.fileName(e.url, e.filetype)
                if not fname then
                    logger.warn("Maki: could not derive filename for", e.url)
                else
                    local path = dir .. "/" .. fname
                    if deps.exists(path) then
                        Marker.markFetched(marker, e.url, fname, deps.now())
                        plan.adopted = plan.adopted + 1
                        plan.changed = true
                    else
                        if deps.exists(path .. ".part") then deps.remove(path .. ".part") end
                        plan.to_fetch[#plan.to_fetch + 1] = {
                            url = e.url, file = fname, path = path, title = e.title or fname,
                        }
                    end
                end
            end
        end
    end
    return plan
end

-- Cap automatic runs to one successful run per interval.
function M.shouldAutoSync(settings, now)
    local hours = settings.sync_interval_hours or M.DEFAULT_INTERVAL_HOURS
    local last = settings.last_sync_time
    if last and (now - last) < hours * 3600 then
        return false, "too recent"
    end
    return true
end

return M
```

- [ ] **Step 4: Run tests**

Run: `cd maki.koplugin && lua tests/_test_makisync.lua`
Expected: `11/11 tests passed`

- [ ] **Step 5: Commit**

```bash
git add maki.koplugin/makisync.lua maki.koplugin/tests/_test_makisync.lua
git commit -m "feat(sync): planSeries + shouldAutoSync (pure)"
```

---

### Task 3: `makisync.runSync` — fetch feeds, download, update markers

**Goal:** The child-process entry point: iterate followed series per server, plan, download to `.part` then rename, record the ledger, honour caps/abort/cancel, and return a result table.

**Files:**
- Modify: `maki.koplugin/makisync.lua`
- Test: `maki.koplugin/tests/_test_makisync.lua` (append)

**Acceptance Criteria:**
- [ ] `runSync(servers, settings, deps, opts)` processes only servers with `sync == true` and a `sync_dir` (server's or `settings.sync_dir`); `opts.server_index` restricts to one server (1-based index into `servers`).
- [ ] Feed pagination: follows `item_table.hrefs.next` until nil; entries are those with `acquisitions[1]` — URL = first acquisition with a supported filetype (`OPDSBrowser.getFiletype` semantics are injected as `deps.filetype(acq)`; an acquisition with `type == "borrow"` is ignored).
- [ ] Download goes to `<path>.part`, renamed to `<path>` on success; ledger updated only on success; marker written once per series and only if `changed`.
- [ ] Stops after `settings.sync_max_dl` (default 50) downloads across the whole run; sets `result.capped = true`.
- [ ] Aborts the whole run after `ABORT_AFTER_CONSECUTIVE_FAILURES` consecutive download failures with `result.aborted = true, result.reason = <err>`; partial ledger progress is still written.
- [ ] A feed fetch failure for one series marks that series `failed` and continues with the next; it does not abort the run. If *every* series' feed fails, `result.aborted = true`.
- [ ] `opts.ignore_ledger == true` (manual "Force sync") treats the ledger as empty for planning (files on disk are still adopted/skipped).
- [ ] Result shape: `{ series = { {title, dir, downloaded, failed, adopted, feed_failed} ... }, downloaded, failed, adopted, aborted, reason, capped }`.
- [ ] `deps.progress` (if given) is called after each download with `{ series_index, series_total, title, downloaded, total_planned }`; `deps.cancelled()` (if given) is checked before each download and ends the run with `result.cancelled = true`.

**Verify:** `cd maki.koplugin && lua tests/_test_makisync.lua` → all pass

**Steps:**

- [ ] **Step 1: Append failing tests**

Append to `maki.koplugin/tests/_test_makisync.lua` **above** the final summary block:

```lua
-- ─── runSync ─────────────────────────────────────────────────────────────

-- Full fake world: markers in memory (via makimarker deps), feeds keyed by URL,
-- downloads succeed unless listed in `fail_urls`.
local function world(opts)
    opts = opts or {}
    local files, dirs = {}, {}
    local markers = {}   -- dir -> marker source
    local feeds = opts.feeds or {}
    local names = opts.names or {}
    local fail_urls = opts.fail_urls or {}
    local log = {}
    local marker_deps = {
        readFile = function(p) return markers[p] end,
        writeFile = function(p, c) markers[p] = c; log[#log + 1] = "mwrite " .. p; return true end,
        rename = function(a, b) markers[b] = markers[a]; markers[a] = nil; return true end,
        listDirs = function(p) return dirs[p] or {} end,
    }
    local deps = {
        marker = marker_deps,
        fetchFeed = function(url)
            log[#log + 1] = "feed " .. url
            local f = feeds[url]
            if not f then return nil, "404" end
            return f
        end,
        fileName = function(url) return names[url] end,
        filetype = function(acq) return acq.type ~= "borrow" and "cbz" or nil end,
        download = function(url, path)
            log[#log + 1] = "dl " .. url
            if fail_urls[url] then return false, "http 500" end
            files[path] = true; return true
        end,
        exists = function(p) return files[p] == true end,
        remove = function(p) files[p] = nil; return true end,
        rename = function(a, b) files[b] = files[a]; files[a] = nil; return true end,
        now = function() return 500 end,
    }
    local function seed_marker(dir, catalog, feed, fetched)
        markers[dir .. "/.maki.lua"] = "return " .. package.loaded["dump"]({
            catalog = catalog, feed = feed, title = dir:match("[^/]+$"), fetched = fetched or {} })
    end
    return { files = files, dirs = dirs, markers = markers, deps = deps, log = log, seed = seed_marker }
end

local function acq(url) return { url = url, acquisitions = { { href = url, type = "application/zip" } }, title = url } end
local function page(entries, next_url) local t = entries; t.hrefs = { next = next_url }; return t end

local SERVERS = { { title = "K", url = "C", sync = true, sync_dir = "/m", username = "u", password = "p" } }

test("runSync: downloads new chapters, writes ledger, renames .part", function()
    local w = world({ feeds = { fs = page({ acq("u1"), acq("u2") }) }, names = { u1 = "c1.cbz", u2 = "c2.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(SERVERS, { sync_max_dl = 50 }, w.deps, {})
    assert(r.downloaded == 2 and r.failed == 0 and r.aborted == false, "r=" .. tostring(r.downloaded))
    assert(w.files["/m/S/c1.cbz"] and w.files["/m/S/c2.cbz"])
    assert(w.files["/m/S/c1.cbz.part"] == nil)
    local mk = dofile_string(w.markers["/m/S/.maki.lua"])
    assert(mk.fetched.u1.file == "c1.cbz" and mk.fetched.u2.at == 500)
    assert(r.series[1].title == "S" and r.series[1].downloaded == 2)
end)

test("runSync: follows pagination", function()
    local w = world({ feeds = { fs = page({ acq("u1") }, "fs2"), fs2 = page({ acq("u2") }) },
                      names = { u1 = "c1.cbz", u2 = "c2.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 2)
end)

test("runSync: ledger entries are skipped; nothing written when unchanged", function()
    local w = world({ feeds = { fs = page({ acq("u1") }) }, names = { u1 = "c1.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs", { u1 = { file = "c1.cbz", at = 1 } })
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 0)
    for _, l in ipairs(w.log) do assert(not l:match("^mwrite"), "marker must not be rewritten") end
end)

test("runSync: ignore_ledger re-fetches deleted chapters", function()
    local w = world({ feeds = { fs = page({ acq("u1") }) }, names = { u1 = "c1.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs", { u1 = { file = "c1.cbz", at = 1 } })
    local r = S.runSync(SERVERS, {}, w.deps, { ignore_ledger = true })
    assert(r.downloaded == 1 and w.files["/m/S/c1.cbz"])
end)

test("runSync: sync_max_dl caps the run", function()
    local w = world({ feeds = { fs = page({ acq("u1"), acq("u2"), acq("u3") }) },
                      names = { u1 = "1.cbz", u2 = "2.cbz", u3 = "3.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(SERVERS, { sync_max_dl = 2 }, w.deps, {})
    assert(r.downloaded == 2 and r.capped == true)
end)

test("runSync: consecutive failures abort, ledger progress kept", function()
    local w = world({ feeds = { fs = page({ acq("u1"), acq("u2"), acq("u3"), acq("u4") }) },
                      names = { u1 = "1.cbz", u2 = "2.cbz", u3 = "3.cbz", u4 = "4.cbz" },
                      fail_urls = { u2 = true, u3 = true } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1 and r.failed == 2 and r.aborted == true and r.reason == "http 500")
    local mk = dofile_string(w.markers["/m/S/.maki.lua"])
    assert(mk.fetched.u1 and not mk.fetched.u2)
    local dls = 0; for _, l in ipairs(w.log) do if l:match("^dl") then dls = dls + 1 end end
    assert(dls == 3, "u4 must not be attempted")
end)

test("runSync: one feed failing does not abort others; all failing aborts", function()
    local w = world({ feeds = { fb = page({ acq("u1") }) }, names = { u1 = "1.cbz" } })
    w.dirs["/m"] = { "A", "B" }; w.seed("/m/A", "C", "fa"); w.seed("/m/B", "C", "fb")
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1 and r.aborted == false)
    assert(r.series[1].feed_failed == true and r.series[2].downloaded == 1)
    local w2 = world({})
    w2.dirs["/m"] = { "A" }; w2.seed("/m/A", "C", "fa")
    local r2 = S.runSync(SERVERS, {}, w2.deps, {})
    assert(r2.aborted == true)
end)

test("runSync: server_index restricts to one server; unsynced servers ignored", function()
    local servers = {
        { title = "X", url = "CX", sync = false, sync_dir = "/x" },
        { title = "K", url = "C", sync = true, sync_dir = "/m" },
    }
    local w = world({ feeds = { fs = page({ acq("u1") }) }, names = { u1 = "1.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local r = S.runSync(servers, {}, w.deps, { server_index = 2 })
    assert(r.downloaded == 1)
    local r0 = S.runSync(servers, {}, w.deps, { server_index = 1 })
    assert(r0.downloaded == 0 and r0.aborted == false)
end)

test("runSync: progress callback and cancel", function()
    local w = world({ feeds = { fs = page({ acq("u1"), acq("u2") }) }, names = { u1 = "1.cbz", u2 = "2.cbz" } })
    w.dirs["/m"] = { "S" }; w.seed("/m/S", "C", "fs")
    local seen = {}
    w.deps.progress = function(st) seen[#seen + 1] = st.downloaded end
    local calls = 0
    w.deps.cancelled = function() calls = calls + 1; return calls > 1 end
    local r = S.runSync(SERVERS, {}, w.deps, {})
    assert(r.downloaded == 1 and r.cancelled == true)
    assert(seen[1] == 1)
end)
```

Also add this helper near the top of the test file (after `local S = dofile(...)`):

```lua
local function dofile_string(src) return assert(loadstring and loadstring(src) or load(src))() end
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `cd maki.koplugin && lua tests/_test_makisync.lua`
Expected: FAIL lines for every `runSync:` test (`attempt to call field 'runSync'`).

- [ ] **Step 3: Implement `runSync` in `makisync.lua`**

Add before `return M`:

```lua
-- Collect acquisition entries from a feed, following rel=next.
local function collect_entries(feed_url, deps)
    local entries, url, pages = {}, feed_url, 0
    while url and pages < 200 do
        pages = pages + 1
        local tbl, err = deps.fetchFeed(url)
        if not tbl then return nil, err or "feed fetch failed" end
        for _, item in ipairs(tbl) do
            if item.acquisitions and item.acquisitions[1] then
                for _, a in ipairs(item.acquisitions) do
                    if a.href and a.type ~= "borrow" then
                        local ft = deps.filetype(a)
                        if ft then
                            entries[#entries + 1] = { url = a.href, title = item.title or item.text, filetype = ft }
                            break
                        end
                    end
                end
            end
        end
        url = tbl.hrefs and tbl.hrefs.next or nil
    end
    return entries
end

local function sync_one_series(server, followed, settings, deps, opts, result, state)
    local marker, dir = followed.marker, followed.dir
    local rec = { title = marker.title or dir:match("[^/]+$"), dir = dir,
                  downloaded = 0, failed = 0, adopted = 0, feed_failed = false }
    result.series[#result.series + 1] = rec

    local entries, err = collect_entries(marker.feed, deps)
    if not entries then
        logger.warn("Maki: feed failed for", rec.title, err)
        rec.feed_failed = true
        return
    end
    state.feeds_ok = state.feeds_ok + 1

    local plan_marker = marker
    if opts.ignore_ledger then
        plan_marker = { fetched = {} }
    end
    local plan = M.planSeries(entries, dir, plan_marker, deps)
    if opts.ignore_ledger then
        -- adoptions discovered against the empty ledger still belong in the real one
        for url, rec_ in pairs(plan_marker.fetched) do
            if Marker.markFetched(marker, url, rec_.file, rec_.at) then plan.changed = true end
        end
    end
    rec.adopted = plan.adopted
    result.adopted = result.adopted + plan.adopted

    for _, item in ipairs(plan.to_fetch) do
        if result.downloaded >= state.max_dl then result.capped = true; break end
        if deps.cancelled and deps.cancelled() then result.cancelled = true; break end
        local tmp = item.path .. ".part"
        local ok, why = deps.download(item.url, tmp, server.username, server.password)
        if ok then
            local rok, rerr = deps.rename(tmp, item.path)
            if not rok then ok, why = false, rerr or "rename failed" end
        end
        if ok then
            if Marker.markFetched(marker, item.url, item.file, deps.now()) then plan.changed = true end
            rec.downloaded = rec.downloaded + 1
            result.downloaded = result.downloaded + 1
            state.consecutive_failures = 0
        else
            deps.remove(tmp)
            rec.failed = rec.failed + 1
            result.failed = result.failed + 1
            state.consecutive_failures = state.consecutive_failures + 1
            result.reason = result.reason or why
            logger.warn("Maki: download failed", item.path, why)
            if state.consecutive_failures >= M.ABORT_AFTER_CONSECUTIVE_FAILURES then
                result.aborted = true
                break
            end
        end
        if deps.progress then
            deps.progress({ series_index = state.series_index, series_total = state.series_total,
                            title = rec.title, downloaded = result.downloaded, total_planned = #plan.to_fetch })
        end
    end

    if plan.changed then
        local wok, werr = Marker.write(dir, marker, deps.marker)
        if not wok then logger.warn("Maki: marker write failed", dir, werr) end
    end
end

-- Entry point for the forked child (and the seed tool / tests).
-- opts: { server_index = n|nil, ignore_ledger = bool }
function M.runSync(servers, settings, deps, opts)
    opts = opts or {}
    local result = { series = {}, downloaded = 0, failed = 0, adopted = 0,
                     aborted = false, capped = false, cancelled = false, reason = nil }
    local state = { max_dl = settings.sync_max_dl or 50, consecutive_failures = 0,
                    feeds_ok = 0, series_index = 0, series_total = 0 }

    local targets = {}
    for i, srv in ipairs(servers) do
        if (not opts.server_index or opts.server_index == i)
           and srv.sync and (srv.sync_dir or settings.sync_dir) then
            local sync_dir = srv.sync_dir or settings.sync_dir
            for _, f in ipairs(Marker.listFollowed(sync_dir, srv.url, deps.marker)) do
                targets[#targets + 1] = { server = srv, followed = f }
            end
        end
    end
    state.series_total = #targets

    for i, t in ipairs(targets) do
        state.series_index = i
        sync_one_series(t.server, t.followed, settings, deps, opts, result, state)
        if result.aborted or result.cancelled then break end
        if result.capped then break end
    end

    if #targets > 0 and state.feeds_ok == 0 then
        result.aborted = true
        result.reason = result.reason or "all feeds failed"
    end
    return result
end
```

Note for the implementer: `planSeries` must treat `marker.fetched` as already set (Task 2 guarantees this), and the `ignore_ledger` branch passes a throwaway marker so adoptions don't get lost — the loop after it merges them back.

- [ ] **Step 4: Run tests**

Run: `cd maki.koplugin && lua tests/_test_makisync.lua`
Expected: `20/20 tests passed`

- [ ] **Step 5: Commit**

```bash
git add maki.koplugin/makisync.lua maki.koplugin/tests/_test_makisync.lua
git commit -m "feat(sync): runSync — per-series ledger-driven downloads"
```

---

### Task 4: `main.lua` — gate, fork, poll, notify, cancel

**Goal:** Replace `performAutoSync`'s body with the daily-cap gate and a `launchSync` that forks `makisync.runSync`, polls for completion, stamps `last_sync_time`, and shows a Notification / manual progress widget.

**Files:**
- Modify: `maki.koplugin/main.lua` (requires block lines 1-13; `performAutoSync` lines 247-331; `saveSettings` ~333; `onCloseWidget` ~344)

**Acceptance Criteria:**
- [ ] `performAutoSync()` keeps the existing DNS/online/debounce logic but replaces the `time_since_last` check with `makisync.shouldAutoSync(self.settings, os.time())` and replaces the `checkSyncDownload` call with `self:launchSync{ manual = false }`.
- [ ] `launchSync(opts)` returns early with `logger.info` (auto) or an `InfoMessage` "Sync already running" (manual) if `self.sync_pid` is set.
- [ ] The child runs `makisync.runSync(self.servers, self.settings, deps, opts)` and writes `dump(result)` to its pipe fd, then the fd is closed. Nothing in the child touches UI.
- [ ] Parent polls every 2 s; on completion reads the pipe, parses with `loadstring`, clears `sync_pid`, and: if not `aborted` → `settings.last_sync_time = os.time()`, `self.updated = true`, `self:saveSettings()`.
- [ ] Auto run: `downloaded > 0` → `Notification:notify(T("Maki: %1 new chapter(s) in %2 series", n, m))` + file-manager refresh (if `self.ui.file_chooser`); `downloaded == 0` → silent; `aborted` → `logger.warn`.
- [ ] Manual run: an `InfoMessage` with text updated from the progress file every poll; tapping it (`dismiss_callback`) calls `self:cancelSync()`; on completion a summary `InfoMessage` (timeout 6) "Maki: N downloaded, F failed, A adopted".
- [ ] `cancelSync()` calls `ffiutil.terminateSubProcess(self.sync_pid)`; the poller then reaps and reports `cancelled`.
- [ ] `onCloseWidget` and a new `onSuspend` handler terminate a live child.
- [ ] `luacheck maki.koplugin/main.lua` reports no new warnings beyond those pre-existing.

**Verify:** `cd maki.koplugin && lua tests/_test_makisync.lua && lua tests/_test_makimarker.lua && luacheck main.lua --no-color | tail -1` → tests pass; luacheck warning count not higher than on `main` before this task (record it first: `git stash; luacheck main.lua | tail -1; git stash pop`).

**Steps:**

- [ ] **Step 1: Add requires**

At the top of `main.lua`, after `local logger = require("logger")`, add:

```lua
local ffiutil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local dump = require("dump")
local MakiSync = require("makisync")
local lfs = require("libs/libkoreader-lfs")
```

- [ ] **Step 2: Add deps builder**

Add this function anywhere after the `OPDS` table definition (e.g. right before `function OPDS:performAutoSync()`):

```lua
-- Build the I/O dependency table makisync needs. Everything here is safe to
-- call from the forked child: no widgets, no UIManager.
function OPDS:_syncDeps(progress_path)
    local browser = self:_ensureBrowser()
    local deps = {
        fetchFeed = function(url)
            local ok, catalog = pcall(browser.parseFeed, browser, url)
            if not ok or not catalog then return nil, tostring(catalog) end
            return browser:genItemTableFromCatalog(catalog, url)
        end,
        fileName = function(url, filetype)
            local ok, name = pcall(browser.getServerFileName, browser, url, filetype)
            if not ok then return nil end
            return name
        end,
        filetype = function(acq) return OPDSBrowser.getFiletype(acq) end,
        download = function(url, path, username, password)
            util.makePath(path:match("^(.*)/[^/]+$"))
            local ok, why = browser:downloadFile(path, url, username, password, nil, true)
            if ok then return true end
            return false, why or "download failed"
        end,
        exists = function(p) return lfs.attributes(p) ~= nil end,
        remove = function(p) return os.remove(p) end,
        rename = function(a, b) return os.rename(a, b) end,
        now = os.time,
    }
    if progress_path then
        deps.progress = function(st)
            local f = io.open(progress_path, "w")
            if f then f:write(dump(st)); f:close() end
        end
    end
    return deps
end

function OPDS:_ensureBrowser()
    if not self.opds_browser then
        self.opds_browser = OPDSBrowser:new{
            servers = self.servers,
            downloads = self.downloads,
            settings = self.settings,
            title = _("OPDS catalog"),
            is_popout = false,
            is_borderless = true,
            title_bar_fm_style = true,
            _manager = self,
        }
    end
    -- Credentials for fetchFeed/getServerFileName come from the browser's
    -- "current catalog" fields; set them per server inside runSync callers.
    return self.opds_browser
end
```

**Important:** `browser:parseFeed` / `getServerFileName` read `self.root_catalog_username/password` from the browser. `runSync` iterates servers, so the child must set those before each server. Add to `deps` a hook and call it from `runSync`: in `makisync.lua`'s `M.runSync`, right after computing `targets`, group is per-target — simplest: inside the `for i, t in ipairs(targets)` loop add `if deps.useServer then deps.useServer(t.server) end` before `sync_one_series(...)`. Then in `_syncDeps` add:

```lua
        useServer = function(srv)
            browser.root_catalog_username = srv.username
            browser.root_catalog_password = srv.password
            browser.root_catalog_title    = srv.title
        end,
```

(Add the `useServer` line to `makisync.lua` as part of this task; the Task 3 tests don't define it, and the call is guarded.)

- [ ] **Step 3: Replace `performAutoSync`**

Replace everything from `self.sync_in_progress = true` to the end of `performAutoSync` (the block that creates the browser and calls `checkSyncDownload`) with:

```lua
    logger.info("OPDS: Starting auto-sync")
    self:launchSync{ manual = false }
end
```

and replace the "Check if enough time has passed" block (`local now = os.time()` … `return end`) with:

```lua
    local due, why = MakiSync.shouldAutoSync(self.settings, os.time())
    if not due then
        logger.info("OPDS: auto-sync skipped:", why)
        return
    end
```

Replace the leading `if self.sync_in_progress then` check with `if self.sync_pid then logger.info("OPDS: Sync already in progress, skipping") return end`. Remove every other reference to `sync_in_progress` in `main.lua`.

- [ ] **Step 4: Add `launchSync`, poller, cancel**

Add after `performAutoSync`:

```lua
local SYNC_POLL_SECONDS = 2

-- opts: { manual = bool, server_index = n|nil, ignore_ledger = bool }
function OPDS:launchSync(opts)
    opts = opts or {}
    if self.sync_pid then
        if opts.manual then
            UIManager:show(InfoMessage:new{ text = _("Sync already running"), timeout = 3 })
        else
            logger.info("OPDS: Sync already in progress, skipping")
        end
        return
    end
    local progress_path
    if opts.manual then
        progress_path = DataStorage:getDataDir() .. "/cache/maki-progress.lua"
        os.remove(progress_path)
    end
    local deps = self:_syncDeps(progress_path)
    local servers, settings = self.servers, self.settings
    local run_opts = { server_index = opts.server_index, ignore_ledger = opts.ignore_ledger }

    local pid, fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local result = MakiSync.runSync(servers, settings, deps, run_opts)
        ffiutil.writeToFD(write_fd, dump(result), true)
    end, true)
    if not pid then
        logger.warn("Maki: could not fork sync:", fd)
        if opts.manual then
            UIManager:show(InfoMessage:new{ text = _("Maki: could not start sync"), timeout = 3 })
        end
        return
    end
    self.sync_pid, self.sync_fd = pid, fd
    self.sync_manual = opts.manual and true or false
    self.sync_progress_path = progress_path
    logger.info("Maki: sync started, pid", pid, "manual", self.sync_manual)

    if opts.manual then self:_showSyncProgress(_("Maki: starting sync…")) end
    self.sync_poll_task = self.sync_poll_task or function() self:_pollSync() end
    UIManager:scheduleIn(SYNC_POLL_SECONDS, self.sync_poll_task)
end

function OPDS:_showSyncProgress(text)
    if self.sync_widget then UIManager:close(self.sync_widget) end
    self.sync_widget = InfoMessage:new{
        text = text,
        dismiss_callback = function()
            self.sync_widget = nil
            self:cancelSync()
        end,
    }
    UIManager:show(self.sync_widget)
end

function OPDS:_closeSyncProgress()
    if self.sync_widget then
        local w = self.sync_widget
        self.sync_widget = nil
        w.dismiss_callback = nil
        UIManager:close(w)
    end
end

function OPDS:_pollSync()
    if not self.sync_pid then return end
    if not ffiutil.isSubProcessDone(self.sync_pid) then
        if self.sync_manual and self.sync_progress_path then
            local f = io.open(self.sync_progress_path, "r")
            if f then
                local src = f:read("*a"); f:close()
                local chunk = src and loadstring("return " .. src)
                local ok, st = pcall(chunk or function() end)
                if ok and type(st) == "table" and self.sync_widget then
                    self:_showSyncProgress(T(_("Maki: %1 (%2/%3)\n%4 downloaded — tap to cancel"),
                        st.title or "", st.series_index or 0, st.series_total or 0, st.downloaded or 0))
                end
            end
        end
        UIManager:scheduleIn(SYNC_POLL_SECONDS, self.sync_poll_task)
        return
    end

    local raw = self.sync_fd and ffiutil.readAllFromFD(self.sync_fd) or nil
    local result
    if raw and raw ~= "" then
        local chunk = loadstring("return " .. raw)
        local ok, r = pcall(chunk or function() end)
        if ok and type(r) == "table" then result = r end
    end
    result = result or { series = {}, downloaded = 0, failed = 0, adopted = 0,
                         aborted = true, reason = "no result from child" }
    local was_manual = self.sync_manual
    self.sync_pid, self.sync_fd, self.sync_manual = nil, nil, false
    if self.sync_progress_path then os.remove(self.sync_progress_path); self.sync_progress_path = nil end
    self:_closeSyncProgress()
    self:_finishSync(result, was_manual)
end

function OPDS:_finishSync(result, was_manual)
    logger.info("Maki: sync finished", "downloaded", result.downloaded, "failed", result.failed,
                "adopted", result.adopted, "aborted", tostring(result.aborted),
                "cancelled", tostring(result.cancelled), result.reason or "")
    if not result.aborted and not result.cancelled then
        self.settings.last_sync_time = os.time()
        self.updated = true
        self:saveSettings()
    end
    local series_with_new = 0
    for _, s in ipairs(result.series or {}) do
        if (s.downloaded or 0) > 0 then series_with_new = series_with_new + 1 end
    end
    if was_manual then
        UIManager:show(InfoMessage:new{
            text = T(_("Maki: %1 downloaded, %2 failed, %3 adopted%4"),
                     result.downloaded, result.failed, result.adopted,
                     result.cancelled and _("\n(cancelled)") or (result.aborted and ("\n" .. tostring(result.reason)) or "")),
            timeout = 6,
        })
    elseif result.downloaded > 0 then
        Notification:notify(T(_("Maki: %1 new chapter(s) in %2 series"), result.downloaded, series_with_new))
    elseif result.aborted then
        logger.warn("Maki: auto-sync aborted:", result.reason)
    end
    if result.downloaded > 0 then self:_refreshFileManager() end
end

function OPDS:_refreshFileManager()
    if not (self.ui and self.ui.file_chooser) then return end
    local home = G_reader_settings:readSetting("home_dir")
    local target = home and home ~= "" and home or self.ui.file_chooser.path
    if target then self.ui.file_chooser:changeToPath(target) end
end

function OPDS:cancelSync()
    if not self.sync_pid then return end
    logger.info("Maki: cancelling sync pid", self.sync_pid)
    ffiutil.terminateSubProcess(self.sync_pid)
    -- the poller will reap it and report `cancelled`/partial results
end

function OPDS:onSuspend()
    if self.sync_pid then self:cancelSync() end
end
```

In `onCloseWidget`, add as the first line: `if self.sync_pid then self:cancelSync() end`. Also add `UIManager:unschedule(self.sync_poll_task)` if `self.sync_poll_task` is set.

Add `SYNC_POLL_SECONDS` near the other constants at the top (`DNS_RETRY_DELAY` etc.) rather than mid-file if luacheck complains about the local placement.

- [ ] **Step 5: Remove `pending_syncs` from settings load/save**

In `OPDS:init` delete the line `self.pending_syncs = self.opds_settings:readSetting("pending_syncs", {})` and any `pending_syncs = self.pending_syncs` passed into `OPDSBrowser:new{}` (there are two such constructions — `onShowMakiCatalog` around line 115 and the one you removed from `performAutoSync`). In `saveSettings`, remove the `pending_syncs` save line if present.

- [ ] **Step 6: Lint and run tests**

Run: `cd maki.koplugin && luacheck main.lua makisync.lua | tail -2 && lua tests/_test_makisync.lua && lua tests/_test_makimarker.lua`
Expected: no *new* warnings; tests pass.

- [ ] **Step 7: Commit**

```bash
git add maki.koplugin/main.lua maki.koplugin/makisync.lua
git commit -m "feat(sync): fork background sync with poller, daily cap, notification"
```

---

### Task 5: `makibrowser.lua` — markers from *Download all here*, buttons → `launchSync`, remove queue

**Goal:** Make the manual bulk download create/update `.maki.lua` markers, route all sync buttons to `launchSync`, and delete the obsolete queue machinery.

**Files:**
- Modify: `maki.koplugin/makibrowser.lua` — `walkFeedForBulk` (~2612), `runBulkDownload` (~2690-2785), settings dialog buttons (~150-175), per-catalog dialog buttons (~1660-1680), sync-queue functions (`checkSyncDownload` 2080, `prunePendingSyncs` 2170, `fillPendingSyncs` 2238, `getSyncDownloadList` 2324, `downloadPendingSyncs` 2390) and constants `SYNC_MAX_ATTEMPTS`, `SYNC_QUEUE_MAX_ENTRIES`, `SYNC_QUEUE_MAX_AGE` (lines 56-60).

**Acceptance Criteria:**
- [ ] `walkFeedForBulk(item_url, breadcrumb, results, limit, on_progress, feed_root)` records `feed = feed_root or item_url` on every result; recursing into a navigation entry passes `item.url` as the new `feed_root`; following `rel=next` keeps the current `feed_root`.
- [ ] `runBulkDownload` writes, for each distinct `target_dir`, a marker `{ catalog = server.url, feed = <feed root>, title = <last breadcrumb>, fetched = {...} }` containing every file downloaded *or already present* in that run (URL → `{file, at}`); an existing marker is read first and merged (existing entries kept).
- [ ] "Sync all catalogs" → `self._manager:launchSync{ manual = true }`; "Force sync all catalogs" → `{ manual = true, ignore_ledger = true }`; per-catalog "Sync" → `{ manual = true, server_index = item.idx - 1 }`; "Force sync" → same plus `ignore_ledger = true`. (`item.idx - 1` matches the existing `self.servers[idx-1]` convention.)
- [ ] `checkSyncDownload`, `prunePendingSyncs`, `fillPendingSyncs`, `getSyncDownloadList`, `downloadPendingSyncs`, and the three queue constants are deleted; `grep -n "pending_syncs\|checkSyncDownload\|sync_in_progress" makibrowser.lua main.lua` returns nothing.
- [ ] `luacheck makibrowser.lua` shows no new warnings; all tests still pass.

**Verify:** `cd maki.koplugin && grep -c "pending_syncs\|checkSyncDownload" makibrowser.lua main.lua; luacheck makibrowser.lua | tail -1; lua tests/_test_makisync.lua` → `0`, `0`; no new warnings; tests pass.

**Steps:**

- [ ] **Step 1: Thread `feed_root` through `walkFeedForBulk`**

Change the signature to `function OPDSBrowser:walkFeedForBulk(item_url, breadcrumb, results, limit, on_progress, feed_root)` and set `feed_root = feed_root or item_url` as the first line of the body. In the acquisition `table.insert(results, {...})` add `feed = feed_root,`. In the navigation recursion call pass `item.url` as the 6th argument; in the pagination call pass `feed_root`.

- [ ] **Step 2: Require the marker module and write markers in `runBulkDownload`**

Add `local Marker = require("makimarker")` to the requires at the top of `makibrowser.lua`.

In `runBulkDownload`, when building `plan`, add `feed = r.feed` and `title = r.breadcrumb[#r.breadcrumb]` to each plan entry. After the download loop and before `Trapper:reset()`, add:

```lua
    -- Record what this series folder now holds so auto-sync can follow it.
    local server = self:getCurrentServer()
    if server then
        local now = os.time()
        local by_dir = {}
        for _, p in ipairs(plan) do
            if lfs.attributes(p.file) then
                local b = by_dir[p.dir]
                if not b then
                    b = { feed = p.feed, title = p.title, items = {} }
                    by_dir[p.dir] = b
                end
                b.items[#b.items + 1] = p
            end
        end
        for dir, b in pairs(by_dir) do
            local marker = Marker.read(dir) or { fetched = {} }
            marker.catalog = server.url
            marker.feed = b.feed
            marker.title = marker.title or b.title
            for _, p in ipairs(b.items) do
                Marker.markFetched(marker, p.url, p.file:match("[^/]+$"), now)
            end
            local ok, err = Marker.write(dir, marker)
            if not ok then logger.warn("Maki: marker write failed", dir, err) end
        end
    end
```

- [ ] **Step 3: Route the buttons**

Settings dialog (the four `NetworkMgr:runWhenConnected` callbacks around lines 150-175): replace the bodies so that

- "Sync all catalogs" → `self._manager:launchSync{ manual = true }`
- "Force sync all catalogs" → `self._manager:launchSync{ manual = true, ignore_ledger = true }`

Per-catalog dialog (around 1660-1680):

- "Force sync" → `self._manager:launchSync{ manual = true, server_index = item.idx - 1, ignore_ledger = true }`
- "Sync" → `self._manager:launchSync{ manual = true, server_index = item.idx - 1 }`

Keep the `UIManager:close(dialog)` and `NetworkMgr:runWhenConnected(function() ... end)` wrappers; drop the `self.sync_force = ...` lines.

- [ ] **Step 4: Delete the queue machinery**

Delete these functions entirely: `checkSyncDownload`, `prunePendingSyncs`, `fillPendingSyncs`, `getSyncDownloadList`, `downloadPendingSyncs`. Delete the constants `SYNC_MAX_ATTEMPTS`, `SYNC_QUEUE_MAX_ENTRIES`, `SYNC_QUEUE_MAX_AGE` and the `SYNC_ABORT_AFTER_CONSECUTIVE_FAILURES` constant if nothing else uses it (`grep -n SYNC_ABORT` to confirm). Remove `pending_syncs` from the `OPDSBrowser:new{}` field list and any `self.pending_syncs` reads. Remove `sync_force`, `sync_server_list`, `sync_server`, `sync_max_dl` fields if now unreferenced (grep each).

- [ ] **Step 5: Lint, test**

Run: `cd maki.koplugin && grep -n "pending_syncs\|checkSyncDownload\|sync_in_progress\|fillPendingSyncs" *.lua; luacheck makibrowser.lua main.lua | tail -2; lua tests/_test_makisync.lua; lua tests/_test_makimarker.lua`
Expected: grep prints nothing; no new luacheck warnings; tests pass.

- [ ] **Step 6: Commit**

```bash
git add maki.koplugin/makibrowser.lua
git commit -m "refactor(sync): markers from bulk download; buttons use launchSync; drop queue"
```

---

### Task 6: `tools/seed_markers.lua` — baseline markers for existing folders

**Goal:** One-off script that matches existing series folders to catalog series and writes baseline markers (every entry on the feed marked fetched, no HEADs).

**Files:**
- Create: `maki.koplugin/tools/seed_markers.lua`
- Create: `maki.koplugin/tools/README.md`

**Acceptance Criteria:**
- [ ] Runs inside KOReader's Lua (via the plugin: a hidden menu entry **Maki → ⚙ → Seed markers (one-off)** that calls `require("tools/seed_markers").run(self)`), because it needs the OPDS parser and credentials.
- [ ] For each server with `sync = true` and a sync dir: fetch the root feed, recurse **only into navigation entries** (libraries → series), stopping at any feed whose items contain acquisitions (that feed is a series). Pagination followed at each level.
- [ ] For each series feed: `sanitize_segment(title)`; if `<sync_dir>/<that>` is a directory without a marker, write `{ catalog, feed = <series feed first-page URL>, title, fetched = { [acq_url] = { at = now } ... } }` for every acquisition on the series feed.
- [ ] Series whose folder has a marker already are skipped. Folders that match no series are listed as unmatched.
- [ ] Shows a `TextViewer` summary: matched N (with names), unmatched folders, skipped (already had marker). Runs inside `Trapper:wrap` with `Trapper:info` progress so it is cancellable (this is a one-off tool; blocking-with-yields is acceptable here).

**Verify:** Manual: on the Boox after Task 7's deploy, run the menu entry with at least one folder in `_MANGA` created by copying from the NAS; summary lists it as matched and `.maki.lua` appears in it with `fetched` populated.

**Steps:**

- [ ] **Step 1: Write the tool**

`maki.koplugin/tools/seed_markers.lua`:

```lua
-- tools/seed_markers.lua — one-off: write baseline .maki.lua markers for
-- series folders that predate markers. Run from Maki's settings menu.
local Trapper = require("ui/trapper")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Marker = require("makimarker")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local function sanitize_segment(name)
    if not name or name == "" then return "Untitled" end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[/\\%z%c]", "_")
    name = name:gsub("[<>:\"|%?%*]", "_")
    if name == "" or name == "." or name == ".." then return "Untitled" end
    return name
end

-- Fetch a feed (all pages). Returns items (flat) and whether any item is an acquisition.
local function fetch_all(browser, url)
    local items, has_acq, page = {}, false, url
    while page do
        local ok, catalog = pcall(browser.parseFeed, browser, page)
        if not ok or not catalog then return nil end
        local tbl = browser:genItemTableFromCatalog(catalog, page)
        for _, it in ipairs(tbl) do
            items[#items + 1] = it
            if it.acquisitions and it.acquisitions[1] then has_acq = true end
        end
        page = tbl.hrefs and tbl.hrefs.next or nil
    end
    return items, has_acq
end

-- Walk navigation levels; call on_series(title, feed_url, items) for each series feed.
local function walk(browser, url, on_series, depth, progress)
    if depth > 4 then return end
    local items, has_acq = fetch_all(browser, url)
    if not items then return end
    if has_acq then return end -- caller handles series feeds
    for _, it in ipairs(items) do
        if it.url and not (it.acquisitions and it.acquisitions[1]) then
            if progress and progress(it.title or "") == false then return end
            local sub, sub_acq = fetch_all(browser, it.url)
            if sub and sub_acq then
                on_series(it.title or it.text or "Untitled", it.url, sub)
            elseif sub then
                walk(browser, it.url, on_series, depth + 1, progress)
            end
        end
    end
end

function M.run(plugin)
    local browser = plugin:_ensureBrowser()
    Trapper:wrap(function()
        local matched, unmatched, skipped = {}, {}, {}
        local now = os.time()
        for _, srv in ipairs(plugin.servers) do
            local sync_dir = srv.sync_dir or plugin.settings.sync_dir
            if srv.sync and sync_dir then
                browser.root_catalog_username = srv.username
                browser.root_catalog_password = srv.password
                browser.root_catalog_title    = srv.title
                local folders = {}
                for name in lfs.dir(sync_dir) do
                    local p = sync_dir .. "/" .. name
                    if name:sub(1, 1) ~= "." and lfs.attributes(p, "mode") == "directory" then
                        folders[name] = p
                    end
                end
                local seen = {}
                walk(browser, srv.url, function(title, feed_url, items)
                    local folder = sanitize_segment(title)
                    local dir = folders[folder]
                    if not dir then return end
                    seen[folder] = true
                    if Marker.read(dir) then skipped[#skipped + 1] = folder; return end
                    local marker = { catalog = srv.url, feed = feed_url, title = title, fetched = {} }
                    for _, it in ipairs(items) do
                        local a = it.acquisitions and it.acquisitions[1]
                        if a and a.href then marker.fetched[a.href] = { at = now } end
                    end
                    local ok, err = Marker.write(dir, marker)
                    if ok then matched[#matched + 1] = folder
                    else logger.warn("seed_markers: write failed", dir, err) end
                end, 0, function(where)
                    return Trapper:info(T(_("Seeding markers…\n%1"), where))
                end)
                for name in pairs(folders) do
                    if not seen[name] then unmatched[#unmatched + 1] = name end
                end
            end
        end
        Trapper:reset()
        table.sort(matched); table.sort(unmatched); table.sort(skipped)
        local text = T(_("Matched (%1):\n%2\n\nUnmatched folders (%3):\n%4\n\nAlready had marker (%5):\n%6"),
            #matched, table.concat(matched, "\n"), #unmatched, table.concat(unmatched, "\n"),
            #skipped, table.concat(skipped, "\n"))
        UIManager:show(TextViewer:new{ title = _("Maki: seed markers"), text = text })
    end)
end

return M
```

- [ ] **Step 2: Add the menu entry**

In `makibrowser.lua`'s settings dialog (the same button list as "Sync all catalogs"), add after "Force sync all catalogs":

```lua
            {{
                    text = _("Seed markers (one-off)"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            require("tools/seed_markers").run(self._manager)
                        end)
                    end,
                    align = "left",
            }},
```

- [ ] **Step 3: Write `tools/README.md`**

```markdown
# Maki tools

## seed_markers.lua

One-off migration for series folders created before `.maki.lua` markers
existed. Open Maki → ⚙ → **Seed markers (one-off)**. For every folder under a
sync catalog's sync dir that matches a series title in that catalog, writes a
marker whose ledger contains every chapter currently on the feed — a baseline.
Chapters missing from disk at seed time are treated as deliberately skipped;
use long-press → *Download all here* to pull a backlog.
```

- [ ] **Step 4: Lint and commit**

Run: `cd maki.koplugin && luacheck tools/seed_markers.lua | tail -1`
Expected: no errors (warnings about unused `logger` args are fine).

```bash
git add maki.koplugin/tools maki.koplugin/makibrowser.lua
git commit -m "tools: seed baseline markers for pre-existing series folders"
```

---

### Task 7: Device smoke test on the Boox

**Goal:** Smoke test on the Boox Go 10.3: deploy, run a manual sync and an auto-sync trigger with Wi-Fi, and prove no ANR occurs and the notification/marker behaviour works.

**USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation. It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Modify (device only): `/sdcard/koreader/plugins/maki.koplugin/` (pushed copy), `/sdcard/koreader/settings/maki.lua`

**Acceptance Criteria:**
- [ ] Plugin pushed: `adb push maki.koplugin /sdcard/koreader/plugins/maki.koplugin` completes; KOReader restarted with `pidof org.koreader.launcher` empty before relaunch.
- [ ] Manual path: Maki → Komga → long-press "JoJo's Bizarre Adventure - Part 9 - The JOJOLands" → *Download all here* completes; `adb shell cat "/sdcard/Books/_MANGA/JoJo's Bizarre Adventure - Part 9 - The JOJOLands/.maki.lua"` shows `catalog`, `feed`, and a non-empty `fetched`.
- [ ] Delete one downloaded chapter file, then Maki → ⚙ → "Sync all catalogs": summary shows `0 downloaded`; the deleted file is NOT re-created.
- [ ] ⚙ → "Force sync all catalogs": the deleted file IS re-created (`adb shell ls` shows it).
- [ ] Auto path: set `auto_sync=true, sync_on_network=true, sync_on_resume=true, last_sync_time=0` in `maki.lua` (KOReader stopped), relaunch, toggle Wi-Fi off/on; within 60 s logcat shows `Maki: sync started` then `Maki: sync finished`; `adb logcat -d | grep -c "ANR in org.koreader"` is unchanged from before the test; the device responds to taps during the run (open the hamburger menu while `Maki: sync started` is logged and before `finished`).
- [ ] Trigger Wi-Fi off/on again: logcat shows `OPDS: auto-sync skipped: too recent`.

**Verify:** `adb logcat -d -s KOReader:* | grep -E "Maki: sync (started|finished)|auto-sync skipped"` shows started → finished → skipped; `adb logcat -d | grep -c "ANR in org.koreader"` equals the pre-test count.

**Steps:**

- [ ] **Step 1: Record the baseline ANR count and deploy**

```bash
adb logcat -d | grep -c "ANR in org.koreader" | tee /tmp/anr_before
cd ~/projects/maki.koplugin
adb shell am force-stop org.koreader.launcher; sleep 2; adb shell pidof org.koreader.launcher   # must print nothing
adb push maki.koplugin /sdcard/koreader/plugins/maki.koplugin
adb shell am start -n org.koreader.launcher/.MainActivity
```

- [ ] **Step 2: Manual bulk download + marker check**

On device: hamburger → Maki (OPDS+) → Komga (bussybox) → navigate to the Weeb Central library → long-press "JoJo's Bizarre Adventure - Part 9 - The JOJOLands" → Download all here. Then:

```bash
adb shell cat "/sdcard/Books/_MANGA/JoJo's Bizarre Adventure - Part 9 - The JOJOLands/.maki.lua" | head -20
```

Expected: `catalog`, `feed`, `title` fields and ≥1 `fetched` entry.

- [ ] **Step 3: Ledger semantics**

```bash
adb shell rm "/sdcard/Books/_MANGA/JoJo's Bizarre Adventure - Part 9 - The JOJOLands/Unknown_Chapter 3.cbz"
```
On device: Maki → ⚙ → Sync all catalogs → summary shows `0 downloaded`. Confirm the file is still absent. Then ⚙ → Force sync all catalogs → confirm with `adb shell ls` that the file is back.

- [ ] **Step 4: Auto-sync without ANR**

```bash
adb shell am force-stop org.koreader.launcher; sleep 2; adb shell pidof org.koreader.launcher
adb shell 'sed -i -e "s/\[\"auto_sync\"\] = false/[\"auto_sync\"] = true/" -e "s/\[\"sync_on_network\"\] = false/[\"sync_on_network\"] = true/" -e "s/\[\"sync_on_resume\"\] = false/[\"sync_on_resume\"] = true/" -e "s/\[\"last_sync_time\"\] = [0-9]*/[\"last_sync_time\"] = 0/" /sdcard/koreader/settings/maki.lua'
adb shell am start -n org.koreader.launcher/.MainActivity
adb shell svc wifi disable; sleep 3; adb shell svc wifi enable
sleep 60
adb logcat -d -s KOReader:* | grep -E "Maki: sync (started|finished)|auto-sync skipped"
adb logcat -d | grep -c "ANR in org.koreader"   # must equal /tmp/anr_before
```

While the sync is running (between `started` and `finished`), tap the hamburger menu on the device — it must open.

- [ ] **Step 5: Daily cap**

```bash
adb shell svc wifi disable; sleep 3; adb shell svc wifi enable; sleep 20
adb logcat -d -s KOReader:* | grep "auto-sync skipped: too recent" | tail -1
```

- [ ] **Step 6: Record results in the commit**

```bash
cd ~/projects/maki.koplugin
git commit --allow-empty -m "test: Boox smoke test — manual/force/auto sync, no ANR (see plan Task 7)"
```

---

## Code Areas

### Area: sync-core

Pure logic with injected I/O; runs in tests, the forked child, and the seed tool.

- `maki.koplugin/makimarker.lua` — the `.maki.lua` file format: read (lenient, always yields a `fetched` table), atomic write via `.tmp` + rename, list followed series dirs for one catalog URL, `markFetched` (never overwrites an existing ledger entry).
- `maki.koplugin/makisync.lua` — `planSeries` (ledger → skip; on-disk → adopt; `.part` → remove; else fetch), `shouldAutoSync` (interval gate on `settings.last_sync_time`), `runSync` (per-server → `listFollowed` → per-series collect feed pages → plan → download `.part` → rename → ledger; cap, consecutive-failure abort, cancel, progress).
- `maki.koplugin/tests/_test_makimarker.lua`, `tests/_test_makisync.lua` — stub harness (`test(name, fn)` + pcall, `N/N tests passed`, non-zero exit on failure); in-memory FS and feed maps; `package.loaded["dump"]`/`["logger"]` stubbed before `dofile`.
- `maki.koplugin/tools/seed_markers.lua` — one-off that uses `makimarker` directly and the browser's feed parser; walks only navigation levels.

Invariants: ledger key is acquisition URL; ledger entry is `{file=<string|nil>, at=<number>}`; existing ledger entries are never modified; marker written only if `changed`; nothing here imports UI modules. Tests run with plain `/usr/bin/lua` from inside `maki.koplugin/`.

### Area: plugin-shell

KOReader-facing glue: widgets, settings, subprocess plumbing.

- `maki.koplugin/main.lua` — plugin object `OPDS` (WidgetContainer). Owns `servers`/`settings` (persisted in `settings/maki.lua` via `LuaSettings`, flushed by `saveSettings` when `self.updated`), the auto-sync triggers (`_onNetworkConnected` debounced, `_onResume`, `schedulePeriodicSync`), DNS-readiness retry (`syncHostsResolve`, `DNS_MAX_RETRIES`), and after Task 4: `launchSync` / `_pollSync` / `_finishSync` / `cancelSync` and `_syncDeps` (builds makisync deps from an `OPDSBrowser` instance whose `root_catalog_*` fields carry credentials).
- `maki.koplugin/makibrowser.lua` — `OPDSBrowser` (Menu). Feed fetch/parse (`fetchFeed`, `parseFeed`, `genItemTableFromCatalog` → item table with `.acquisitions`, `.url`, `.hrefs.next`), filename derivation via HEAD (`getServerFileName`), single-file download (`downloadFile`, `quiet` flag suppresses dialogs), bulk walk (`walkFeedForBulk`) and bulk download with live Trapper progress (`runBulkDownload`), settings dialog (sync buttons ~150-175), per-catalog long-press dialog (~1660), `sanitize_segment` (local, top of file), `getCurrentServer` (by `root_catalog_title`).
- `maki.koplugin/makihttp.lua` — keepalive HTTPS `Client` (`downloadURL(url, path)` → `true` | `false, err` | `nil` on host mismatch). Used by bulk download; not needed by the child (it uses `downloadFile`).
- `maki.koplugin/_meta.lua` — plugin metadata.
- `.luacheckrc` at repo root — run `luacheck <file>` from `maki.koplugin/`.

Invariants: anything executed inside `runInSubProcess` must not call `UIManager` or create widgets; `self.updated = true` before `saveSettings()` or nothing is flushed; `servers[idx-1]` is the dialog-index convention; Android kills the app if the UI thread blocks >5 s, so all network work on the main thread must be inside a Trapper flow with yields (bulk download) or in the child. No unit tests in this area; verification is luacheck + the Task 7 device smoke test.
