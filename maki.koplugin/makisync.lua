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
--   fileSize(path)            -> bytes | nil             (optional; no replacements without it)
--   fetchJSON(url, username, password) -> table | nil, err (optional; Komga REST, no replacements without it)
--   openFile                  -> path of the document open in the reader, or nil
--                                (optional; captured by the parent before forking)
--   realpath(path)            -> canonical path | nil    (optional; used to match openFile)
--
-- Change detection: file size. For a Komga series feed, one REST call per
-- series per sync (/api/v1/series/{id}/books) yields every book's
-- `sizeBytes`. A chapter already in the ledger whose local file is still on
-- disk is re-downloaded ("replace") when the server size is known and
-- differs from the local size. OPDS <updated> is NOT usable: Komga bumps it
-- on every book of a series whenever it rescans that series.

local logger = require("logger")
local Marker = require("makimarker")

local M = {}

M.DEFAULT_INTERVAL_HOURS = 24
M.ABORT_AFTER_CONSECUTIVE_FAILURES = 2

local function strip_slash(p) return (p:gsub("/+$", "")) end

local function is_open(path, deps)
    local open = deps.openFile
    if not open then return false end
    if path == open then return true end
    if deps.realpath then
        local ok, real = pcall(deps.realpath, path)
        if ok and real and real == open then return true end
    end
    return false
end

-- A ledger entry whose chapter changed on the server since it was fetched.
-- Returns a replace plan item, "open" when it is the document being read,
-- or nil.
local function plan_replace(e, rec, dir, deps, plan)
    if not e.size or not deps.fileSize then return nil end
    local fname = rec.file
    if not fname then
        -- Seeded entries carry no file name: resolve it once (HEAD), only
        -- when there is something to compare, and remember it.
        fname = deps.fileName(e.url, e.filetype)
        if not fname then return nil end
        rec.file = fname
        plan.changed = true
    end
    local path = dir .. "/" .. fname
    if not deps.exists(path) then return nil end -- deleted on purpose: stays gone
    local local_size = deps.fileSize(path)
    if not local_size or local_size == e.size then return nil end
    if is_open(path, deps) then return "open" end
    if deps.exists(path .. ".part") then
        deps.remove(path .. ".part")
    end
    return { url = e.url, file = fname, path = path, title = e.title or fname,
             size = e.size, replace = true }
end

-- Decide what to do for every acquisition entry of one series feed.
-- `entry.size` (server bytes, optional) drives replacements.
function M.planSeries(entries, dir, marker, deps)
    dir = strip_slash(dir)
    marker.fetched = marker.fetched or {}
    local plan = { to_fetch = {}, adopted = 0, skipped_open = 0, changed = false }
    for _, e in ipairs(entries) do
        if e.url then
            local rec = marker.fetched[e.url]
            if rec then
                local r = plan_replace(e, rec, dir, deps, plan)
                if r == "open" then
                    logger.info("Maki: not replacing the open document", e.url)
                    plan.skipped_open = plan.skipped_open + 1
                elseif r then
                    plan.to_fetch[#plan.to_fetch + 1] = r
                end
            else
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

-- ── Komga REST (file sizes) ─────────────────────────────────────────────

-- REST url listing every book of the series behind a Komga OPDS series
-- feed (".../opds/v1.2/series/{id}"), or nil for any other feed. Keeps any
-- path prefix Komga is served under.
function M.komgaSeriesBooksUrl(feed_url)
    if type(feed_url) ~= "string" then return nil end
    local base, id = feed_url:match("^(https?://.-)/opds/v[%d%.]+/series/([^/?#]+)")
    if not base then return nil end
    return base .. "/api/v1/series/" .. id .. "/books?unpaged=true"
end

-- Komga book id from an OPDS acquisition url (".../opds/v1.2/books/{id}/file/..."), or nil.
function M.komgaBookId(acq_url)
    if type(acq_url) ~= "string" then return nil end
    return acq_url:match("/opds/v[%d%.]+/books/([^/?#]+)/file")
end

-- { [book_id] = sizeBytes } from a decoded /books response, or nil when the
-- response does not have the expected shape. Malformed rows are skipped.
function M.bookSizes(resp)
    if type(resp) ~= "table" or type(resp.content) ~= "table" then return nil end
    local sizes = {}
    for _, b in ipairs(resp.content) do
        if type(b) == "table" and type(b.id) == "string" and type(b.sizeBytes) == "number" then
            sizes[b.id] = b.sizeBytes
        end
    end
    return sizes
end

-- One REST call for a followed series. Any failure means "no size info"
-- (no replacements for this series), never a failed sync.
local function fetch_sizes(feed_url, server, deps)
    if not (deps.fetchJSON and deps.fileSize) then return nil end
    local url = M.komgaSeriesBooksUrl(feed_url)
    if not url then return nil end
    local ok, resp, err = pcall(deps.fetchJSON, url, server.username, server.password)
    if not ok then resp, err = nil, resp end
    local sizes = resp and M.bookSizes(resp)
    if not sizes then
        logger.warn("Maki: no book sizes for", feed_url, err or "unexpected response")
    end
    return sizes
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

local function sync_one_series(server, followed, deps, opts, result, state)
    local marker, dir = followed.marker, followed.dir
    local rec = { title = marker.title or dir:match("[^/]+$"), dir = dir,
                  downloaded = 0, replaced = 0, failed = 0, adopted = 0, feed_failed = false }
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
    -- Server sizes only matter for chapters already in the ledger.
    if next(plan_marker.fetched or {}) then
        local sizes = fetch_sizes(marker.feed, server, deps)
        if sizes then
            for _, e in ipairs(entries) do
                local id = M.komgaBookId(e.url)
                e.size = id and sizes[id] or nil
            end
        end
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
        -- Replacements share the per-run cap with new chapters, so a large
        -- server-side refresh spreads across several syncs.
        if result.downloaded + result.replaced >= state.max_dl then result.capped = true; break end
        if deps.cancelled and deps.cancelled() then result.cancelled = true; break end
        local tmp = item.path .. ".part"
        local ok, why = deps.download(item.url, tmp, server.username, server.password)
        if ok and item.replace and deps.fileSize(tmp) ~= item.size then
            -- Truncated, or the server file changed again mid-sync: never
            -- swap a bad copy over a good one. Retried next sync.
            ok, why = false, "size mismatch"
        end
        if ok then
            local rok, rerr = deps.rename(tmp, item.path)
            if not rok then ok, why = false, rerr or "rename failed" end
        end
        if ok then
            if item.replace then
                -- .part renamed over the old file; the .sdr sidecar is left
                -- alone (same pages, so reading progress stays valid).
                Marker.markReplaced(marker, item.url, item.file, deps.now())
                plan.changed = true
                rec.replaced = rec.replaced + 1
                result.replaced = result.replaced + 1
            else
                if Marker.markFetched(marker, item.url, item.file, deps.now()) then
                    plan.changed = true
                end
                rec.downloaded = rec.downloaded + 1
                result.downloaded = result.downloaded + 1
            end
            state.consecutive_failures = 0
        else
            deps.remove(tmp)
            rec.failed = rec.failed + 1
            result.failed = result.failed + 1
            -- A size mismatch is a server-side condition, not a sign the
            -- network is down: it must not abort the rest of the sync.
            if why ~= "size mismatch" then
                state.consecutive_failures = state.consecutive_failures + 1
            end
            result.reason = result.reason or why
            logger.warn("Maki: download failed", item.path, why)
            if state.consecutive_failures >= M.ABORT_AFTER_CONSECUTIVE_FAILURES then
                result.aborted = true
                break
            end
        end
        if deps.progress then
            deps.progress({ series_index = state.series_index, series_total = state.series_total,
                            title = rec.title, downloaded = result.downloaded, replaced = result.replaced,
                            total_planned = #plan.to_fetch })
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
    local result = { series = {}, downloaded = 0, replaced = 0, failed = 0, adopted = 0,
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
        if deps.useServer then deps.useServer(t.server) end
        sync_one_series(t.server, t.followed, deps, opts, result, state)
        if result.aborted or result.cancelled then break end
        if result.capped then break end
    end

    if #targets > 0 and state.feeds_ok == 0 then
        result.aborted = true
        result.reason = result.reason or "all feeds failed"
    end

    -- The result crosses a pipe that the parent only drains once the child has
    -- exited: a record per followed series would fill the pipe buffer on a big
    -- shelf and wedge the child in write() forever. Only series that actually
    -- did something are worth reporting; the totals carry the rest.
    local reported = {}
    for _, rec in ipairs(result.series) do
        if rec.downloaded > 0 or rec.replaced > 0 or rec.failed > 0 or rec.feed_failed then
            reported[#reported + 1] = { title = rec.title, downloaded = rec.downloaded,
                                        replaced = rec.replaced, failed = rec.failed,
                                        feed_failed = rec.feed_failed or nil }
        end
    end
    result.series = reported
    return result
end

return M
