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
        if deps.useServer then deps.useServer(t.server) end
        sync_one_series(t.server, t.followed, settings, deps, opts, result, state)
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
        if rec.downloaded > 0 or rec.failed > 0 or rec.feed_failed then
            reported[#reported + 1] = { title = rec.title, downloaded = rec.downloaded,
                                        failed = rec.failed, feed_failed = rec.feed_failed or nil }
        end
    end
    result.series = reported
    return result
end

return M
