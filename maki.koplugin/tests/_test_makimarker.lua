-- tests/_test_makimarker.lua
-- Usage: cd maki.koplugin && lua tests/_test_makimarker.lua

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

local Marker = dofile("makimarker.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- An in-memory filesystem: files[path] = contents, dirs[path] = { name, ... }
local function fs(files, dirs, log)
    files, dirs, log = files or {}, dirs or {}, log or {}
    local deps
    deps = {
        files = files, dirs = dirs, log = log,
        readFile = function(p) log[#log + 1] = "read " .. p; return files[p] end,
        writeFile = function(p, data)
            log[#log + 1] = "write " .. p
            if deps.write_fails then return false, "disk full" end
            files[p] = data
            return true
        end,
        rename = function(a, b)
            log[#log + 1] = "rename " .. a .. " -> " .. b
            if deps.rename_fails then return nil, "rename failed" end
            files[b], files[a] = files[a], nil
            return true
        end,
        listDirs = function(p) return dirs[p] or {} end,
    }
    return deps
end

-- Seed a marker file for `dir` straight into the fake fs.
local function seed(deps, dir, marker)
    deps.files[Marker.path(dir)] = "return " .. package.loaded["dump"](marker) .. "\n"
end

-- ─── path ────────────────────────────────────────────────────────────────

test("path: appends the marker filename", function()
    assert(Marker.MARKER_FILENAME == ".maki.lua")
    assert(Marker.path("/m/S") == "/m/S/.maki.lua")
end)

test("path: trailing slashes are stripped", function()
    assert(Marker.path("/m/S/") == "/m/S/.maki.lua")
    assert(Marker.path("/m/S///") == "/m/S/.maki.lua")
end)

-- ─── read ────────────────────────────────────────────────────────────────

test("read: missing file yields an empty marker", function()
    local m = Marker.read("/m/S", fs())
    assert(type(m) == "table" and type(m.fetched) == "table")
    assert(next(m.fetched) == nil)
end)

test("read: unparsable contents yield an empty marker", function()
    local deps = fs({ ["/m/S/.maki.lua"] = "return {{{" })
    local m = Marker.read("/m/S", deps)
    assert(next(m.fetched) == nil)
end)

test("read: chunk that errors at runtime yields an empty marker", function()
    local deps = fs({ ["/m/S/.maki.lua"] = "error('boom')" })
    local m = Marker.read("/m/S", deps)
    assert(next(m.fetched) == nil)
end)

test("read: chunk returning a non-table yields an empty marker", function()
    local deps = fs({ ["/m/S/.maki.lua"] = "return 42" })
    local m = Marker.read("/m/S", deps)
    assert(next(m.fetched) == nil)
end)

test("read: readFile throwing is caught", function()
    local deps = fs()
    deps.readFile = function() error("io exploded") end
    local m = Marker.read("/m/S", deps)
    assert(next(m.fetched) == nil)
end)

test("read: a valid marker round-trips", function()
    local deps = fs()
    seed(deps, "/m/S", { catalog = "C", feed = "F", title = "Series",
                         fetched = { u1 = { file = "1.cbz", at = 7 } } })
    local m = Marker.read("/m/S", deps)
    assert(m.catalog == "C" and m.feed == "F" and m.title == "Series")
    assert(m.fetched.u1.file == "1.cbz" and m.fetched.u1.at == 7)
end)

test("read: a marker without `fetched` gets an empty one", function()
    local deps = fs({ ["/m/S/.maki.lua"] = "return { catalog = 'C' }" })
    local m = Marker.read("/m/S", deps)
    assert(m.catalog == "C" and type(m.fetched) == "table" and next(m.fetched) == nil)
end)

-- ─── write ───────────────────────────────────────────────────────────────

test("write: goes through a .tmp file then renames", function()
    local deps = fs()
    local ok = Marker.write("/m/S", { catalog = "C", fetched = {} }, deps)
    assert(ok == true)
    assert(deps.log[1] == "write /m/S/.maki.lua.tmp")
    assert(deps.log[2] == "rename /m/S/.maki.lua.tmp -> /m/S/.maki.lua")
    assert(deps.files["/m/S/.maki.lua.tmp"] == nil, "tmp must not linger")
    assert(deps.files["/m/S/.maki.lua"]:match("^return "))
end)

test("write: what is written reads back", function()
    local deps = fs()
    assert(Marker.write("/m/S", { catalog = "C", feed = "F",
                                  fetched = { u1 = { file = "1.cbz", at = 9 } } }, deps))
    local m = Marker.read("/m/S", deps)
    assert(m.catalog == "C" and m.feed == "F" and m.fetched.u1.at == 9)
end)

test("write: a failing writeFile is reported and nothing is renamed", function()
    local deps = fs()
    deps.write_fails = true
    local ok, err = Marker.write("/m/S", { fetched = {} }, deps)
    assert(ok == false and err == "disk full")
    assert(deps.log[2] == nil, "must not rename after a failed write")
end)

test("write: a failing rename is reported", function()
    local deps = fs()
    deps.rename_fails = true
    local ok, err = Marker.write("/m/S", { fetched = {} }, deps)
    assert(ok == false and err == "rename failed")
    assert(deps.files["/m/S/.maki.lua"] == nil)
end)

-- ─── listFollowed ────────────────────────────────────────────────────────

test("listFollowed: finds a series one level down", function()
    local deps = fs()
    deps.dirs["/m"] = { "A" }
    seed(deps, "/m/A", { catalog = "C", feed = "fa", fetched = {} })
    local found = Marker.listFollowed("/m", "C", deps)
    assert(#found == 1)
    assert(found[1].dir == "/m/A" and found[1].marker.feed == "fa")
    assert(found[1].marker_path == "/m/A/.maki.lua")
end)

test("listFollowed: descends into unmarked folders", function()
    local deps = fs()
    deps.dirs["/m"] = { "Library" }
    deps.dirs["/m/Library"] = { "S" }
    seed(deps, "/m/Library/S", { catalog = "C", feed = "fs", fetched = {} })
    local found = Marker.listFollowed("/m", "C", deps)
    assert(#found == 1 and found[1].dir == "/m/Library/S")
end)

test("listFollowed: never descends into a marked series", function()
    local deps = fs()
    deps.dirs["/m"] = { "S" }
    deps.dirs["/m/S"] = { "Nested" }
    seed(deps, "/m/S", { catalog = "C", feed = "fs", fetched = {} })
    seed(deps, "/m/S/Nested", { catalog = "C", feed = "fn", fetched = {} })
    local found = Marker.listFollowed("/m", "C", deps)
    assert(#found == 1 and found[1].dir == "/m/S")
end)

test("listFollowed: another catalog's series is not followed", function()
    local deps = fs()
    deps.dirs["/m"] = { "A", "B" }
    seed(deps, "/m/A", { catalog = "C", feed = "fa", fetched = {} })
    seed(deps, "/m/B", { catalog = "OTHER", feed = "fb", fetched = {} })
    local found = Marker.listFollowed("/m", "C", deps)
    assert(#found == 1 and found[1].dir == "/m/A")
end)

test("listFollowed: legacy `catalog_url` key is honoured", function()
    local deps = fs()
    deps.dirs["/m"] = { "A" }
    seed(deps, "/m/A", { catalog_url = "C", feed = "fa", fetched = {} })
    local found = Marker.listFollowed("/m", "C", deps)
    assert(#found == 1 and found[1].dir == "/m/A")
end)

test("listFollowed: stops at max_depth", function()
    local deps = fs()
    deps.dirs["/m"] = { "a" }
    deps.dirs["/m/a"] = { "b" }
    deps.dirs["/m/a/b"] = { "S" }
    seed(deps, "/m/a/b/S", { catalog = "C", feed = "fs", fetched = {} })
    assert(#Marker.listFollowed("/m", "C", deps, 2) == 0)
    assert(#Marker.listFollowed("/m", "C", deps, 4) == 1)
end)

test("listFollowed: a trailing slash on the sync dir does not double up", function()
    local deps = fs()
    deps.dirs["/m"] = { "A" }
    seed(deps, "/m/A", { catalog = "C", feed = "fa", fetched = {} })
    local found = Marker.listFollowed("/m/", "C", deps)
    assert(#found == 1 and found[1].dir == "/m/A")
end)

test("listFollowed: an empty sync dir yields nothing", function()
    assert(#Marker.listFollowed("/m", "C", fs()) == 0)
end)

-- ─── markFetched ─────────────────────────────────────────────────────────

test("markFetched: records file and timestamp", function()
    local marker = { fetched = {} }
    assert(Marker.markFetched(marker, "u1", "1.cbz", 100) == true)
    assert(marker.fetched.u1.file == "1.cbz" and marker.fetched.u1.at == 100)
end)

test("markFetched: never overwrites an existing entry", function()
    local marker = { fetched = { u1 = { file = "old.cbz", at = 1 } } }
    assert(Marker.markFetched(marker, "u1", "new.cbz", 100) == false)
    assert(marker.fetched.u1.file == "old.cbz" and marker.fetched.u1.at == 1)
end)

test("markFetched: an entry with a nil file still suppresses re-fetch", function()
    local marker = { fetched = {} }
    assert(Marker.markFetched(marker, "u1", nil, 100) == true)
    assert(marker.fetched.u1.file == nil and marker.fetched.u1.at == 100)
    assert(Marker.markFetched(marker, "u1", "1.cbz", 200) == false)
end)

test("markFetched: creates `fetched` when absent", function()
    local marker = {}
    assert(Marker.markFetched(marker, "u1", "1.cbz", 100) == true)
    assert(marker.fetched.u1.file == "1.cbz")
end)

print(string.format("%d/%d tests passed", pass, pass + fail))
if fail > 0 then os.exit(1) end
