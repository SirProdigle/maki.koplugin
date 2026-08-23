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
