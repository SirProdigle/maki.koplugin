-- makimarker.lua
-- The `.maki.lua` per-series marker file: a lenient reader, an atomic
-- writer, a helper to list followed series directories for one catalog
-- URL, and `markFetched` which never overwrites an existing ledger entry.
--
-- Marker shape: { catalog_url = <string|nil>, fetched = { [url] = { file = <string|nil>, at = <number> }, ... } }

local dump = require("dump")
local logger = require("logger")

local MARKER_FILENAME = ".maki.lua"

local M = {}
M.MARKER_FILENAME = MARKER_FILENAME

-- Lenient read: any parse/IO failure yields a fresh marker with an empty
-- `fetched` table rather than erroring.
function M.read(path)
    local ok_read, contents = pcall(function()
        local f = io.open(path, "r")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end)
    if not ok_read or not contents then
        return { fetched = {} }
    end
    local chunk, load_err = load(contents, "@" .. path)
    if not chunk then
        logger.warn("Maki: failed to parse marker", path, load_err)
        return { fetched = {} }
    end
    local ok_run, marker = pcall(chunk)
    if not ok_run or type(marker) ~= "table" then
        logger.warn("Maki: failed to load marker", path)
        return { fetched = {} }
    end
    marker.fetched = marker.fetched or {}
    return marker
end

-- Atomic write via a sibling `.tmp` file + rename.
function M.write(path, marker)
    local tmp_path = path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then
        return false, "could not open " .. tmp_path
    end
    f:write("return " .. dump(marker) .. "\n")
    f:close()
    local ok, err = os.rename(tmp_path, path)
    if not ok then
        return false, err
    end
    return true
end

-- List directories under `dir` that carry a marker for `catalog_url`.
-- deps: { listDirs(dir) -> {name, ...}, exists(path) -> bool, joinPath(a,b) -> path (optional) }
function M.listFollowed(dir, catalog_url, deps)
    local join = deps.joinPath or function(a, b) return a .. "/" .. b end
    local followed = {}
    local names = deps.listDirs(dir) or {}
    for _, name in ipairs(names) do
        local series_dir = join(dir, name)
        local marker_path = join(series_dir, MARKER_FILENAME)
        if deps.exists(marker_path) then
            local marker = M.read(marker_path)
            if marker.catalog_url == catalog_url then
                followed[#followed + 1] = { dir = series_dir, marker = marker, marker_path = marker_path }
            end
        end
    end
    return followed
end

-- Record a fetched acquisition URL. Never overwrites an existing entry.
function M.markFetched(marker, url, file, at)
    marker.fetched = marker.fetched or {}
    if marker.fetched[url] then
        return false
    end
    marker.fetched[url] = { file = file, at = at }
    return true
end

return M
