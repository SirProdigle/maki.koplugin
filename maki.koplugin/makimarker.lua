-- makimarker.lua
-- The `.maki.lua` per-series marker file: a lenient reader, an atomic
-- writer, a helper to list followed series directories for one catalog
-- URL, and `markFetched` which never overwrites an existing ledger entry.
--
-- Marker shape:
--   { catalog = <server url>, feed = <series feed url>, title = <string>,
--     fetched = { [acquisition_url] = { file = <string|nil>, at = <number> }, ... } }
--
-- Every side effect goes through an optional `deps` table so the same code
-- runs in unit tests, in the forked child and in the seed tool:
--   readFile(path)          -> contents | nil
--   writeFile(path, data)   -> ok, err
--   rename(from, to)        -> ok, err
--   listDirs(path)          -> { name, ... }

local dump = require("dump")
local logger = require("logger")

local MARKER_FILENAME = ".maki.lua"

local M = {}
M.MARKER_FILENAME = MARKER_FILENAME

local io_deps = {
    readFile = function(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end,
    writeFile = function(path, data)
        local f = io.open(path, "w")
        if not f then return false, "could not open " .. path end
        f:write(data)
        f:close()
        return true
    end,
    rename = function(a, b) return os.rename(a, b) end,
    listDirs = function(path)
        local names = {}
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok then return names end
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local attr = lfs.attributes(path .. "/" .. name)
                if attr and attr.mode == "directory" then names[#names + 1] = name end
            end
        end
        return names
    end,
}

local function D(deps) return deps or io_deps end

local function strip_slash(p) return (p:gsub("/+$", "")) end

function M.path(dir) return strip_slash(dir) .. "/" .. MARKER_FILENAME end

-- Lenient read: any parse/IO failure yields a fresh marker with an empty
-- `fetched` table rather than erroring. Accepts a series dir.
function M.read(dir, deps)
    local path = M.path(dir)
    local ok_read, contents = pcall(D(deps).readFile, path)
    if not ok_read or not contents then
        return { fetched = {} }
    end
    local loader = load or rawget(_G, "loadstring")
    local chunk, load_err = loader(contents, "@" .. path)
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

-- Atomic write via a sibling `.tmp` file + rename. Accepts a series dir.
function M.write(dir, marker, deps)
    deps = D(deps)
    local path = M.path(dir)
    local tmp_path = path .. ".tmp"
    local ok, err = deps.writeFile(tmp_path, "return " .. dump(marker) .. "\n")
    if not ok then return false, err or ("could not write " .. tmp_path) end
    local rok, rerr = deps.rename(tmp_path, path)
    if not rok then return false, rerr end
    return true
end

-- List directories under `dir` that carry a marker for `catalog_url`.
-- Series do not always sit directly under the sync folder: *Download all
-- here* on a library writes <sync_dir>/<library>/<series>/.maki.lua, so scan
-- a few levels down. A directory that already carries a marker is a series —
-- never descend into it.
M.MAX_DEPTH = 3

function M.listFollowed(dir, catalog_url, deps, max_depth)
    deps = D(deps)
    max_depth = max_depth or M.MAX_DEPTH
    local followed = {}
    local function scan(base, depth)
        for _, name in ipairs(deps.listDirs(base) or {}) do
            local series_dir = base .. "/" .. name
            local marker = M.read(series_dir, deps)
            local catalog = marker.catalog or marker.catalog_url
            if catalog then
                if catalog == catalog_url then
                    followed[#followed + 1] = {
                        dir = series_dir, marker = marker, marker_path = M.path(series_dir),
                    }
                end
            elseif depth < max_depth then
                scan(series_dir, depth + 1)
            end
        end
    end
    scan(strip_slash(dir), 1)
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
